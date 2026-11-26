from datetime import datetime, timezone
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch
from types import SimpleNamespace
import uuid

from radio import Radio, StandaloneArchive, supervise_worker
from import_sms import import_messages


class FixtureModem:
    def _command(self, command, **kwargs):
        if command == 'AT+QCCID':
            return ['+QCCID: 89860012345678901234']
        if command.startswith('AT+CMGS=') and kwargs.get('pdu'):
            return ['+CMGS: 3']
        raise AssertionError(command)


class ArchiveTests(TestCase):
    def test_timeline_pages_by_recorded_time_and_removes_completed_plaintext(self):
        with TemporaryDirectory() as directory:
            archive = StandaloneArchive(Path(directory) / 'messages.sqlite', 'ec20')
            archive.bind_sim(FixtureModem(), '460031234567890')
            with archive.connect() as db:
                archive.record(db, '10000', 'older', False, '2026-11-14T08:00:00+08:00', 0)
            stamp = datetime(2026, 11, 13, tzinfo=timezone.utc)
            with patch('trial_sms.delivered', return_value=('10000', stamp, 'verification text', None)):
                self.assertTrue(archive.ingest('c0ffee'))
            base = '/api/sms/thread?peer=10000&limit=1&order=timeline'
            _, first = archive.request('GET', base)
            newest = first[0]
            self.assertEqual(newest['content'], 'verification text')
            _, previous = archive.request('GET', base + f"&before_timeline={newest['timeline_cursor']}&before_id={newest['id']}")
            self.assertEqual(previous[0]['content'], 'older')
            self.assertEqual(archive.request('DELETE', f"/api/sms/messages/{newest['id']}?peer=10000"), (200, {}))
            with archive.connect() as db:
                self.assertEqual(db.execute('select body,complete from homeline_at_inbox').fetchone()[:], ('', 1))

    def test_same_request_does_not_resubmit_and_incoming_interrupts_between_segments(self):
        with TemporaryDirectory() as directory:
            commands = []
            class Modem(FixtureModem):
                usable = True
                def _command(self, command, **kwargs):
                    if command.startswith('AT+CMGS='):
                        commands.append(kwargs['timeout'])
                    return super()._command(command, **kwargs)

            modem = Modem()
            archive = StandaloneArchive(Path(directory) / 'messages.sqlite', 'ec20')
            archive.bind_sim(modem, '460031234567890')
            radio = Radio(modem, archive, 'test', pcm_fd=-1)
            radio.poll_call = lambda: None
            request_id = str(uuid.uuid4())
            status, result = radio.send_message('10000', 'hello', request_id)
            self.assertEqual(status, 200)
            self.assertEqual(radio.send_message('10000', 'hello', request_id), (status, result))
            self.assertEqual(commands, [8])

            def incoming_after_first_segment():
                if len(commands) > 1:
                    radio.call = SimpleNamespace(state='incoming')
            radio.poll_call = incoming_after_first_segment
            partial_id = str(uuid.uuid4())
            self.assertEqual(radio.send_message('10000', '字' * 90, partial_id), (409, {'error': 'send_uncertain'}))
            self.assertEqual(commands, [8, 8])
            restarted = Radio(modem, archive, 'test', pcm_fd=-1)
            self.assertEqual(restarted.send_message('10000', '字' * 90, partial_id), (409, {'error': 'send_uncertain'}))
            self.assertEqual(commands, [8, 8])

    def test_worker_failure_requests_service_recovery(self):
        failed = []
        def maintenance():
            raise PermissionError('simulated failure')
        with patch('radio.traceback.print_exc'):
            supervise_worker(maintenance, lambda: False, lambda: failed.append(True))
        self.assertEqual(failed, [True])

    def test_first_start_send_receive_and_restart_without_legacy_database(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'messages.sqlite'
            modem = FixtureModem()
            sim = '460031234567890'
            inbox = StandaloneArchive(path, 'ec20')
            inbox.bind_sim(modem, sim)
            self.assertEqual(inbox.request('GET', '/api/sms/contacts'), (200, []))
            outgoing = inbox.send(modem, '10000', 'hello')
            with patch('trial_sms.delivered', return_value=('10000', datetime.now(timezone.utc), 'reply', None)):
                self.assertTrue(inbox.ingest('c0ffee'))
                self.assertFalse(inbox.ingest('c0ffee'))
            restarted = StandaloneArchive(path, 'ec20')
            restarted.bind_sim(modem, sim)
            _, rows = restarted.request('GET', '/api/sms/thread?peer=10000')
            self.assertEqual({(row['type'], row['content']) for row in rows}, {(1, 'reply'), (2, 'hello')})
            self.assertEqual(restarted.request('DELETE', f'/api/sms/messages/{outgoing}?peer=10000'), (200, {}))
            restarted.bind_sim(modem, '460031234567891')
            self.assertEqual(restarted.request('GET', '/api/sms/contacts'), (200, []))
            with sqlite3.connect(path) as db:
                tables = {row[0] for row in db.execute("select name from sqlite_master where type='table'")}
            self.assertTrue({'devices', 'sim_cards'}.isdisjoint(tables))

    def test_import_preserves_message_id_and_id_sequence(self):
        with TemporaryDirectory() as directory:
            source = Path(directory) / 'old.sqlite'
            destination = Path(directory) / 'new.sqlite'
            modem = FixtureModem()
            old = StandaloneArchive(source, 'ec20')
            old.bind_sim(modem, '460031234567890')
            first = old.send(modem, '10000', 'history')
            deleted = old.send(modem, '10001', 'removed')
            old.request('DELETE', f'/api/sms/messages/{deleted}?peer=10001')
            self.assertEqual(import_messages(source, destination, 'ec20')['sms'], 1)
            new = StandaloneArchive(destination, 'ec20')
            new.bind_sim(modem, old.imsi)
            _, rows = new.request('GET', '/api/sms/thread?peer=10000')
            self.assertEqual(rows[0]['id'], first)
            self.assertGreater(new.send(modem, '10001', 'new message'), deleted)
            self.assertEqual(old.request('GET', '/api/sms/thread?peer=10001'), (200, []))
