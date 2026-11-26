#!/usr/bin/env python3
"""Temporary App-to-EC20 outbound test route, bound only to localhost."""
from contextlib import contextmanager
from collections import deque
import fcntl
import os
import select
import signal
import socket
import socketserver
import subprocess
import termios
import threading
import time
import tty
import uuid
from pathlib import Path

from hotline_test import DIAL_MARKER, test_leg, release
from modem import ModemError
from probe import response, serial_port

VOICE = 'EC20-Voice'
PBX = 'HomeLine-PBX'
AT = '/dev/ttyUSB2'
PCM = '/dev/ttyUSB1'
RESTORE = Path('restore-needed')
PCM_MARKER = Path('pcm-armed')
ADMISSION_UNTIL = time.monotonic() + 225


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True, timeout=9)


def channels(container):
    text = docker('exec', container, 'asterisk', '-rx', 'core show channels count')
    return int(next(line.split()[0] for line in text.splitlines() if line.endswith(' active channels')))


@contextmanager
def exclusive_modem():
    if channels(VOICE) != 0 or channels(PBX) != 1:
        raise ModemError('Unexpected activity on the phone line')
    docker('exec', VOICE, '/usr/local/libexec/homeline-check-ims')
    pid = docker('inspect', '-f', '{{.State.Pid}}', VOICE).strip()
    owner = subprocess.check_output(['fuser', AT], stderr=subprocess.DEVNULL, text=True, timeout=3).split()
    if owner != [pid]:
        raise ModemError('Unexpected AT port owner')
    RESTORE.touch(exist_ok=False)
    try:
        docker('stop', '-t', '4', VOICE)
        if any(subprocess.run(['fuser', '-s', port], timeout=3).returncode == 0 for port in (AT, PCM)):
            raise ModemError('Modem serial port is busy')
        with serial_port(AT) as modem:
            yield modem
    finally:
        # If serial IO failed, the watchdog performs a fresh AT cleanup before restoring.
        if not DIAL_MARKER.exists() and not PCM_MARKER.exists():
            docker('start', VOICE)
            RESTORE.unlink(missing_ok=True)
            print('Original EC20 service restored', flush=True)


@contextmanager
def audio_port(path=PCM):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    saved = None
    try:
        fcntl.ioctl(fd, termios.TIOCEXCL)
        saved = termios.tcgetattr(fd)
        tty.setraw(fd)
        settings = termios.tcgetattr(fd)
        settings[2] = (settings[2] | termios.CLOCAL | termios.CREAD) & ~(termios.HUPCL | termios.CRTSCTS)
        settings[4] = settings[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, settings)
        yield fd
    finally:
        try:
            if saved is not None:
                termios.tcsetattr(fd, termios.TCSANOW, saved)
        finally:
            os.close(fd)


def frame(kind, data):
    return bytes([kind]) + len(data).to_bytes(2, 'big') + data


def read_exact(conn, size):
    result = bytearray()
    while len(result) < size:
        data = conn.recv(size - len(result))
        if not data:
            break
        result.extend(data)
    return bytes(result)


class PCMQueue:
    """Keep complete 20 ms, 8 kHz mono PCM frames and bound live latency."""
    size = 320
    silence = bytes(size)

    def __init__(self):
        self.frames = deque(maxlen=6)
        self.tail = bytearray()

    def append(self, chunk):
        self.tail.extend(chunk)
        while len(self.tail) >= self.size:
            self.frames.append(bytes(self.tail[:self.size]))
            del self.tail[:self.size]

    def pop(self):
        return self.frames.popleft() if self.frames else self.silence


def pump(conn, fd, modem, cancelled, *, duration=38, check_call=None):
    conn.setblocking(False)
    inbound, to_modem, to_phone = (bytearray() for _ in range(3))
    uplink, downlink = PCMQueue(), PCMQueue()
    counts = [0, 0]
    deadline = time.monotonic() + duration
    next_tick = time.monotonic()
    next_check = next_tick + 1
    while not cancelled.is_set() and time.monotonic() < deadline:
        now = time.monotonic()
        if now >= next_check:
            if check_call is None:
                leg = test_leg(modem.calls())
                if leg is None or leg.state != 'active':
                    break
            elif not check_call():
                break
            next_check = now + 1
        if now >= next_tick:
            # Keep USB PCM clocked through gaps in RTP. A late iteration sends
            # one frame at the current tick, so it cannot burst stale samples.
            next_tick = max(next_tick + .020, now + .015)
            if not to_modem:
                to_modem.extend(uplink.pop())
            if not to_phone and downlink.frames:
                to_phone.extend(frame(0x10, downlink.pop()))
        pending = ([conn] if to_phone else []) + ([fd] if to_modem else [])
        read, write, _ = select.select([conn, fd], pending, [], max(0, next_tick-time.monotonic()))
        if conn in read:
            try:
                chunk = conn.recv(4096)
            except BlockingIOError:
                chunk = None
            if chunk == b'':
                break
            if chunk:
                inbound.extend(chunk)
            while len(inbound) >= 3:
                kind, size = inbound[0], int.from_bytes(inbound[1:3], 'big')
                if size > 3200:
                    raise ValueError('Oversized AudioSocket frame')
                if len(inbound) < size + 3:
                    break
                if kind in (0, 0xff):
                    return counts
                if kind == 0x10 and size % 2 == 0:
                    uplink.append(inbound[3:3+size])
                del inbound[:3+size]
        if fd in read:
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                chunk = None
            if chunk == b'':
                break
            if chunk:
                downlink.append(chunk)
        if fd in write:
            try:
                sent = os.write(fd, to_modem)
            except BlockingIOError:
                sent = 0
            counts[0] += sent
            del to_modem[:sent]
        if conn in write:
            try:
                sent = conn.send(to_phone)
            except BlockingIOError:
                sent = 0
            counts[1] += sent
            del to_phone[:sent]
    return counts


