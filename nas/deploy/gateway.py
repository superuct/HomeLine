"""HomeLine single-SIM NAS gateway. All service listeners except TLS are loopback."""
import asyncio
import hashlib
import hmac
import http.client
import json
import os
import re
import socketserver
import sqlite3
import ssl
import signal
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

BASE = Path(os.environ.get("HOMELINE_CONFIG", "/etc/homeline"))
STATE = Path(os.environ.get("HOMELINE_STATE", "/var/lib/homeline"))
C = {}
auth_lock = threading.Lock()
upstream_token = ""
attempts = deque()
calls = {}
waiting = set()
ringing_legs = {}
pickups = {}
connected_legs = {}
call_lock = threading.Lock()


def release_core_call(key):
    # Keep the exact modem channel until its hangup request succeeds.
    with call_lock:
        leg = connected_legs.get(key) or ringing_legs.get(key)
    if leg:
        control_socket = os.environ.get("HOMELINE_ASTERISK_SOCKET")
        command = (["asterisk", "-C", "/opt/homeline/asterisk-cli.conf", "-s", control_socket] if control_socket else
                   ["docker", "exec", "EC20-Voice", "asterisk"])
        result = subprocess.run([*command, "-rx", "channel request hangup " + leg],
                                capture_output=True, timeout=3)
        if result.returncode:
            raise OSError("Modem hangup request failed")
    with call_lock:
        if connected_legs.get(key) == leg:
            connected_legs.pop(key, None)
        if ringing_legs.get(key) == leg:
            ringing_legs.pop(key, None)
        calls.pop(key, None)
        waiting.discard(key)
        pickups.pop(key, None)


def database():
    return sqlite3.connect(STATE / "push.sqlite", timeout=5)


def latest_sms():
    with sqlite3.connect("file:" + C["sms_db"] + "?mode=ro", uri=True) as db:
        return db.execute("select coalesce(max(id),0) from sms where type=1").fetchone()[0]

def register_phone(owner, sms, voip, pickup):
    with database() as db:
        db.execute("begin immediate")
        if not sms and not voip:
            # Retain the delivery cursor across an unregister/re-register.
            db.execute("update phone set sms='',voip='',pickup=0 where owner=?", (owner,))
            return
        row = db.execute("select owner,sms,cursor from phone where id=1").fetchone()
        same_phone = row and (row[0] == owner or (sms and row[1] == sms))
        cursor = row[2] if same_phone else latest_sms()
        db.execute("insert or replace into phone(id,owner,sms,voip,cursor,pickup) values(1,?,?,?,?,?)",
                   (owner, sms, voip, cursor, int(pickup)))


def push_certificate(kind):
    return BASE / ("voip.pem" if kind == "voip" and (BASE / "voip.pem").exists() else "apns.pem")


def push_status():
    with database() as db:
        rows = db.execute("select kind,accepted,failed,reason from push_delivery").fetchall()
    return {kind: {"lastAccepted": accepted, "lastFailed": failed, "lastError": reason}
            for kind, accepted, failed, reason in rows}


def record_push(kind, reason=None):
    now = time.time()
    try:
        with database() as db:
            db.execute("insert or ignore into push_delivery(kind) values(?)", (kind,))
            if reason is None:
                db.execute("update push_delivery set accepted=? where kind=?", (now, kind))
            else:
                db.execute("update push_delivery set failed=?,reason=? where kind=?", (now, reason, kind))
    except sqlite3.Error:
        print("Push delivery status not recorded", file=sys.stderr, flush=True)


