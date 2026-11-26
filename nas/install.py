#!/usr/bin/env python3
"""Check and install the SakuraFrp NAS systemd units."""
import argparse
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='validate configuration without installing services')
args = parser.parse_args()
root = Path(__file__).resolve().parent
config = Path('/etc/homeline-nas')
client = Path('/var/lib/homeline-sakurafrp')
units = ['homeline-nas.service', 'homeline-sakurafrp-gateway.service', 'homeline-sakurafrp-client.service']


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def read_environment(path):
    result = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        require(separator and value and not any(c in value for c in '\n\r\0"\' '),
                f'Use unquoted KEY=value entries in {path}')
        result[key] = value
    return result


require(platform.system() == 'Linux', 'The NAS installer requires Linux with systemd.')
require(root == Path('/opt/homeline-nas'), 'Place this NAS directory at /opt/homeline-nas first.')
for command in ['python3', 'curl', 'openssl', 'systemctl', 'systemd-analyze']:
    require(shutil.which(command), f'Missing dependency: {command}')
require('HTTP2' in subprocess.check_output(['curl', '-V'], text=True), 'Install curl with HTTP/2 support for APNs.')
for file in [root/'bin/homeline-media', root/'bin/frpc', config/'service.env',
             config/'sakurafrp.env', config/'config.json', client/'frpc.ini']:
    require(file.is_file(), f'Missing {file}')
for binary in [root/'bin/homeline-media', root/'bin/frpc']:
    require(os.access(binary, os.X_OK), f'Make {binary} executable')
env = read_environment(config/'service.env')
frp = read_environment(config/'sakurafrp.env')
require(env.get('HOMELINE_MODE') == 'sakurafrp', 'Set HOMELINE_MODE=sakurafrp in service.env')
require(env.get('HOMELINE_CONFIG') == str(config), 'HOMELINE_CONFIG must be /etc/homeline-nas')
require(env.get('HOMELINE_STATE') == '/var/lib/homeline-nas', 'HOMELINE_STATE must be /var/lib/homeline-nas')
for name in ['AT_DEVICE', 'PCM_DEVICE']:
    require(name in env and Path(env[name]).is_char_device(), f'Choose a connected serial character device for {name}')
require(env['AT_DEVICE'] != env['PCM_DEVICE'], 'AT_DEVICE and PCM_DEVICE must differ')
require(frp.get('FRP_HTTP_TARGET') == '127.0.0.1:' + env.get('FRP_ORIGIN_PORT', '18086'), 'FRP_HTTP_TARGET does not match FRP_ORIGIN_PORT')
require(frp.get('FRP_ICE_TARGET') == '127.0.0.1:' + env.get('ICE_PORT', '20119'), 'FRP_ICE_TARGET does not match ICE_PORT')
require('FRP_PUBLIC_UDP' in frp and not frp['FRP_PUBLIC_UDP'].endswith('.invalid:62119'), 'Set actual FRP_PUBLIC_UDP')
for name in ['frpc.ini']:
    require((client/name).stat().st_mode & 0o077 == 0, f'Use mode 600 for {client/name}')
settings = json.loads((config/'config.json').read_text())
require(settings.get('apns_topic') and settings.get('token'), 'Run configure.py first')
require((config/'config.json').stat().st_mode & 0o077 == 0, 'Use mode 600 for config.json')
for kind in ['apns', 'voip']:
    certificate = config / (kind + '.pem')
    if kind == 'voip' and not certificate.exists():
        continue
    require(certificate.is_file() and (config/(kind+'.key')).is_file(), f'Install {kind}.pem and {kind}.key for lock-screen alerts')
    require((config/(kind+'.key')).stat().st_mode & 0o077 == 0, 'Use mode 600 for APNs private keys')
    subprocess.run(['openssl', 'x509', '-in', str(certificate), '-checkend', '0', '-noout'],
                   check=True, stdout=subprocess.DEVNULL)
    certificate_key = subprocess.check_output(['openssl', 'x509', '-in', str(certificate), '-pubkey', '-noout'])
    private_key = subprocess.check_output(['openssl', 'pkey', '-in', str(config/(kind+'.key')),
                                           '-passin', 'pass:', '-pubout'], stderr=subprocess.PIPE)
    require(certificate_key == private_key, f'{kind} certificate and private key do not match')
for unit in units:
    subprocess.run(['systemd-analyze', 'verify', str(root/unit)], check=True)
print('Configuration checks passed. Cellular calls and Apple delivery need the acceptance steps.')
if args.check:
    raise SystemExit(0)
require(os.geteuid() == 0, 'Run the installer with sudo.')
try:
    pwd.getpwnam('homeline-frp')
except KeyError:
    subprocess.run(['useradd', '--system', '--home-dir', str(client), '--shell', '/usr/sbin/nologin', 'homeline-frp'], check=True)
owner = pwd.getpwnam('homeline-frp')
os.chown(client, owner.pw_uid, owner.pw_gid)
os.chmod(client, 0o700)
for file in client.iterdir():
    if file.is_file():
        os.chown(file, owner.pw_uid, owner.pw_gid)
        os.chmod(file, 0o600)
for unit in units:
    target = Path('/etc/systemd/system')/unit
    if target.exists() and target.read_bytes() != (root/unit).read_bytes():
        raise SystemExit(f'{target} exists with different settings. Back it up before replacing it.')
for unit in units:
    shutil.copyfile(root/unit, Path('/etc/systemd/system')/unit)
    os.chmod(Path('/etc/systemd/system')/unit, 0o644)
subprocess.run(['systemctl', 'daemon-reload'], check=True)
subprocess.run(['systemctl', 'enable', '--now', *units], check=True)
subprocess.run(['systemctl', 'is-active', *units], check=True)
