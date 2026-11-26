"""Loopback-only test gateway with two PTYs and no APNs configuration."""
import argparse
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time
import tty

parser = argparse.ArgumentParser()
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--work', type=Path, required=True)
parser.add_argument('--openssl', default='openssl')
parser.add_argument('--launch', type=Path, help='run the packaged launcher using simulated serial devices')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
work = args.work.resolve()
work.mkdir(mode=0o700, exist_ok=True)
if any(work.iterdir()):
    raise SystemExit("Choose an empty fixture directory")
os.umask(0o077)
cert = work/'fullchain.pem'
if not cert.exists():
    ca=work/'ca.pem'
    key=work/'ca.key'
    csr=work/'leaf.csr'
    extensions=work/'leaf.ext'
    extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n")
    def ssl(*options):
        subprocess.run([args.openssl,*options],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    ssl('req','-x509','-newkey','rsa:2048','-nodes','-days','30','-subj','/CN=HomeLine Fixture Root',
        '-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign',
        '-keyout',str(key),'-out',str(ca))
    ssl('req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=127.0.0.1',
        '-keyout',str(work/'tls.key'),'-out',str(csr))
    ssl('x509','-req','-days','2','-in',str(csr),'-CA',str(ca),'-CAkey',str(key),'-CAcreateserial',
        '-extfile',str(extensions),'-out',str(cert))
    ssl('x509','-in',str(ca),'-outform','der','-out',str(work/'ca.der'))
config={'token':'rtc-native-fixture-token','device':'ec20','apns_env':'development'}
(work/'config.json').write_text(json.dumps(config))
master, slave = os.openpty()
audio, audio_slave = os.openpty()
tty.setraw(slave)
tty.setraw(audio_slave)
os.set_blocking(audio, False)
path, pcm_path = os.ttyname(slave), os.ttyname(audio_slave)
active=False
commands=bytearray()
def read_commands():
    global active
    answers={'AT+CPIN?':'+CPIN: READY','AT+CIMI':'460031234567890','AT+QCCID':'+QCCID: 89860012345678901234','AT+CMGF?':'+CMGF: 0',
             'AT+CNMI?':'+CNMI: 2,1,0,0,0','AT+CPMS?':'+CPMS: "SM",0,10,"SM",0,10,"SM",0,10',
             'AT+CEREG?':'+CEREG: 0,1','AT+CSQ':'+CSQ: 23,99','AT+COPS?':'+COPS: 0,0,"CHN-CT",7'}
    while True:
        commands.extend(os.read(master,2048))
        while b'\r' in commands:
            line, _, rest=commands.partition(b'\r')
            commands[:] = rest
            command=line.decode('ascii').strip()
            data=answers.get(command,'')
            if command.startswith('ATD'):
                active=True
                print('Fixture ATD',flush=True)
            elif command=='AT+CLCC' and active:
                data='+CLCC: 1,0,0,0,0,"10000",129'
            elif command=='AT+CHUP':
                active=False
                print('Fixture CHUP',flush=True)
            os.write(master,('\r\n'+(data+'\r\n' if data else '')+'OK\r\n').encode())
def simulate_audio():
    frame = struct.pack('<160h', *(int(3000 * math.sin(2 * math.pi * 350 * i / 8000)) for i in range(160)))
    mic_reference = [complex(math.cos(2 * math.pi * 710 * i / 8000), math.sin(2 * math.pi * 710 * i / 8000))
                     for i in range(160)]
    received = bytearray()
    heard_mic = False
    while True:
        if active:
            try:
                os.write(audio, frame)
            except BlockingIOError:
                pass
            try:
                chunk = os.read(audio, 4096)
            except BlockingIOError:
                chunk = b''
            if not heard_mic:
                received.extend(chunk)
                while len(received) >= 320:
                    samples = struct.unpack('<160h', received[:320])
                    del received[:320]
                    if abs(sum(a * b for a, b in zip(samples, mic_reference))) / 80 > 300:
                        print('Fixture received iPhone microphone tone', flush=True)
                        heard_mic = True
                        received.clear()
                        break
        time.sleep(.02)
for task in (read_commands,simulate_audio):
    threading.Thread(target=task,daemon=True).start()
env=dict(os.environ,HOMELINE_CONFIG=str(work),HOMELINE_STATE=str(work/'state'))
if args.launch:
    env.update(AT_DEVICE=path, PCM_DEVICE=pcm_path, TLS_BIND='127.0.0.1', TLS_PORT='18643',
               ICE_BIND='127.0.0.1', ICE_PORT='18644', SMS_LOOPBACK_PORT='18645',
               MEDIA_BIN=str(args.media.resolve()))
    command = ['sh', str(args.launch.resolve())]
else:
    command = [sys.executable,str(root/'nas/webrtc-voice/radio.py'),'--listen','127.0.0.1','--port','18643',
               '--ice','127.0.0.1:18644','--media',str(args.media.resolve()),'--work',str(work),
               '--at',path,'--pcm',pcm_path,'--sms-port','18645']
child=subprocess.Popen(command,env=env)
try:
    child.wait()
finally:
    if child.poll() is None: child.terminate(); child.wait(timeout=4)
raise SystemExit(child.returncode)