def apple(kind, token, payload, collapse=None):
    host = "api.sandbox.push.apple.com" if C["apns_env"] == "development" else "api.push.apple.com"
    cert = push_certificate(kind)
    key = cert.with_suffix(".key")
    if not cert.is_file() or not key.is_file():
        record_push(kind, "MissingCertificate")
        return False
    headers = {"apns-topic": C.get("apns_topic", "org.example.homeline") + (".voip" if kind == "voip" else ""),
               "apns-push-type": kind, "apns-priority": "10", "apns-expiration": "0" if kind == "voip" else str(int(time.time())+3600)}
    if collapse:
        headers["apns-collapse-id"] = collapse
    cmd = ["curl", "--http2", "--silent", "--show-error", "--max-time", "5", "--cert", str(cert), "--key", str(key), "--write-out", "\n%{http_code}"]
    for k, v in headers.items():
        cmd.extend(["-H", k + ": " + v])
    try:
        result = subprocess.run(cmd + ["--data-binary", "@-", "https://" + host + "/3/device/" + token],
                                input=json.dumps(payload, ensure_ascii=False), capture_output=True, text=True)
    except OSError:
        record_push(kind, "TransportError")
        return False
    body, _, status = result.stdout.rpartition("\n")
    if status == "200":
        record_push(kind)
        return True
    try:
        reason = json.loads(body)["reason"]
        if not isinstance(reason, str) or not re.fullmatch(r"[A-Za-z0-9_]{1,64}", reason):
            reason = "InvalidAPNsResponse"
    except (ValueError, KeyError, TypeError):
        reason = {6: "DNSFailure", 7: "ConnectionFailed", 28: "Timeout",
                  35: "TLSFailure", 58: "ClientCertificateError"}.get(result.returncode, "TransportError")
    record_push(kind, reason)
    print("APNs", kind, status, reason, file=sys.stderr, flush=True)
    if status == "410" or reason == "BadDeviceToken":
        field = "voip" if kind == "voip" else "sms"
        with database() as db:
            db.execute(f"update phone set {field}='' where {field}=?", (token,))
    return False


def sms_payload(message_id, sender, text, imsi, installation):
    return {"aps": {"alert": {"title": sender[:64] or "新短信", "body": (text or "")[:600]},
                    "sound": "default", "mutable-content": 1,
                    "thread-id": "sms-" + hashlib.sha256(sender.encode()).hexdigest()[:24]},
            "open": "sms", "sender": sender, "message_id": message_id,
            "device_id": C.get("device", "ec20"), "imsi": imsi or "", "installation": installation}


def sms_loop():
    while True:
        try:
            with database() as db:
                row = db.execute("select sms,cursor,owner from phone where id=1").fetchone()
            if row and row[0]:
                with sqlite3.connect("file:" + C["sms_db"] + "?mode=ro", uri=True) as smsdb:
                    incoming = smsdb.execute(
                        "select id,coalesce(nullif(sender,''),peer,''),content,imsi from sms where type=1 and id>? order by id limit 20",
                        (row[1],)).fetchall()
                cursor = row[1]
                for message_id, sender, text, imsi in incoming:
                    payload = sms_payload(message_id, sender, text, imsi, row[2])
                    if not apple("alert",row[0],payload): break
                    with database() as db:
                        updated = db.execute("update phone set cursor=? where id=1 and sms=? and owner=? and cursor=?",
                                             (message_id,row[0],row[2],cursor)).rowcount
                    if not updated:
                        break
                    cursor = message_id
        except (sqlite3.Error, OSError):
            print("SMS monitor unavailable", file=sys.stderr, flush=True)
        time.sleep(5)


def upstream(method, path, body, token=""):
    conn = http.client.HTTPConnection("127.0.0.1", C["vohive_port"], timeout=30)
    try:
        conn.request(method, path, body, {"Content-Type": "application/json", "Authorization": "Bearer " + token})
        r = conn.getresponse()
        return r.status, r.read()
    finally:
        conn.close()


