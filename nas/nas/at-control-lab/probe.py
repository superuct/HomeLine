#!/usr/bin/env python3
"""Read-only check of the physical EC20 AT port during an exclusive test window."""
from contextlib import contextmanager
import fcntl
import json
import os
import re
import stat
import termios
import tty

from modem import Modem, ModemError


@contextmanager
def serial_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    original = None
    try:
        if not stat.S_ISCHR(os.fstat(fd).st_mode):
            raise ValueError('Expected a serial character device')
        fcntl.ioctl(fd, termios.TIOCEXCL)
        original = termios.tcgetattr(fd)
        tty.setraw(fd)
        current = termios.tcgetattr(fd)
        current[2] = (current[2] | termios.CLOCAL | termios.CREAD) & ~termios.HUPCL
        current[4] = current[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, current)
        termios.tcflush(fd, termios.TCIFLUSH)
        os.set_blocking(fd, True)
        yield Modem(fd)
    finally:
        try:
            if original is not None:
                termios.tcsetattr(fd, termios.TCSANOW, original)
        finally:
            os.close(fd)


def response(modem, command, pattern):
    for line in modem._command(command):
        match = re.fullmatch(pattern, line)
        if match:
            return match.groups()
    raise ModemError(f'Unexpected response to {command}')


def probe(path):
    with serial_port(path) as modem:
        modem._command('AT')
        model, = response(modem, 'AT+CGMM', r'(EC20[\w.-]*)')
        pin, = response(modem, 'AT+CPIN?', r'\+CPIN:\s*(READY|SIM PIN|SIM PUK)')
        registered, = response(modem, 'AT+CEREG?', r'\+CEREG:\s*\d+,\s*([0-9])(?:,.*)?')
        signal, = response(modem, 'AT+CSQ', r'\+CSQ:\s*(\d+),\s*\d+')
        mode, = response(modem, 'AT+CMGF?', r'\+CMGF:\s*([01])')
        calls = modem.calls()
        # Report state only, no stored messages, phone numbers or SIM identifiers.
        return {'module': model, 'sim': pin, 'lte_registration': int(registered),
                'signal_csq': int(signal), 'sms_pdu_mode': mode == '0',
                'voice_calls': len(calls)}


if __name__ == '__main__':
    print(json.dumps(probe('/dev/ttyUSB2'), ensure_ascii=False), flush=True)
