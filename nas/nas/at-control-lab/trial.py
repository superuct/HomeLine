"""One exclusive AT owner for the bounded HomeLine NAS trial."""
from __future__ import annotations

from contextlib import ExitStack
from dataclasses import dataclass, field
import hmac
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import socketserver
import sqlite3
import subprocess
import threading
import termios
import time
import uuid

from app_bridge import audio_port, docker, pump, read_exact, Server
from modem import CALL_FINAL_RESULTS, CALL_STATUS_NOTICE, ModemError, address
from probe import response, serial_port
from trial_sms import Archive

AT = '/dev/ttyUSB2'
CALL_ID = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
MARKER = Path('active-radio')
BUSY = Path('active-call')
LIVE = Path('ready')
HOLD = os.environ.get('HOMELINE_AT_HOLD') == '1'
CUT_OFF = float('inf') if HOLD else time.monotonic() + 660
ACTIVE_LIMIT = float('inf') if HOLD else 180


@dataclass
class Call:
    incoming: bool
    number: str
    index: int = -1
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    state: str = ''
    changed: threading.Event = field(default_factory=threading.Event)
    done: threading.Event = field(default_factory=threading.Event)
    deadline: float = field(default_factory=lambda: time.monotonic() + 45)
    socket: socket.socket = None
    digits: str = ''
    remote_end: bool = False
    sip_channel: str = ''