def sms_request(method, path, body):
    global upstream_token
    for _ in range(2):
        with auth_lock:
            if not upstream_token:
                status, data = upstream("POST", "/api/auth/login", json.dumps(C["upstream_login"]))
                if status != 200:
                    return 502, b'{}'
                upstream_token = json.loads(data)["token"]
            token = upstream_token
        status, data = upstream(method, path, body, token)
        if status != 401:
            return status, data
        with auth_lock:
            if upstream_token == token:
                upstream_token = ""
    return 502, b'{}'


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, data=None):
        raw = data if isinstance(data, bytes) else json.dumps(data or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_api(self):
        method = self.command
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 <= size <= 65536 or self.headers.get("Transfer-Encoding"):
                return self.reply(400)
            raw = self.rfile.read(size)
            path = urlsplit(self.path).path
            if path == "/api/homeline/pair" and method == "POST":
                password = json.loads(raw)["password"]
                with auth_lock:
                    now = time.monotonic()
                    while attempts and now - attempts[0] > 60:
                        attempts.popleft()
                    if len(attempts) >= 10:
                        return self.reply(429)
                    if not isinstance(password,str) or len(password.encode()) > 120 or not hmac.compare_digest(hashlib.pbkdf2_hmac("sha256",password.encode(),bytes.fromhex(C["salt"]),240000).hex(), C["verifier"]):
                        attempts.append(now)
                        return self.reply(401)
                result = {"version": 1, "device": C["device"], "sipUser": C["sip_user"], "token": C["token"], "pushEnvironment": C["apns_env"]}
                if C.get("voice_transport"):
                    result["voiceTransport"] = C["voice_transport"]
                return self.reply(200, result)
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), ("Bearer " + C["token"]).encode()):
                return self.reply(401)
            if path == "/api/homeline/push" and method == "POST":
                v = json.loads(raw)
                sms, voip = v["sms"], v["voip"]
                owner = str(uuid.UUID(v["installation"]))
                if any(not isinstance(t,str) or not re.fullmatch(r"(?:[0-9a-f]{32,200})?", t) for t in (sms, voip)):
                    return self.reply(400)
                register_phone(owner, sms, voip, v.get("pickup") is True)
                cert = push_certificate("alert")
                return self.reply(200, {"providerReady": cert.is_file() and cert.with_suffix(".key").is_file(),
                                        "delivery": push_status()})
            if C.get("voice_transport") != "webrtc" and path.startswith("/api/homeline/calls/") and method in ("POST", "GET"):
                key = str(uuid.UUID(path.rsplit("/", 1)[1]))
                if method == "POST":
                    if json.loads(raw or b"{}").get("ready") is True:
                        with call_lock: waiting.discard(key)
                    else:
                        release_core_call(key)
                with call_lock:
                    active = key in connected_legs or calls.get(key,0) > time.monotonic()
                return self.reply(200, {"active": active})
            allowed = {"GET": ["/api/devices","/api/sms/contacts","/api/sms/thread"], "POST":["/api/sms/send"]}
            if path in allowed.get(method,[]) or (method=="DELETE" and re.fullmatch(r"/api/sms/messages/-?[0-9]+",path)):
                status,data = sms_request(method,self.path,raw or None)
                return self.reply(status,data)
            self.reply(404)
        except (ValueError, TypeError, KeyError):
            self.reply(400)
        except (OSError, subprocess.TimeoutExpired, sqlite3.Error, http.client.HTTPException):
            self.reply(502)
    do_POST = do_GET = do_DELETE = handle_api


class AGI(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(4)
        fields = {}
        for _ in range(128):
            line = self.rfile.readline(2048).decode(errors="replace").strip()
            if not line: break
            k,_,v=line.partition(": ")
            fields[k]=v
        route = fields.get("agi_network_script","").split("/")
        if route == ["incoming"]:
            key = str(uuid.uuid4())
            with call_lock:
                now = time.monotonic()
                for k in list(calls):
                    if calls[k] < now: calls.pop(k); waiting.discard(k); ringing_legs.pop(k,None); pickups.pop(k,None)
                calls[key] = now + 50
                source = fields.get("agi_arg_1","")
                if re.fullmatch(r"Quectel/[A-Za-z0-9_-]+-[0-9a-fA-F]+", source):
                    ringing_legs[key] = source
            self.wfile.write(f'SET VARIABLE HL_UUID "{key}"\n'.encode())
            self.rfile.readline(2048)
            with database() as db:
                target = db.execute("select voip,owner,pickup from phone where id=1").fetchone()
            if target and target[0] and (BASE / "apns.pem").is_file():
                channel = fields.get("agi_channel", "")
                pickup = bool(target[2] and re.fullmatch(r"PJSIP/ec20-[0-9a-fA-F]+",channel))
                with call_lock:
                    waiting.add(key)
                    if pickup: pickups[key] = channel
                payload = {"aps":{}, "installation":target[1], "uuid":key, "pickup":pickup, "caller":fields.get("agi_callerid","")[:60]}
                def notify_phone():
                    if not apple("voip",target[0],payload):
                        with call_lock:
                            waiting.discard(key); pickups.pop(key,None)
                threading.Thread(target=notify_phone,daemon=True).start()
        elif len(route)==2 and route[0]=="pickup":
            with call_lock:
                key = route[1]
                peer = pickups.get(key,"") if calls.get(key,0)>time.monotonic() else ""
                if peer:
                    pickups[key] = ""
                    source = ringing_legs.pop(key,None)
                    if source: connected_legs[key] = source
            self.wfile.write(f'SET VARIABLE HL_PEER "{peer}"\n'.encode())
            self.rfile.readline(2048)
        elif len(route)==2 and route[0]=="released":
            release_core_call(route[1])
        elif len(route)==2:
            with call_lock:
                if route[0]=="ended": calls.pop(route[1],None); waiting.discard(route[1]); pickups.pop(route[1],None); ringing_legs.pop(route[1],None)
                pickup = route[1] in pickups
                ready = route[1] not in waiting
                active = calls.get(route[1],0)>time.monotonic()
            self.wfile.write(('SET VARIABLE HL_PICKUP "'+str(int(pickup))+'"\n').encode())
            self.rfile.readline(2048)
            self.wfile.write(('SET VARIABLE HL_READY "'+str(int(ready))+'"\n').encode())
            self.rfile.readline(2048)
            self.wfile.write(('SET VARIABLE HL_ACTIVE "'+str(int(active))+'"\n').encode())
            self.rfile.readline(2048)


async def pipe(reader, writer):
    while chunk := await reader.read(65536):
        writer.write(chunk)
        await writer.drain()


async def dispatch(reader, writer):
    peer = None
    try:
        prefix = await asyncio.wait_for(reader.readuntil(b" "),10)
        if len(prefix)>16: return
        http = prefix in (b"GET ", b"POST ", b"DELETE ")
        if not http and prefix not in (b"REGISTER ",b"INVITE ",b"OPTIONS ",b"SIP/2.0 ",b"ACK ",b"BYE ",b"CANCEL ",b"UPDATE ",b"INFO ",b"\r\nREGISTER "): return
        other, peer = await asyncio.open_connection("127.0.0.1", C["api_port"] if http else C["sip_port"])
        peer.write(prefix)
        tasks = [asyncio.create_task(pipe(reader,peer)),asyncio.create_task(pipe(other,writer))]
        _,pending=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
        for t in pending:t.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)
    except (ConnectionError,OSError,ValueError,asyncio.IncompleteReadError,asyncio.LimitOverrunError,asyncio.TimeoutError): pass
    finally:
        if peer: peer.close()
        writer.close()