class Session:
    def __init__(self):
        self.id = uuid.uuid4()
        self.ready = threading.Event()
        self.audio = threading.Event()
        self.cancel = threading.Event()
        self.done = threading.Event()
        self.conn = None

    def run(self):
        try:
            with exclusive_modem() as modem:
                modem._command('AT')
                if modem.calls() or self.cancel.is_set():
                    return
                response(modem, 'AT+CEREG?', r'\+CEREG:\s*\d+,\s*([15])(?:,.*)?')
                PCM_MARKER.touch(exist_ok=False)
                try:
                    modem._command('AT+QPCMV=0')
                    with audio_port() as fd:
                        termios.tcflush(fd, termios.TCIOFLUSH)
                        modem._command('AT+QPCMV=1,0')
                        if self.cancel.is_set():
                            return
                        DIAL_MARKER.touch(exist_ok=False)
                        modem.dial('10000', timeout=7)
                        print('App requested ATD 10000', flush=True)
                        deadline = time.monotonic() + 11
                        while not self.cancel.is_set() and time.monotonic() < deadline:
                            leg = test_leg(modem.calls())
                            if leg and leg.state == 'active':
                                self.ready.set()
                                print('EC20 reported connected; waiting for App media', flush=True)
                                if self.audio.wait(4) and not self.cancel.is_set():
                                    counts = pump(self.conn, fd, modem, self.cancel)
                                    print('PCM transferred (uplink bytes, downlink framed bytes):', counts, flush=True)
                                return
                            if 'NO CARRIER' in modem.events:
                                break
                            time.sleep(0.22)
                finally:
                    if modem.usable:
                        if DIAL_MARKER.exists():
                            release(modem)
                        modem._command('AT+QPCMV=0')
                        PCM_MARKER.unlink(missing_ok=True)
        except Exception as error:
            print('AT test:', type(error).__name__, str(error), flush=True)
        finally:
            if self.conn is not None:
                try:
                    self.conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            self.done.set()
            if RESTORE.exists():
                # Exit so systemd's recovery command handles this case.
                os.kill(os.getpid(), signal.SIGTERM)


current = None
lock = threading.Lock()


class AGI(socketserver.StreamRequestHandler):
    def handle(self):
        global current
        self.connection.settimeout(3)
        fields = {}
        for _ in range(64):
            line = self.rfile.readline(1024).decode('ascii', errors='replace').strip()
            if not line:
                break
            key, _, value = line.partition(': ')
            fields[key] = value
        if fields.get('agi_extension') != '10000' or time.monotonic() >= ADMISSION_UNTIL:
            return
        with lock:
            if current is not None and not current.done.is_set():
                return
            current = session = Session()
        threading.Thread(target=session.run, daemon=True).start()
        handed_off = False
        try:
            while not session.ready.wait(0.2):
                if session.done.is_set() or select.select([self.connection], [], [], 0)[0]:
                    return
            self.wfile.write(f'SET VARIABLE HL_AT_ID "{session.id}"\n'.encode())
            handed_off = self.rfile.readline(1024).startswith(b'200 result=1')
        finally:
            if not handed_off:
                session.cancel.set()


class Audio(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(3)
        if read_exact(self.connection, 3) != b'\x01\x00\x10':
            return
        identifier = read_exact(self.connection, 16)
        with lock:
            session = current
            if session is None or session.id.bytes != identifier or not session.ready.is_set() or session.audio.is_set() or session.done.is_set():
                return
            session.conn = self.connection
            session.audio.set()
        session.done.wait(46)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    with Server(('127.0.0.1', 14673), AGI) as agi, Server(('127.0.0.1', 14674), Audio) as audio:
        threading.Thread(target=audio.serve_forever, daemon=True).start()
        print('AT test route ready on loopback', flush=True)
        agi.serve_forever()
