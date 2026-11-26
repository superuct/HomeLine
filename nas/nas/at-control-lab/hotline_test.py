#!/usr/bin/env python3
"""One EC20 outbound test to the authorized 10000 service number."""
import json
from pathlib import Path
import sys
import time

from modem import ModemError
from probe import response, serial_port

PORT = '/dev/ttyUSB2'
NUMBER = '10000'
DIAL_MARKER = Path('dial-armed')


def test_leg(calls):
    if len(calls) == 1 and not calls[0].incoming and calls[0].number in ('', NUMBER, '+8610000', '8610000'):
        return calls[0]
    return None


def release(modem):
    calls = modem.calls()
    if calls:
        if test_leg(calls) is None:
            raise ModemError('A call outside this test is present')
        modem.hangup(voice=True)
        for _ in range(6):
            time.sleep(0.25)
            calls = modem.calls()
            if not calls:
                break
        if calls and test_leg(calls) is not None:
            cvhu, = response(modem, 'AT+CVHU?', r'\+CVHU:\s*([01])')
            if cvhu == '0':
                modem.hangup()
                time.sleep(0.4)
                calls = modem.calls()
        if calls:
            raise ModemError('The test call did not clear')
    DIAL_MARKER.unlink(missing_ok=True)
    print('AT verified that the line has no active calls', flush=True)


def dial_once():
    with serial_port(PORT) as modem:
        modem._command('AT')
        registered, = response(modem, 'AT+CEREG?', r'\+CEREG:\s*\d+,\s*([0-9])(?:,.*)?')
        if registered not in ('1', '5') or modem.calls():
            raise ModemError('LTE is unavailable or the line is in use')
        modem.events.clear()
        states = []
        dial_start = time.monotonic()
        DIAL_MARKER.touch(exist_ok=False)
        try:
            modem.dial(NUMBER, timeout=8)
            print('ATD acknowledged by EC20', flush=True)
            deadline = time.monotonic() + 13
            while time.monotonic() < deadline:
                calls = modem.calls()
                leg = test_leg(calls)
                if leg:
                    if not states or states[-1] != leg.state:
                        states.append(leg.state)
                        print('CLCC outgoing:', leg.state, flush=True)
                    if leg.state == 'active':
                        print(json.dumps({'active_after_seconds': round(time.monotonic() - dial_start, 2), 'states': states}), flush=True)
                        return
                elif calls or states or 'NO CARRIER' in modem.events:
                    break
                time.sleep(0.25)
            raise ModemError('The outgoing call did not reach the active state')
        finally:
            if modem.usable:
                release(modem)


if __name__ == '__main__':
    if sys.argv[1:] == ['--cleanup']:
        if DIAL_MARKER.exists():
            with serial_port(PORT) as modem:
                modem._command('AT')
                release(modem)
    elif not sys.argv[1:]:
        dial_once()
    else:
        raise SystemExit('Expected no arguments or --cleanup')