def tls_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(["http/1.1"])
    context.load_cert_chain(cert, key)
    return context


async def watch_tls(context, cert, key):
    current = None
    while True:
        try:
            revision = (cert.stat().st_mtime_ns, key.stat().st_mtime_ns)
            if revision != current:
                context.load_cert_chain(cert, key)
                current = revision
        except (OSError, ssl.SSLError) as error:
            print("TLS certificate reload will retry:", type(error).__name__, file=sys.stderr, flush=True)
        await asyncio.sleep(30)


def initialize_state():
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
    with database() as db:
        db.execute("create table if not exists phone(id integer primary key,owner text,sms text,voip text,cursor integer)")
        if "pickup" not in {row[1] for row in db.execute("pragma table_info(phone)")} :
            db.execute("alter table phone add column pickup integer not null default 0")
        db.execute("create table if not exists login_epoch(value text primary key)")
        db.execute("""create table if not exists push_delivery(
            kind text primary key,accepted integer,failed integer,reason text)""")
        epoch = hashlib.sha256(C["token"].encode()).hexdigest()
        previous = db.execute("select value from login_epoch limit 1").fetchone()
        if previous and previous[0] != epoch:
            db.execute("delete from phone")
            db.execute("delete from push_delivery")
            db.execute("delete from login_epoch")
        db.execute("insert or ignore into login_epoch values(?)",(epoch,))


async def main():
    global C
    C=json.loads((BASE/"config.json").read_text())
    initialize_state()
    cert, key = BASE / "fullchain.pem", BASE / "tls.key"
    tls = tls_context(cert, key)
    asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, tls.load_cert_chain, cert, key)
    for service in [ThreadingHTTPServer(("127.0.0.1",C["api_port"]),API),socketserver.ThreadingTCPServer(("127.0.0.1",C["agi_port"]),AGI)]:
        threading.Thread(target=service.serve_forever,daemon=True).start()
    threading.Thread(target=sms_loop,daemon=True).start()
    server=await asyncio.start_server(dispatch,C["listen"],C["port"],ssl=tls,limit=8192)
    async with server:
        edge_bind = os.environ.get("HOMELINE_EDGE_BIND")
        if not edge_bind:
            await server.serve_forever()
            return
        edge_dir = Path(os.environ["HOMELINE_EDGE_TLS"])
        edge_cert, edge_key = edge_dir / "leaf.pem", edge_dir / "server.key"
        edge_tls = tls_context(edge_cert, edge_key)
        edge_port = int(os.environ.get("HOMELINE_EDGE_PORT", "19444"))
        edge = await asyncio.start_server(dispatch, edge_bind, edge_port, ssl=edge_tls, limit=8192)
        async with edge:
            await watch_tls(edge_tls, edge_cert, edge_key)

if __name__=="__main__": asyncio.run(main())
