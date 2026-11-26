"""Exercise the call lifecycle without using a modem or sending a push."""
from pathlib import Path
import socket
from tempfile import TemporaryDirectory
from unittest import TestCase, main
from unittest.mock import patch
import uuid

from radio import Calls
from modem import Modem
from trial import Call, Radio


class FixtureMedia:
    def __init__(self):
        self.connection_state = 'new'
        self.enabled = False
        self.closed = False

    def offer(self, sdp):
        return {'sdp': sdp, 'type': 'answer'}

    def status(self):
        return {'state': self.connection_state}

    def state(self):
        return self.connection_state

    def enable(self):
        self.enabled = True

    def close(self):
        self.closed = True


class FixtureRadio:
    call = None
    dial_count = 0

    def begin(self, number, *, identifier):
        self.dial_count += 1
        self.call = Call(False, number, id=identifier, state='dialing')
        return self.call

    def answer(self, identifier):
        if not self.call or self.call.id != identifier:
            return False
        self.call.state = 'active'
        return True

    def end(self, identifier):
        if self.call and self.call.id == identifier:
            self.call = None


class CallsTests(TestCase):
    def setUp(self):
        self.radio = FixtureRadio()
        self.media = FixtureMedia()
        self.notifications = []
        self.service = Calls(self.radio, lambda _: self.media, self.notifications.append)
        self.id = str(uuid.uuid4())
        self.path = '/api/homeline/rtc/calls/' + self.id

    def post(self, action, body=None):
        return self.service.request('POST', self.path + '/' + action, body or {})

    def test_outgoing_dials_once_only_after_ice_then_reports_remote_release(self):
        self.assertEqual(self.post('offer', {'sdp': 'fixture', 'phone': '10000'})[0], 200)
        self.assertEqual(self.post('connect'), (409, {'state': 'ice_pending'}))
        self.assertEqual(self.radio.dial_count, 0)
        self.media.connection_state = 'connected'
        self.assertEqual(self.post('connect')[0], 200)
        self.assertEqual(self.post('connect')[0], 200)
        self.assertEqual(self.radio.dial_count, 1)
        self.radio.call.state = 'active'
        self.service.tick(self.service.current, 0)
        self.assertTrue(self.media.enabled)
        self.radio.call = None
        self.service.tick(self.service.current, 0)
        self.assertTrue(self.media.closed)
        self.assertEqual(self.service.request('GET', self.path, {}), (200, {'state': 'ended'}))

    def test_end_visible_while_radio_is_still_cleaning_up(self):
        self.assertEqual(self.post('offer', {'sdp': 'fixture', 'phone': '10000'})[0], 200)
        self.media.connection_state = 'connected'
        self.assertEqual(self.post('connect')[0], 200)
        self.radio.call.state = 'alerting'
        self.radio.call.done.set()
        self.service.tick(self.service.current, 0)
        self.assertEqual(self.service.request('GET', self.path, {}), (200, {'state': 'ended'}))
        self.assertFalse(self.media.closed)
        self.radio.call = None
        self.service.tick(self.service.current, 0)
        self.assertTrue(self.media.closed)

    def test_late_offer_cannot_revive_rejected_incoming_call(self):
        self.radio.call = Call(True, '13800138000', id=self.id, state='incoming')
        self.service.new_incoming(self.radio.call)
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.post('end'), (200, {'state': 'ended'}))
        self.assertIsNone(self.radio.call)
        self.assertEqual(self.post('offer', {'sdp': 'late'}), (410, {'state': 'ended'}))

    def test_accept_incoming_uses_existing_call_uuid(self):
        self.radio.call = Call(True, '13800138000', id=self.id, state='incoming')
        self.service.new_incoming(self.radio.call)
        self.assertEqual(self.post('offer', {'sdp': 'fixture'})[0], 200)
        self.media.connection_state = 'connected'
        self.assertEqual(self.post('connect')[0], 200)
        self.service.tick(self.service.current, 0)
        self.assertTrue(self.media.enabled)
        self.assertEqual(self.radio.call.id, self.id)
        self.assertEqual(self.post('end')[0], 200)
        self.assertTrue(self.media.closed)



