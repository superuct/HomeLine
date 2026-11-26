"""WebRTC call signaling and EC20 ownership without a SIP/PBX process."""
from contextlib import ExitStack
from dataclasses import dataclass
import hmac
import http.client
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import struct
import signal
import subprocess
import sys
import threading
import time
import traceback
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'at-control-lab'))
from app_bridge import PCM, audio_port
from modem import ModemError, address
from probe import serial_port
os.environ.setdefault('HOMELINE_AT_HOLD', '1')
from trial import API as RadioAPI, AT, BUSY, Call, Radio, CALL_ID, restore
from sms_archive import StandaloneArchive

MAX_RECORDING_BYTES = 30 * 60 * 8000 * 2
RECORDING_TTL = 60 * 60


class WebRTCRadio(Radio):
    def start_incoming(self, leg):
        number = leg.number if re.fullmatch(r'\+?[0-9]{2,15}', leg.number) else ''
        call = self.call = Call(True, number, leg.index, state='incoming')
        BUSY.touch()
        # Call the signal layer outside the radio's serialization lock.
        threading.Thread(target=self.incoming_notice, args=(call,), daemon=True).start()


class Media:
    def __init__(self, binary, pcm_fd, ice, public_ip, token_file, token, recording_file):
        self.token = token
        self.process = subprocess.Popen(
            [binary, '-pcm-fd', str(pcm_fd), '-ice', ice, '-public-ip', public_ip,
             '-token-file', str(token_file), '-recording-file', str(recording_file)], pass_fds=(pcm_fd,))

    def request(self, method, path, value=None, timeout=5):
        conn = http.client.HTTPConnection('127.0.0.1', 14676, timeout=timeout)
        try:
            conn.request(method, path, json.dumps(value) if value is not None else None,
                         {'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
            r = conn.getresponse()
            data = r.read()
            if r.status >= 300:
                raise OSError(f'WebRTC media service returned {r.status}')
            return json.loads(data) if data else None
        finally:
            conn.close()

    def offer(self, sdp):
        for _ in range(12):
            try:
                return self.request('POST', '/offer', {'type': 'offer', 'sdp': sdp})
            except ConnectionRefusedError:
                if self.process.poll() is not None:
                    raise
                time.sleep(.1)
        raise OSError('WebRTC media service did not start')

    def status(self):
        return self.request('GET', '/status', timeout=.5)

    def state(self):
        return self.status()['state']

    def enable(self):
        self.request('PUT', '/media', timeout=.5)

    def start_recording(self):
        self.request('PUT', '/recording', timeout=2)

    def stop_recording(self):
        self.request('DELETE', '/recording', timeout=2)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


@dataclass
class Session:
    id: str
    phone: str
    incoming: bool
    expires: float
    media: Media = None
    started: bool = False
    enabled: bool = False
    disconnected_at: float = 0
    codec: str = ''
    recording: bool = False


class Calls:
    def __init__(self, radio, create_media, notify, recordings=None):
        self.radio = radio
        self.create_media, self.notify = create_media, notify
        self.recordings = recordings
        self.current = None
        self.ended = {}
        self.lock = threading.RLock()

    def new_incoming(self, call):
        with self.lock:
            if self.radio.call is not call:
                return
            if self.current:
                self.end(self.current.id)
            self.current = Session(call.id, call.number, True, call.deadline)
        self.notify(call)

    def end(self, identifier):
        with self.lock:
            session = self.current
            if not session or session.id != identifier:
                return
            self.current = None
            self.ended[identifier] = time.monotonic() + 120
            try:
                self.radio.end(identifier)
            finally:
                if session.media:
                    session.media.close()
                self.finalize_recording(session.id)

    def finalize_recording(self, identifier):
        if self.recordings is None:
            return False
        raw = self.recordings / (identifier + '.pcm')
        ready = self.recordings / (identifier + '.ready')
        if raw.exists():
            if raw.stat().st_size >= 320:
                raw.replace(ready)
                os.utime(ready)
            else:
                raw.unlink()
        return ready.exists()

    def recording_file(self, identifier):
        return self.recordings / (identifier + '.ready')

    def maintain(self):
        next_cleanup = 0
        while not self.radio.stopping:
            with self.lock:
                now = time.monotonic()
                self.ended = {key: expiry for key, expiry in self.ended.items() if expiry > now}
                session = self.current
                if session:
                    self.tick(session, now)
                if self.recordings is not None and now >= next_cleanup:
                    next_cleanup = now + 60
                    limit = time.time() - RECORDING_TTL
                    for file in self.recordings.iterdir():
                        if file.suffix not in ('.pcm', '.ready') or (session and file.stem == session.id):
                            continue
                        try:
                            if file.stat().st_mtime < limit:
                                file.unlink(missing_ok=True)
                        except FileNotFoundError:
                            continue
            time.sleep(.2)

    def tick(self, session, now):
        call = self.radio.call
        if call and call.id == session.id and call.done.is_set():
            # The radio owns serial cleanup. Do not block HTTPS status on it.
            return
        if (not session.started and now >= session.expires) or (
                (session.started or session.incoming) and (not call or call.id != session.id)):
            self.end(session.id)
            return
        if not session.media:
            return
        try:
            media = session.media.status()
            state = media['state']
            session.codec = media.get('codec', '')
            if state in ('failed', 'closed'):
                self.end(session.id)
            elif state == 'disconnected':
                if not session.disconnected_at:
                    session.disconnected_at = now
                elif now - session.disconnected_at > 6:
                    self.end(session.id)
            elif state == 'connected':
                session.disconnected_at = 0
                if session.started and call and call.state == 'active' and not session.enabled:
                    session.media.enable()
                    session.enabled = True
                    print('WebRTC media and EC20 call active', flush=True)
        except OSError:
            self.end(session.id)

    def request(self, method, path, body):
        if method == 'GET' and path == '/api/homeline/rtc/capabilities':
            return 200, {'transport': 'webrtc', 'version': 1, 'recording': self.recordings is not None}
        match = re.fullmatch(r'/api/homeline/rtc/calls/(' + CALL_ID + r')(?:/(offer|connect|end|digit|record-start|record-stop))?', path)
        if not match:
            return 404, {}
        identifier, action = match.groups()
        with self.lock:
            session = self.current
            if method == 'GET' and action is None:
                if not session or session.id != identifier:
                    return 200, {'state': 'ended'}
                call = self.radio.call
                matching_call = call is not None and call.id == identifier
                if (matching_call and call.done.is_set()) or (not matching_call and (session.started or session.incoming)):
                    return 200, {'state': 'ended'}
                state = call.state if matching_call else 'preparing'
                if state == 'active' and not session.enabled:
                    state = 'connecting'
                return 200, {'state': state or 'dialing', 'codec': session.codec}
            if method != 'POST' or action is None:
                return 405, {}
            if action == 'end':
                self.end(identifier)
                self.ended[identifier] = time.monotonic() + 120
                return 200, {'state': 'ended'}
            if action == 'record-stop' and self.recordings is not None and self.recording_file(identifier).is_file():
                return 200, {'ready': True}
            if identifier in self.ended:
                return 410, {'state': 'ended'}
            if action == 'offer':
                sdp = body.get('sdp')
                if not isinstance(sdp, str) or not sdp or len(sdp) > 48000:
                    return 400, {}
                if not session:
                    phone = body.get('phone')
                    if not isinstance(phone, str):
                        return 410, {'state': 'ended'}
                    address(phone)
                    if self.radio.call:
                        return 409, {'state': 'busy'}
                    session = self.current = Session(identifier, phone, False, time.monotonic() + 30)
                if session.id != identifier:
                    return 409, {'state': 'busy'}
                if not session.media:
                    session.media = self.create_media(identifier)
                try:
                    return 200, session.media.offer(sdp)
                except (OSError, ValueError):
                    self.end(identifier)
                    raise
            if not session or session.id != identifier or not session.media:
                return 410, {'state': 'ended'}
            if action == 'connect':
                if session.started:
                    return 200, {'state': 'connecting'}
                if session.media.state() != 'connected':
                    return 409, {'state': 'ice_pending'}
                if session.incoming:
                    started = self.radio.answer(identifier)
                else:
                    call = self.radio.begin(session.phone, identifier=identifier)
                    started = call is not None and not call.done.is_set()
                if not started:
                    self.end(identifier)
                    return 409, {'state': 'unavailable'}
                session.started = True
                return 200, {'state': 'connecting'}
            if action in ('record-start', 'record-stop'):
                if self.recordings is None or not session.enabled:
                    return 409, {}
                if action == 'record-start':
                    if self.recording_file(identifier).exists():
                        return 409, {}
                    session.media.start_recording()
                    session.recording = True
                    return 200, {'recording': True}
                if session.recording:
                    session.media.stop_recording()
                    session.recording = False
                return 200, {'ready': self.finalize_recording(identifier)}
            call = self.radio.call
            digit = body.get('digit')
            if not call or call.id != identifier or call.state != 'active':
                return 409, {'state': 'ended'}
            if not isinstance(digit, str) or not re.fullmatch(r'[0-9*#]', digit):
                return 400, {}
            self.radio.queue_digit(digit)
            return 200, {}


def start_server(stack, address_, handler, **attributes):
    server = stack.enter_context(ThreadingHTTPServer(address_, handler))
    for key, value in attributes.items():
        setattr(server, key, value)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def supervise_worker(task, stopping, recover):
    try:
        task()
    except Exception:
        traceback.print_exc()
    finally:
        if not stopping():
            print(f'HomeLine worker exited: {task.__name__}', file=sys.stderr, flush=True)
            recover()


def main():
    import argparse
    args = argparse.ArgumentParser()
    args.add_argument('--listen', required=True, help='IP address for standalone HTTPS')
    args.add_argument('--port', type=int, required=True, help='HTTPS port')
    args.add_argument('--edge-http', action='store_true', help='serve the existing TLS relay on its loopback API port')
    args.add_argument('--http-only', action='store_true', help='serve only a local origin for a TLS-terminating gateway')
    args.add_argument('--at', default=AT)
    args.add_argument('--pcm', default=PCM)
    args.add_argument('--media', required=True, help='path to Pion media executable')
    args.add_argument('--ice', required=True, help='UDP listen address for ICE')
    args.add_argument('--public-ip', default='')
    args.add_argument('--work', required=True, help='private directory for radio restore markers')
    args.add_argument('--sms-db', help='HomeLine SMS database (defaults to messages.sqlite in the work directory)')
    args.add_argument('--sms-port', type=int, default=14675, help='private loopback port for the internal SMS handler')
    options = args.parse_args()
    if options.http_only and (options.listen != '127.0.0.1' or options.edge_http):
        args.error('--http-only requires loopback and cannot use --edge-http')
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'deploy'))
    import gateway
    gateway.BASE = gateway.BASE.resolve()
    gateway.STATE = gateway.STATE.resolve()
    media_binary = str(Path(options.media).resolve())
    gateway.C = json.loads((gateway.BASE / 'config.json').read_text())
    config = gateway.C
    config['voice_transport'] = 'webrtc'
    if not 1 <= options.sms_port <= 65535:
        args.error('invalid SMS port')
    sms_db = Path(options.sms_db).resolve() if options.sms_db else Path(options.work).resolve() / 'messages.sqlite'
    if 'sms_db' in config and sms_db == Path(config['sms_db']).resolve():
        raise SystemExit('Choose a separate database for the standalone SMS archive')
    config['sms_db'] = str(sms_db)
    os.umask(0o077)
    os.chdir(options.work)
    if Path('active-radio').exists():
        raise SystemExit('Restore the previous AT session before restarting')
    token = secrets.token_hex(32)
    token_file = Path('media-token').resolve()
    token_file.write_text(token)
    with ExitStack() as stack:
        modem = stack.enter_context(serial_port(options.at))
        pcm = stack.enter_context(audio_port(options.pcm))
        radio = WebRTCRadio(modem, StandaloneArchive(config['sms_db'], config['device']), token, pcm_fd=pcm)

        def notify(call):
            with gateway.database() as db:
                target = db.execute('select voip,owner from phone where id=1').fetchone()
            if target and target[0]:
                accepted = gateway.apple('voip', target[0], {'aps': {}, 'installation': target[1],
                    'uuid': call.id, 'caller': call.number, 'voice': 'webrtc'})
                print('WebRTC incoming PushKit request ' + ('accepted' if accepted else 'failed'), flush=True)

        recordings = Path('recordings').resolve()
        recordings.mkdir(mode=0o700, exist_ok=True)
        calls = Calls(radio, lambda identifier: Media(media_binary, pcm, options.ice, options.public_ip,
            token_file, token, recordings / (identifier + '.pcm')), notify, recordings)
        radio.incoming_notice = calls.new_incoming

        def local_sms(method, path, body):
            conn = http.client.HTTPConnection('127.0.0.1', options.sms_port, timeout=105)
            try:
                conn.request(method, path, body, {'X-HomeLine-AT': token})
                response_ = conn.getresponse()
                data = response_.read()
                if method == 'GET' and path == '/api/devices' and response_.status == 200:
                    status = json.loads(data)
                    status['voiceTransport'] = 'webrtc'
                    status['pushDelivery'] = gateway.push_status()
                    data = json.dumps(status).encode()
                return response_.status, data
            finally:
                conn.close()
        gateway.sms_request = local_sms

        class API(gateway.API):
            protocol_version = 'HTTP/1.1'

            def handle_api(self):
                path = urlsplit(self.path).path
                if not path.startswith('/api/homeline/rtc/'):
                    return super().handle_api()
                if not hmac.compare_digest(self.headers.get('Authorization', '').encode(),
                                           ('Bearer ' + config['token']).encode()):
                    self.close_connection = True
                    return self.reply(401)
                download = re.fullmatch(r'/api/homeline/rtc/calls/(' + CALL_ID + r')/recording', path)
                if download and self.command in ('GET', 'DELETE'):
                    return self.send_recording(download[1])
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 <= size <= 65536 or self.headers.get('Transfer-Encoding'):
                        self.close_connection = True
                        return self.reply(400)
                    data = json.loads(self.rfile.read(size)) if size else {}
                    if not isinstance(data, dict):
                        return self.reply(400)
                    status, value = calls.request(self.command, path, data)
                    self.reply(status, value)
                except (TypeError, ValueError):
                    self.reply(400)
                except (OSError, ModemError, http.client.HTTPException):
                    self.reply(502)
            def send_recording(self, identifier):
                file = calls.recording_file(identifier)
                if self.command == 'DELETE':
                    file.unlink(missing_ok=True)
                    return self.reply(200)
                try:
                    audio = file.open('rb')
                except FileNotFoundError:
                    return self.reply(404)
                with audio:
                    size = min(os.fstat(audio.fileno()).st_size, MAX_RECORDING_BYTES)
                    size -= size % 2
                    if size < 320:
                        return self.reply(404)
                    header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size + 36,
                        b'WAVE', b'fmt ', 16, 1, 1, 8000, 16000, 2, 16, b'data', size)
                    self.send_response(200)
                    self.send_header('Content-Type', 'audio/wav')
                    self.send_header('Content-Length', str(size + len(header)))
                    self.send_header('Cache-Control', 'no-store')
                    self.end_headers()
                    try:
                        self.wfile.write(header)
                        remaining = size
                        while remaining:
                            chunk = audio.read(min(65536, remaining))
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            remaining -= len(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

            do_GET = do_POST = do_DELETE = handle_api

        gateway.initialize_state()
        radio.initialize()
        start_server(stack, ('127.0.0.1', options.sms_port), RadioAPI, radio=radio)
        if options.edge_http:
            start_server(stack, ('127.0.0.1', config['api_port']), API)
        class HTTPS(ThreadingHTTPServer):
            def get_request(self):
                connection, address_ = super().get_request()
                connection.settimeout(8)
                try:
                    return tls.wrap_socket(connection, server_side=True, do_handshake_on_connect=False), address_
                except OSError:
                    connection.close()
                    raise

        server_class = ThreadingHTTPServer
        if not options.http_only:
            tls = gateway.tls_context(gateway.BASE / 'fullchain.pem', gateway.BASE / 'tls.key')
            server_class = HTTPS
        server = stack.enter_context(server_class((options.listen, options.port), API))
        shutdown = threading.Event()
        def stop(*_):
            shutdown.set()
            radio.stopping = True
        def recover():
            radio.stopping = True
        signal.signal(signal.SIGTERM, stop)
        for task in (server.serve_forever, gateway.sms_loop, calls.maintain):
            threading.Thread(target=supervise_worker, args=(task, shutdown.is_set, recover), daemon=True).start()
        print('HomeLine WebRTC/AT ready', flush=True)
        try:
            radio.run()
        finally:
            radio.stopping = True
            with calls.lock:
                if calls.current:
                    calls.end(calls.current.id)
        if not shutdown.is_set():
            raise RuntimeError('HomeLine media or modem service needs recovery')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--restore']:
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--at', default=AT)
        restore(parser.parse_args(sys.argv[2:]).at)
    else:
        main()