class Radio:
    def __init__(self, modem, archive, token, *, pcm_fd, flush_pcm=None):
        self.modem, self.archive, self.token = modem, archive, token
        self.pcm_fd = pcm_fd
        self.flush_pcm = flush_pcm or (lambda: termios.tcflush(pcm_fd, termios.TCIOFLUSH))
        self.last_release = 0.
        self.lock = threading.RLock()
        self.sms_submission_lock = threading.Lock()
        self.active_submission = None
        self.call = None
        self.call_poll_failures = 0
        self.stopping = False
        self.status = {}
        self.events = {}
        self.sms_retry_at = {}
        self.sms_storage = None
        self.sms_deferred = set()
        self.sms_scan_at = time.monotonic()

    def initialize(self):
        m = self.modem
        m._command('AT')
        if m.calls():
            raise ModemError('EC20 has an existing call')
        if response(m, 'AT+CPIN?', r'\+CPIN:\s*(READY)') != ('READY',):
            raise ModemError('SIM not ready')
        imsi, = response(m, 'AT+CIMI', r'([0-9]{14,16})')
        self.archive.bind_sim(m, imsi)
        settings = {}
        for name, regex in [('CMGF', r'\+CMGF:\s*([01])'), ('CNMI', r'\+CNMI:\s*([\d,]+)'),
                            ('CPMS', r'\+CPMS:\s*"([A-Z]+)",\d+,\s*\d+,\s*"([A-Z]+)",\s*\d+,\s*\d+,\s*"([A-Z]+)",\s*\d+,\s*\d+')]:
            settings[name] = response(m, f'AT+{name}?', regex)
        try:
            settings['DSCI'] = response(m, 'AT^DSCI?', r'\^DSCI:\s*([01])')
        except ModemError:
            print('AT DSCI setting query unsupported', flush=True)
        self.sms_storage = settings['CPMS'][0]
        Path('sms-settings.json').write_text(json.dumps(settings))
        MARKER.touch()
        m.initialize()
        if settings.get('DSCI') != ('1',):
            try:
                m._command('AT^DSCI=1')
            except ModemError:
                print('AT DSCI enable rejected', flush=True)
            else:
                print('AT DSCI notifications enabled', flush=True)
        else:
            print('AT DSCI notifications already enabled', flush=True)
        m._command('AT+QPCMV=0')
        self.refresh()
        if not self.status['radio_registered']:
            raise ModemError('LTE not registered')

    def scan_sms(self):
        for storage in ('SM', 'ME'):
            try:
                self.select_sms_storage(storage)
                # Status 0 is unread and status 1 is read. A prior CMGR can
                # have marked a message read before it was committed to SQLite.
                for line in self.modem._command('AT+CMGL=4'):
                    slot = re.match(r'\+CMGL:\s*(\d+)\s*,\s*[01]\s*,', line)
                    if slot:
                        self.events.setdefault((storage, slot[1]), time.monotonic())
            except ModemError:
                if not self.modem.usable:
                    raise
                print('AT message store scan will retry', flush=True)

    def select_sms_storage(self, storage):
        if storage != self.sms_storage:
            self.modem._command(f'AT+CPMS="{storage}"')
            self.sms_storage = storage

    def refresh(self):
        m = self.modem
        reg, = response(m, 'AT+CEREG?', r'\+CEREG:\s*\d+,\s*(\d+)(?:,.*)?')
        csq, = response(m, 'AT+CSQ', r'\+CSQ:\s*(\d+),\s*\d+')
        try:
            operator, act = response(m, 'AT+COPS?', r'\+COPS:\s*\d+,\s*\d+,"([^"]*)",(\d+)')
        except ModemError:
            operator, act = '', ''
        registered = reg in ('1', '5')
        names = {'CHN-CT': '中国电信', '46003': '中国电信', '46005': '中国电信',
                 '46011': '中国电信', '46000': '中国移动', '46002': '中国移动',
                 '46001': '中国联通'}
        self.status = {'id': self.archive.device, 'physical_present': True, 'control_online': True,
                       'radio_registered': registered, 'healthy': registered, 'running': True,
                       'registration_state_label': {'2': 'searching', '3': 'denied'}.get(reg,
                            '已注册（AT 测试）' if registered else 'not_registered'),
                       'modem': {'operator': names.get(operator.strip().upper(), operator) if registered else '',
                                 'network_mode': 'LTE' if act in ('7', '9', '10') else '',
                                 'signal_dbm': -113 + 2 * int(csq) if int(csq) <= 31 else None}}

    def begin(self, number, sip_channel='', *, identifier=None):
        address(number)
        with self.lock:
            if self.call or self.stopping or time.monotonic() >= CUT_OFF or self.modem.calls():
                return None
            self.collect_events()
            call = self.call = Call(False, number, id=identifier or str(uuid.uuid4()), sip_channel=sip_channel)
            BUSY.touch()
            try:
                self.flush_pcm()
                self.modem._command('AT+QPCMV=1,0')
                self.modem.dial(number, timeout=7)
            except ModemError as error:
                remote = str(error) in CALL_FINAL_RESULTS
                self.end(call.id, remote=remote)
                if remote:
                    print(f'AT dial finished with {error}', flush=True)
                    return call
                raise
            except OSError:
                self.end(call.id)
                raise
            print('AT outgoing call admitted', flush=True)
            return call

    def end(self, identifier, *, remote=False, radio_idle=False):
        with self.lock:
            call = self.call
            if not call or call.id != identifier:
                return
            call.remote_end = remote
            # Wake FastAGI or close the media socket immediately. The SIP
            # leg can finish while the serial port completes its cleanup.
            call.done.set()
            call.changed.set()
            if remote and call.state == 'active' and call.sip_channel:
                threading.Thread(target=self.hangup_sip, args=(call.sip_channel,), daemon=True).start()
            if call.socket:
                try:
                    call.socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            try:
                if not radio_idle:
                    release(self.modem, call.index)
                self.modem._command('AT+QPCMV=0')
                BUSY.unlink(missing_ok=True)
                self.last_release = time.monotonic()
            except (ModemError, OSError):
                self.stopping = True
                raise
            finally:
                self.call = None
            print('AT call released' + (' (remote)' if remote else ''), flush=True)

    @staticmethod
    def hangup_sip(channel):
        # Only the exact outbound channel recorded by FastAGI is eligible.
        # This also covers a remote release before AudioSocket attaches.
        try:
            docker('exec', 'HomeLine-PBX', 'asterisk', '-rx', 'channel request hangup ' + channel)
        except (OSError, subprocess.SubprocessError):
            print('AT SIP channel release command failed', flush=True)

    def answer(self, identifier):
        with self.lock:
            call = self.call
            if not call or not call.incoming or call.id != identifier or self.stopping:
                return False
            if call.state == 'active':
                return True
            if call.state != 'incoming':
                return False
            try:
                self.flush_pcm()
                self.modem._command('AT+QPCMV=1,0')
                self.modem.answer()
                # Media can wait for CLCC while SIP confirms pickup.
                call.state = 'answering'
                return True
            except (ModemError, OSError):
                self.end(identifier)
                return False

    def start_incoming(self, leg):
        call = self.call = Call(True, leg.number if re.fullmatch(r'\+?[0-9]{2,15}', leg.number) else '',
                                leg.index, state='incoming')
        BUSY.touch()
        def originate():
            try:
                result = docker('exec', 'HomeLine-PBX', 'asterisk', '-rx',
                    f'channel originate Local/{call.id}@hl-at-audio/n extension {call.id}@hl-at-inbound')
                if 'failed' in result.lower() or 'unable' in result.lower():
                    raise OSError('Local originate failed')
            except (OSError, RuntimeError):
                self.end(call.id)
        threading.Thread(target=originate, daemon=True).start()
        print('AT incoming call detected', flush=True)

    def handle_release_notice(self, call, notices, *, radio_idle=False):
        outgoing_setup = not call.incoming and call.state != 'active'
        for notice in notices:
            indexed = re.match(r'\^CEND:\s*(\d+)\s*(?:,|$)', notice)
            status = CALL_STATUS_NOTICE.match(notice)
            if status and status.groups()[1:] == ('1' if call.incoming else '0', '6', '0'):
                indexed = status
            ends_leg = indexed and (call.index == int(indexed[1]) or (call.index == -1 and outgoing_setup))
            ends_dial = outgoing_setup and notice in CALL_FINAL_RESULTS
            carrier_lost = radio_idle and notice == 'NO CARRIER'
            if ends_leg or ends_dial or carrier_lost or notice.startswith('VOICE CALL: END'):
                print('AT modem release notice: ' + notice.split(':', 1)[0], flush=True)
                self.end(call.id, remote=True, radio_idle=radio_idle)
                return True
        return False

    def poll_call(self):
        try:
            legs = self.modem.calls()
        except ModemError as error:
            if not self.modem.usable:
                raise
            end_notices = self.collect_events()
            if self.call and self.handle_release_notice(self.call, end_notices):
                self.call_poll_failures = 0
                return
            self.call_poll_failures += 1
            if self.call_poll_failures >= 4:
                raise ModemError('EC20 rejected four consecutive call-state queries') from error
            if self.call_poll_failures == 1:
                print('AT call-state query rejected; retrying', flush=True)
            return True
        if self.call_poll_failures:
            print('AT call-state query recovered', flush=True)
            self.call_poll_failures = 0
        end_notices = self.collect_events()
        call = self.call
        if not call:
            if not self.stopping and time.monotonic() < CUT_OFF:
                incoming = next((leg for leg in legs if leg.incoming and leg.state == 'incoming'), None)
                if incoming:
                    self.start_incoming(incoming)
            return bool(legs)
        leg = next((leg for leg in legs if leg.incoming == call.incoming and call.index in (-1, leg.index)), None)
        if self.handle_release_notice(call, end_notices, radio_idle=leg is None):
            return
        if leg is None and (call.index != -1 or time.monotonic() >= call.deadline - 41):
            self.end(call.id, remote=True, radio_idle=True)
            return
        if leg is None:
            return
        call.index = leg.index
        if leg.state == 'active' and call.state != 'active':
            call.state = 'active'
            call.deadline = time.monotonic() + ACTIVE_LIMIT
            call.changed.set()
            print('AT voice connected', flush=True)
        elif leg.state == 'alerting' and call.state != 'alerting':
            call.state = 'alerting'
            call.changed.set()
            print('AT outgoing call alerting', flush=True)
        if time.monotonic() >= call.deadline:
            print('AT call deadline reached in state ' + (call.state or 'dialing'), flush=True)
            self.end(call.id)
        elif call.state == 'active' and call.digits:
            digit, call.digits = call.digits[0], call.digits[1:]
            try:
                self.modem._command(f'AT+VTS="{digit}"', timeout=2)
            except ModemError:
                print('AT keypad tone rejected', flush=True)

    def pdu(self, value, queued_at=None):
        try:
            if self.archive.ingest(value):
                detail = '' if queued_at is None else (
                    f'; queued {time.monotonic() - queued_at:.2f}s; voice {"active" if self.call else "idle"}')
                print('AT incoming message recorded' + detail, flush=True)
            # False from ingest still means the part or duplicate is durable.
            return True
        except (ValueError, IndexError):
            print('AT received an unsupported message encoding', flush=True)
            return False

    def collect_events(self):
        end_notices = []
        while self.modem.events:
            event = self.modem.events.popleft()
            slot = re.fullmatch(r'\+CMTI:\s*"(SM|ME)",\s*(\d+)', event)
            if slot:
                self.events.setdefault(slot.groups(), time.monotonic())
            elif event in CALL_FINAL_RESULTS or event.startswith(('VOICE CALL: END', '^CEND:', '^DSCI:')):
                end_notices.append(event)
        return end_notices

    def poll_sms(self):
        if self.call and self.call.state != 'active':
            return
        # Prioritize voice setup and release. In an established call, CMGR on
        # the selected store is local; changing stores can wait until idle.
        now = time.monotonic()
        candidate = next((slot for slot in self.events
                          if self.sms_retry_at.get(slot, 0) <= now and (not self.call or
                              (slot[0] == self.sms_storage and slot not in self.sms_deferred))), None)
        if candidate is None:
            return
        storage, index = candidate
        try:
            self.select_sms_storage(storage)
            data = self.modem._command(f'AT+CMGR={int(index)}')
            header = next(((i, line) for i, line in enumerate(data) if line.startswith('+CMGR:')), None)
            if header and re.match(r'\+CMGR:\s*[01]\s*,', header[1]):
                if header[0] + 1 == len(data):
                    raise ModemError('No SMS PDU')
                if self.pdu(data[header[0]+1], queued_at=self.events[candidate]):
                    self.modem._command(f'AT+CMGD={int(index)}')
        except (ModemError, sqlite3.Error):
            if not self.modem.usable:
                raise
            if self.call:
                self.sms_deferred.add(candidate)
                print('AT message read deferred until call ends', flush=True)
            else:
                self.sms_retry_at[candidate] = now + 30
                print('AT message read or cleanup will retry', flush=True)
            return
        self.events.pop(candidate)
        self.sms_retry_at.pop(candidate, None)
        self.sms_deferred.discard(candidate)

    def send_message(self, number, message, request_id=None):
        address(number)
        if not isinstance(message, str) or not 1 <= len(message.encode('utf-16-be')) <= 1024:
            raise ValueError('Invalid message length')
        request_id = str(uuid.UUID(request_id)) if request_id is not None else str(uuid.uuid4())
        fingerprint = hashlib.sha256(json.dumps([number, message], ensure_ascii=False).encode()).hexdigest()
        with self.sms_submission_lock:
            if self.active_submission and self.active_submission != request_id:
                return 409, {'error': 'sms_busy'}
            prior = self.archive.claim_send(request_id, fingerprint)
            if prior:
                saved_fingerprint, status, result = prior
                if saved_fingerprint != fingerprint:
                    return 409, {'error': 'request_conflict'}
                if status:
                    return status, json.loads(result)
                if self.active_submission == request_id:
                    return 202, {'state': 'sending'}
                return 409, {'error': 'send_uncertain'}
            self.active_submission = request_id

        attempted = False
        deadline = time.monotonic() + 75
        response = None

        def send_part(pdu):
            nonlocal attempted
            delay = .75 - (time.monotonic() - self.last_release)
            if delay > 0:
                time.sleep(delay)
            with self.lock:
                if (self.stopping or not self.modem.usable or self.poll_call() or self.call
                        or time.monotonic() + 8 > min(deadline, CUT_OFF)):
                    raise ModemError('Voice busy or SMS deadline reached')
                attempted = True
                return self.modem._command(f'AT+CMGS={len(pdu)-1}', pdu=pdu, timeout=8)

        try:
            id_ = self.archive.send(self.modem, number, message, send_part=send_part)
            response = 200, {'id': id_}
        except (ModemError, OSError, sqlite3.Error):
            response = 409, {'error': 'send_uncertain' if attempted else 'voice_busy'}
        else:
            print('AT outgoing message submitted', flush=True)
        finally:
            # Keep a crash-interrupted claim pending on disk so a retry
            # cannot submit an already transmitted segment again.
            with self.sms_submission_lock:
                try:
                    if response is not None:
                        if response[1].get('error') == 'voice_busy':
                            self.archive.abandon_unstarted_send(request_id)
                        else:
                            self.archive.finish_send(request_id, *response)
                finally:
                    self.active_submission = None
        return response

    def queue_digit(self, digit):
        with self.lock:
            if self.call and self.call.state == 'active' and re.fullmatch('[0-9*#A-D]', digit):
                if len(self.call.digits) < 12:
                    self.call.digits += digit

    def run(self):
        next_status = time.monotonic() + 15
        while not self.stopping and self.modem.usable:
            with self.lock:
                self.poll_call()
                self.poll_sms()
                if not self.call and time.monotonic() >= next_status:
                    self.refresh()
                    next_status = time.monotonic() + 15
                if not self.call and time.monotonic() >= self.sms_scan_at:
                    self.scan_sms()
                    self.sms_scan_at = time.monotonic() + 300
            time.sleep(.25)


