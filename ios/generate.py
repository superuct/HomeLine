#!/usr/bin/env python3
"""Configure the iOS targets and generate their Xcode project."""
import argparse
import json
import plistlib
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle-id', required=True)
parser.add_argument('--team')
parser.add_argument('--app-identifier-prefix', help='profile AppIdentifierPrefix, for example ABCDE12345.')
parser.add_argument('--apns-env', choices=['development', 'production'], default='development')
parser.add_argument('--local-webrtc', type=Path, help='optional Swift package path for offline builds')
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
    parser.error('invalid bundle ID')
if args.team and not re.fullmatch(r'[A-Z0-9]{10}', args.team):
    parser.error('invalid Apple team ID')
if args.app_identifier_prefix and not re.fullmatch(r'[A-Z0-9]{10}\.', args.app_identifier_prefix):
    parser.error('invalid AppIdentifierPrefix')
project = Path(__file__).resolve().parent
spec = json.loads((project / 'project.json').read_text().replace('org.example.homeline', args.bundle_id))
base = spec['settings']['base']
if args.team:
    base['DEVELOPMENT_TEAM'] = args.team
    base['CODE_SIGN_STYLE'] = 'Automatic'
prefix = args.app_identifier_prefix
if prefix:
    base['AppIdentifierPrefix'] = prefix
base['HOMELINE_APNS_ENV'] = args.apns_env
if args.local_webrtc:
    spec['packages']['WebRTC'] = {'path': str(args.local_webrtc.resolve())}
build = project/'build'
build.mkdir(exist_ok=True)
for target in ('HomeLine', 'SMSNotificationService'):
    settings = spec['targets'][target]['settings']['base']
    source = project / settings['CODE_SIGN_ENTITLEMENTS']
    contents = source.read_text().replace('org.example.homeline', args.bundle_id)
    entitlements = build / f'{target}.entitlements'
    plistlib.loads(contents.encode())
    entitlements.write_text(contents)
    settings['CODE_SIGN_ENTITLEMENTS'] = str(entitlements.relative_to(project))
configured = build/'project.configured.json'
configured.write_text(json.dumps(spec, ensure_ascii=False, indent=2))
subprocess.run(['xcodegen', 'generate', '--spec', str(configured), '--project-root', str(project),
                '--project', str(project)], cwd=project, check=True)
