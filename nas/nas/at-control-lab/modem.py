"""Offline single-SIM AT control prototype. Pass an already-open lab PTY FD."""
import csv
from collections import deque
from dataclasses import dataclass
import os
import re
import select
import threading
import time


@dataclass(frozen=True)
class Call:
    index: int
    incoming: bool
    state: str
    number: str


CALL_FINAL_RESULTS = frozenset(("NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE"))
CALL_STATUS_NOTICE = re.compile(r'^\^DSCI:\s*(\d+)\s*,\s*([01])\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,|$)')


class ModemError(Exception):
    pass


def address(number):
    if not re.fullmatch(r'\+?[0-9]{2,15}', number):
        raise ValueError('Invalid phone number')
    digits = number.lstrip('+')
    padded = digits + ('F' if len(digits) % 2 else '')
    return bytes((len(digits), 0x91 if number.startswith('+') else 0x81)) + bytes.fromhex(
        ''.join(padded[i:i+2][::-1] for i in range(0, len(padded), 2)))


def submit_pdu(number, text):
    # Single-part UCS-2 SMS-SUBMIT, using the modem's configured SMSC.
    if any(ord(character) > 0xffff for character in text):
        raise ValueError('The lab supports UCS-2 characters only')
    body = text.encode('utf-16-be')
    if not 0 < len(body) <= 140:
        raise ValueError('The lab supports one SMS segment')
    return b'\x00\x01\x00' + address(number) + b'\x00\x08' + bytes((len(body),)) + body


def deliver_pdu(value):
    raw = bytes.fromhex(value)
    try:
        start = 1 + raw[0]
        if raw[start] & 0x43:
            raise ValueError('Expected a single SMS-DELIVER segment')
        count, kind = raw[start+1:start+3]
        if kind not in (0x81, 0x91, 0xa1):
            raise ValueError('Expected a numeric sender')
        addr_end = start + 3 + (count + 1) // 2
        digits = ''.join(f'{byte:02x}'[::-1] for byte in raw[start+3:addr_end])[:count]
        if len(digits) != count or not digits.isascii() or not digits.isdecimal():
            raise ValueError('Invalid sender address')
        if raw[addr_end+1] != 0x08:
            raise ValueError('Only UCS-2 incoming SMS is supported in this lab')
        size = raw[addr_end+9]
        body = raw[addr_end+10:]
        if len(body) != size or size > 140 or size % 2:
            raise ValueError('Invalid SMS length')
        return ('+' if kind == 0x91 else '') + digits, body.decode('utf-16-be')
    except IndexError as error:
        raise ValueError('Truncated SMS PDU') from error


class Modem:
    states = ('active', 'held', 'dialing', 'alerting', 'incoming', 'waiting')

    def __init__(self, fd):
        self.fd = fd
        self.buffer = bytearray()
        self.events = deque(maxlen=128)
        self.lock = threading.RLock()
        self.usable = True

    def _next(self, deadline):
        while True:
            if self.buffer.startswith(b'> '):
                del self.buffer[:2]
                return '> '
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                line = bytes(self.buffer[:newline]).strip().decode('ascii')
                del self.buffer[:newline+1]
                if line:
                    return line
                continue
            delay = deadline - time.monotonic()
            if delay <= 0 or not select.select([self.fd], [], [], delay)[0]:
                raise TimeoutError('Modem response timed out')
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise OSError('Modem disconnected')
            self.buffer.extend(chunk)
            if len(self.buffer) > 16384:
                raise OSError('Modem response exceeded the line limit')

    @staticmethod
    def is_event(line):
        return (line == 'RING' or line in CALL_FINAL_RESULTS or
                line.startswith(('+CMTI:', '+CLIP:', '^CEND:', 'VOICE CALL: END')) or
                CALL_STATUS_NOTICE.match(line) is not None)

    def _response(self, deadline, *, prompt=False, placing_call=False):
        response = []
        while True:
            line = self._next(deadline)
            if placing_call and line in CALL_FINAL_RESULTS:
                raise ModemError(line)
            if self.is_event(line):
                self.events.append(line)
            elif line == 'OK' and not prompt:
                return response
            elif line == '> ' and prompt:
                return response
            elif line in ('OK', '> ', 'ERROR') or line.startswith(('+CME ERROR:', '+CMS ERROR:')):
                raise ModemError(line)
            else:
                response.append(line)

    def _command(self, command, *, pdu=None, timeout=3):
        with self.lock:
            if not self.usable:
                raise ModemError('Serial session requires reopening after a transport failure')
            deadline = time.monotonic() + timeout
            try:
                os.write(self.fd, command.encode('ascii') + b'\r')
                if pdu is not None:
                    self._response(deadline, prompt=True)
                    os.write(self.fd, pdu.hex().upper().encode('ascii') + b'\x1a')
                return self._response(deadline, placing_call=command.startswith('ATD') or command == 'ATA')
            except (TimeoutError, OSError):
                self.usable = False
                raise

    def initialize(self):
        for command in ('AT', 'ATE0', 'AT+CMGF=0', 'AT+CNMI=2,1,0,0,0'):
            self._command(command)

    def send(self, number, text):
        pdu = submit_pdu(number, text)
        response = self._command(f'AT+CMGS={len(pdu)-1}', pdu=pdu, timeout=30)
        for line in response:
            if line.startswith('+CMGS:'):
                return int(line.split(':', 1)[1])
        raise ModemError('No SMS submit reference')

    def receive(self, storage, index):
        if storage not in ('SM', 'ME') or not isinstance(index, int) or not 0 <= index <= 65535:
            raise ValueError('Invalid SMS storage or index')
        with self.lock:
            self._command(f'AT+CPMS="{storage}"')
            lines = self._command(f'AT+CMGR={index}')
        for position, line in enumerate(lines[:-1]):
            if line.startswith('+CMGR:'):
                return deliver_pdu(lines[position+1])
        raise ModemError('No SMS PDU')

    def next_event(self, timeout=3):
        with self.lock:
            if self.events:
                return self.events.popleft()
            deadline = time.monotonic() + timeout
            while True:
                line = self._next(deadline)
                if self.is_event(line):
                    return line

    def dial(self, number, *, timeout=3):
        address(number)
        self._command(f'ATD{number};', timeout=timeout)

    def answer(self):
        self._command('ATA')

    def hangup(self, *, voice=False):
        self._command('AT+CHUP' if voice else 'ATH')

    def calls(self):
        calls = []
        for line in self._command('AT+CLCC'):
            if not line.startswith('+CLCC:'):
                continue
            fields = next(csv.reader([line.split(':', 1)[1]], skipinitialspace=True))
            index, direction, state, mode = map(int, fields[:4])
            if mode == 0 and 0 <= state < len(self.states):
                calls.append(Call(index, direction == 1, self.states[state], fields[5] if len(fields) > 5 else ''))
        return calls