def release(modem, index):
    legs = modem.calls()
    if legs and (index == -1 or any(leg.index == index for leg in legs)):
        modem.hangup(voice=True)
        for _ in range(8):
            time.sleep(.2)
            if not modem.calls():
                return
        raise ModemError('EC20 call did not clear')


def restore(at=AT):
    if not MARKER.exists():
        return
    with serial_port(at) as modem:
        modem._command('AT')
        if BUSY.exists():
            release(modem, -1)
            BUSY.unlink()
        modem._command('AT+QPCMV=0')
        s = json.loads(Path('sms-settings.json').read_text())
        if s.get('DSCI') == ['0']:
            try:
                modem._command('AT^DSCI=0')
            except ModemError:
                print('AT DSCI restore rejected', flush=True)
        modem._command('AT+CNMI=' + s['CNMI'][0])
        modem._command('AT+CMGF=' + s['CMGF'][0])
        modem._command('AT+CPMS=' + ','.join(f'"{memory}"' for memory in s['CPMS']))
    MARKER.unlink()


class AGI(socketserver.StreamRequestHandler):
    def send_agi(self, command):
        self.wfile.write((command + '\n').encode())
        return self.rfile.readline(1024).startswith(b'200 result=1')

    def handle(self):
        self.connection.settimeout(4)
        fields = {}
        for _ in range(64):
            line = self.rfile.readline(2048).decode(errors='replace').strip()
            if not line:
                break
            key, _, value = line.partition(': ')
            fields[key] = value
        radio = self.server.radio
        route, _, arg = fields.get('agi_network_script', '').partition('/')
        if route == 'start':
            number = fields.get('agi_extension', '')
            if not re.fullmatch(r'\+?[0-9]{2,15}', number):
                return
            channel = fields.get('agi_channel', '')
            if not re.fullmatch(r'PJSIP/[A-Za-z0-9_-]+-[0-9a-fA-F]+', channel):
                channel = ''
            call = radio.begin(number, channel)
            if not call:
                return
            handed_off = False
            ringing = False
            try:
                while not call.done.is_set():
                    if select.select([self.connection], [], [], 0)[0]:
                        return
                    if call.state == 'active':
                        handed_off = self.send_agi(f'SET VARIABLE HL_AT_ID "{call.id}"')
                        return
                    if call.state == 'alerting' and not ringing:
                        self.send_agi('EXEC Ringing')
                        ringing = True
                    call.changed.wait(.15)
                    call.changed.clear()
                if call.remote_end:
                    self.send_agi('SET VARIABLE HL_AT_REMOTE_END 1')
            finally:
                if not handed_off:
                    radio.end(call.id)
        elif re.fullmatch(CALL_ID, arg):
            if route == 'identify':
                with radio.lock:
                    call = radio.call
                    if call and call.id == arg and call.incoming:
                        if call.number:
                            self.send_agi(f'SET CALLERID {call.number}')
                        self.send_agi(f'SET VARIABLE HL_AT_ID "{arg}"')
            elif route == 'answer' and radio.answer(arg):
                self.send_agi('SET VARIABLE HL_AT_ANSWER 1')
            elif route == 'end':
                radio.end(arg)


