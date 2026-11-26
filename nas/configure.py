#!/usr/bin/env python3
"""Create first-run credentials. Re-running will not overwrite existing settings."""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, required=True)
parser.add_argument('--device', default='ec20')
parser.add_argument('--bundle-id', required=True)
parser.add_argument('--apns-env', choices=['development', 'production'], default='development')
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
    parser.error('invalid iOS bundle ID')
os.umask(0o077)
args.config.mkdir(parents=True, exist_ok=True)
target = args.config / 'config.json'
if target.exists():
    parser.error(f'{target} already exists')
password = getpass.getpass('Pairing password: ')
if not 12 <= len(password.encode()) <= 120:
    parser.error('choose a password of 12–120 bytes')
if password != getpass.getpass('Repeat password: '):
    parser.error('passwords differ')
salt = secrets.token_bytes(16)
config = {
    'device': args.device, 'apns_env': args.apns_env, 'apns_topic': args.bundle_id,
    'sip_user': 'homeline',  # Older clients expect this field in the pairing response.
    'salt': salt.hex(), 'verifier': hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 240000).hex(),
    'token': secrets.token_urlsafe(32),
}
with target.open('x') as file:
    json.dump(config, file, indent=2)
    file.write('\n')
print(f'Created {target}')
