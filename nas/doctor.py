#!/usr/bin/env python3
"""Check a public HomeLine entry without sending SMS or placing calls."""
import argparse
import getpass
import json
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url', help='The HTTPS address entered in the iPhone app')
args = parser.parse_args()
origin = args.url.rstrip('/')
url = urllib.parse.urlsplit(origin)
if url.scheme != 'https' or not url.hostname or url.username or url.query or url.fragment or url.path:
    parser.error('Enter an HTTPS origin with optional port')
password = getpass.getpass('Pairing password: ')


def request(path, token='', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(origin+'/api/'+path, data=data, headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer '+token})
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=10) as reply:
        result = json.load(reply)
        print(path.split('?')[0], reply.status, round((time.monotonic()-started)*1000), 'ms')
        return result


try:
    pair = request('homeline/pair', body={'password': password})
    token = pair['token']
    devices = request('devices', token)
    request('sms/contacts?'+urllib.parse.urlencode({'device_id': pair['device'], 'limit': 1}), token)
    capabilities = request('homeline/rtc/capabilities', token)
    assert capabilities['transport'] == 'webrtc'
    print('HTTPS authentication, SMS reading and voice signaling passed.')
    print('Push delivery status available:', 'pushDelivery' in devices)
    print('Complete the cellular SMS, lock-screen CallKit and two-way audio checks next.')
except Exception as error:
    raise SystemExit(f'Check failed: {type(error).__name__}. Check the address, certificate, password and NAS logs.')