class SerialReleaseTests(TestCase):
    def dial_and_alert(self, radio, serial):
        media = FixtureMedia()
        service = Calls(radio, lambda _: media, lambda _: None)
        path = '/api/homeline/rtc/calls/' + str(uuid.uuid4())
        self.assertEqual(service.request('POST', path + '/offer', {'sdp': 'test', 'phone': '10000'})[0], 200)
        media.connection_state = 'connected'
        serial.sendall(b'OK\r\nOK\r\nOK\r\n')
        self.assertEqual(service.request('POST', path + '/connect', {})[0], 200)
        serial.sendall(b'+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n')
        radio.poll_call()
        self.assertEqual(service.request('GET', path, {})[1]['state'], 'alerting')
        return service, path, media

    def test_release_notice_overrides_old_alerting_or_query_error(self):
        replies = [
            b'BUSY\r\n+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n',
            b'NO ANSWER\r\nERROR\r\n',
            b'NO CARRIER\r\n+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n',
            b'^CEND: 1,0,0,21\r\n+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n',
            b'^DSCI: 1,0,6,0,"10000",129\r\n+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n',
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                host, serial = socket.socketpair()
                with host, serial, TemporaryDirectory() as work, patch('trial.BUSY', Path(work) / 'active-call'):
                    radio = Radio(Modem(host.fileno()), None, '', pcm_fd=-1, flush_pcm=lambda: None)
                    service, path, media = self.dial_and_alert(radio, serial)
                    serial.sendall(reply + b'OK\r\nOK\r\n')
                    radio.poll_call()
                    self.assertIsNone(radio.call)
                    self.assertTrue(radio.modem.usable)
                    self.assertEqual(service.request('GET', path, {}), (200, {'state': 'ended'}))
                    service.tick(service.current, 0)
                    self.assertTrue(media.closed)

    def test_dsci_setting_response_and_unrelated_legs(self):
        host, serial = socket.socketpair()
        with host, serial, TemporaryDirectory() as work, patch('trial.BUSY', Path(work) / 'active-call'):
            radio = Radio(Modem(host.fileno()), None, '', pcm_fd=-1, flush_pcm=lambda: None)
            serial.sendall(b'^DSCI: 1\r\nOK\r\n')
            self.assertEqual(radio.modem._command('AT^DSCI?'), ['^DSCI: 1'])
            service, path, _ = self.dial_and_alert(radio, serial)
            serial.sendall(b'^DSCI: 2,0,6,0,"10000",129\r\n'
                           b'^DSCI: 1,1,6,0,"10000",129\r\n'
                           b'^DSCI: 1,0,6,1,"10000",129\r\n'
                           b'^DSCI: 1,0,3,0,"10000",129\r\n'
                           b'+CLCC: 1,0,3,0,0,"10000",129\r\nOK\r\n')
            radio.poll_call()
            self.assertEqual(service.request('GET', path, {})[1]['state'], 'alerting')

    def test_unrelated_busy_does_not_end_connected_leg(self):
        host, serial = socket.socketpair()
        with host, serial, TemporaryDirectory() as work, patch('trial.BUSY', Path(work) / 'active-call'):
            radio = Radio(Modem(host.fileno()), None, '', pcm_fd=-1, flush_pcm=lambda: None)
            service, path, _ = self.dial_and_alert(radio, serial)
            serial.sendall(b'+CLCC: 1,0,0,0,0,"10000",129\r\nOK\r\n')
            radio.poll_call()
            service.tick(service.current, 0)
            serial.sendall(b'BUSY\r\n+CLCC: 1,0,0,0,0,"10000",129\r\nOK\r\n')
            radio.poll_call()
            self.assertEqual(service.request('GET', path, {})[1]['state'], 'active')

if __name__ == '__main__':
    main()