class Audio(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(3)
        if read_exact(self.connection, 3) != b'\x01\x00\x10':
            return
        ident = read_exact(self.connection, 16)
        if len(ident) != 16:
            return
        identifier = str(uuid.UUID(bytes=ident))
        radio = self.server.radio
        with radio.lock:
            call = radio.call
            if not call or call.id != identifier or call.socket:
                return
            call.socket = self.connection
        try:
            # The Local leg exists before the phone answers. Peek for EOF
            # without consuming a partial AudioSocket header or PCM sample.
            while call.state != 'active' and not call.done.is_set():
                if select.select([self.connection], [], [], .1)[0]:
                    if not self.connection.recv(1, socket.MSG_PEEK):
                        return
                    call.done.wait(.1)
            if call.done.is_set():
                return
            counts = pump(self.connection, radio.pcm_fd, None, call.done, duration=ACTIVE_LIMIT + 5,
                          check_call=lambda: call.state == 'active')
            print('AT media bytes:', counts, flush=True)
        finally:
            radio.end(identifier)


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_request()

    do_POST = do_DELETE = do_GET

    def handle_request(self):
        radio = self.server.radio
        try:
            if not hmac.compare_digest(self.headers.get('X-HomeLine-AT', ''), radio.token):
                status, data = 403, {}
            elif self.command == 'GET' and self.path == '/api/devices':
                status, data = 200, {'devices': [radio.status]}
            elif self.command == 'POST' and self.path == '/api/sms/send':
                size = int(self.headers.get('Content-Length', 0))
                if not 1 <= size <= 65536:
                    raise ValueError('Request size')
                value = json.loads(self.rfile.read(size))
                if (value.get('device_id') != radio.archive.device
                        or value.get('imsi') not in (None, '', radio.archive.imsi)):
                    print('AT SMS not submitted: device or SIM mismatch', flush=True)
                    status, data = 404, {'error': 'device_or_sim'}
                else:
                    try:
                        status, data = radio.send_message(value['phone'], value['message'], value.get('request_id'))
                    except (TypeError, ValueError, KeyError):
                        print('AT SMS not submitted: invalid request', flush=True)
                        status, data = 400, {'error': 'invalid_request'}
                    except ModemError as exc:
                        print('AT SMS command rejected:', str(exc), flush=True)
                        status, data = 502, {'error': 'modem_rejected'}
                    except TimeoutError:
                        print('AT SMS modem response timed out', flush=True)
                        status, data = 504, {'error': 'modem_timeout'}
                    except (OSError, sqlite3.Error) as exc:
                        print('AT SMS I/O failed:', type(exc).__name__, flush=True)
                        status, data = 502, {'error': 'storage_or_transport'}
            elif self.command == 'POST' and (match := re.fullmatch(r'/at/(answer|end)/(' + CALL_ID + ')', self.path)):
                action, identifier = match.groups()
                if action == 'end':
                    radio.end(identifier)
                    status, data = 200, {}
                else:
                    status, data = (200 if radio.answer(identifier) else 409), {}
            else:
                status, data = radio.archive.request(self.command, self.path)
        except (TypeError, ValueError, AttributeError, KeyError):
            status, data = 400, {}
        except (ModemError, OSError, sqlite3.Error):
            status, data = 502, {}
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def ami_packet(stream):
    fields = {}
    while line := stream.readline(4096):
        if line == b'\r\n':
            return fields
        key, _, value = line.decode(errors='replace').strip().partition(': ')
        fields[key] = value
    raise OSError('PBX event stream ended')


def ami_events(radio, sock, stream, prefix):
    try:
        sock.settimeout(None)
        while not radio.stopping:
            msg = ami_packet(stream)
            if (msg.get('Event') == 'DTMFEnd' and msg.get('Direction') == 'Received'
                    and msg.get('Channel', '').startswith(prefix)):
                radio.queue_digit(msg.get('Digit', ''))
    except OSError:
        radio.stopping = True


def run():
    cfg = json.loads(Path('/etc/homeline-unified/config.json').read_text())
    with ExitStack() as stack:
        modem = stack.enter_context(serial_port(AT))
        pcm_fd = stack.enter_context(audio_port())
        radio = Radio(modem, Archive(cfg['sms_db'], cfg['device']), Path('token').read_text().strip(), pcm_fd=pcm_fd)
        radio.initialize()
        for server_type, port, handler in [(Server, 14673, AGI), (Server, 14674, Audio),
                                            (ThreadingHTTPServer, 14675, API)]:
            server = stack.enter_context(server_type(('127.0.0.1', port), handler))
            server.radio = radio
            threading.Thread(target=server.serve_forever, daemon=True).start()
        for attempt in range(5):
            try:
                with ExitStack() as pending:
                    sock = pending.enter_context(socket.create_connection(('127.0.0.1', 15038), 2))
                    stream = pending.enter_context(sock.makefile('rb'))
                    if not stream.readline(4096).startswith(b'Asterisk Call Manager/'):
                        raise OSError('PBX event stream greeting unavailable')
                    sock.sendall(f'Action: Login\r\nUsername: homeline-at\r\nSecret: {radio.token}\r\nEvents: on\r\n\r\n'.encode())
                    if ami_packet(stream).get('Response') != 'Success':
                        raise OSError('PBX did not accept the trial event subscription')
                    stack.enter_context(pending.pop_all())
                    break
            except OSError:
                if attempt == 4:
                    raise
                time.sleep(.25)
        prefix = 'PJSIP/' + str(cfg['sip_user']) + '-'
        threading.Thread(target=ami_events, args=(radio, sock, stream, prefix), daemon=True).start()
        LIVE.touch()
        signal.signal(signal.SIGTERM, lambda *_: setattr(radio, 'stopping', True))
        print('HomeLine AT modem ready', flush=True)
        try:
            radio.run()
        finally:
            sock.shutdown(socket.SHUT_RDWR)


if __name__ == '__main__':
    import sys
    if sys.argv[1:] == ['--restore']:
        restore()
    else:
        run()
