"""Forward HomeLine HTTPS origin traffic and WebRTC UDP behind an FRP client."""
import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import selectors
import socket
import ssl
import sys
import threading
import time
from urllib.parse import urlsplit

OFFER = re.compile(r"/api/homeline/rtc/calls/[0-9a-fA-F-]{36}/offer")
HOP_HEADERS = {"connection", "transfer-encoding", "date", "server", "keep-alive",
               "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate"}
CANDIDATE = re.compile(r"(?m)^(a=candidate:\S+ \d+ UDP \d+ )([^\s]+) (\d+)(?= typ host\b)", re.IGNORECASE)
PEER_TIMEOUT = 30
MAX_PEERS = 64


def address(value):
    host, sep, port = value.rpartition(":")
    if not sep or not host or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise argparse.ArgumentTypeError("Expected an IPv4 address or hostname followed by :port")
    return host, int(port)


def public_answer(answer, origin, advertised):
    value = json.loads(answer)
    ip, port = advertised

    def candidate(match):
        if (match[2], int(match[3])) == origin:
            return f"{match[1]}{ip} {port}"
        return match[0]

    sdp = value["sdp"]
    rewritten = CANDIDATE.sub(candidate, sdp)
    if rewritten == sdp and not any(
            (match[2], int(match[3])) == advertised for match in CANDIDATE.finditer(sdp)):
        raise ValueError("Missing local ICE candidate")
    rewritten = re.sub(r"(?m)^(c=IN IP4 )" + re.escape(origin[0]) + r"(?=\r?$)",
                       lambda match: match[1] + ip, rewritten)
    value["sdp"] = re.sub(r"(?m)^(m=audio )" + str(origin[1]) + r"(?= )",
                          lambda match: match[1] + str(port), rewritten)
    return json.dumps(value, separators=(",", ":")).encode()


class API(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def relay(self):
        self.close_connection = True
        path = urlsplit(self.path).path
        if not self.path.startswith("/api/"):
            return self.send_error(404)
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.send_error(400)
        if self.headers.get("Transfer-Encoding") or not 0 <= size <= 65536:
            return self.send_error(400)

        request_headers = {"Accept", "Authorization", "Content-Type"}
        headers = {name: value for name in request_headers if (value := self.headers.get(name)) is not None}
        origin = http.client.HTTPConnection(*self.server.options.http_target, timeout=110)
        sent_headers = False
        try:
            advertised = None
            if self.command == "POST" and OFFER.fullmatch(path):
                host, port = self.server.options.public_udp
                advertised = socket.gethostbyname(host), port
            body = self.rfile.read(size) if size else None
            origin.request(self.command, self.path, body=body, headers=headers)
            response = origin.getresponse()
            rewritten = advertised is not None and response.status == 200
            answer = public_answer(response.read(), self.server.options.ice_origin, advertised) if rewritten else None
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in HOP_HEADERS and not (rewritten and name.lower() == "content-length"):
                    self.send_header(name, value)
            if rewritten:
                self.send_header("Content-Length", str(len(answer)))
            self.send_header("Connection", "close")
            sent_headers = True
            self.end_headers()
            if rewritten:
                self.wfile.write(answer)
            else:
                while chunk := response.read(65536):
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (ValueError, KeyError, OSError, http.client.HTTPException):
            if not sent_headers:
                self.send_error(502)
        finally:
            origin.close()

    do_GET = do_POST = do_DELETE = relay


class GatewayServer(ThreadingHTTPServer):
    timeout = 0.5

    def __init__(self, options):
        self.options = options
        self.tls = server_tls(options)
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(options.http_bind, API)

    def get_request(self):
        connection, peer = super().get_request()
        connection.settimeout(8)
        if self.tls:
            try:
                connection = self.tls.wrap_socket(connection, server_side=True, do_handshake_on_connect=False)
            except OSError:
                connection.close()
                raise
        return connection, peer

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def server_tls(options):
    def context(files):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(*files)
        return tls

    if not options.tls:
        return None
    default = context(options.tls)
    if options.sni_tls:
        hostname, cert, key = options.sni_tls
        alternate = context((cert, key))

        def select(connection, requested, _):
            if requested and requested.lower() == hostname.lower():
                connection.context = alternate

        default.sni_callback = select
    return default


def forward_udp(listener, target_address, stop):
    peers = {}
    with selectors.DefaultSelector() as mux:
        mux.register(listener, selectors.EVENT_READ)
        try:
            while not stop.is_set():
                for key, _ in mux.select(timeout=0.5):
                    try:
                        data, sender = key.fileobj.recvfrom(65535)
                        if key.data is not None:
                            listener.sendto(data, key.data)
                            continue
                        if sender not in peers:
                            if len(peers) >= MAX_PEERS:
                                continue
                            target = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                            try:
                                target.connect(target_address)
                                target.setblocking(False)
                                mux.register(target, selectors.EVENT_READ, sender)
                            except BaseException:
                                target.close()
                                raise
                        else:
                            target, _ = peers[sender]
                        peers[sender] = target, time.monotonic()
                        target.send(data)
                    except (BlockingIOError, ConnectionRefusedError, ConnectionResetError):
                        continue
                now = time.monotonic()
                for sender, (target, touched) in list(peers.items()):
                    if now - touched > PEER_TIMEOUT:
                        mux.unregister(target)
                        target.close()
                        del peers[sender]
        finally:
            for target, _ in peers.values():
                target.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--http-bind", type=address, default="127.0.0.1:22443")
    parser.add_argument("--http-target", type=address, default="127.0.0.1:18086")
    parser.add_argument("--udp-bind", type=address, default="127.0.0.1:22444")
    parser.add_argument("--udp-target", type=address, default="127.0.0.1:20119")
    parser.add_argument("--ice-origin", type=address, default="127.0.0.1:20119")
    parser.add_argument("--public-udp", type=address, required=True)
    parser.add_argument("--tls", nargs=2, metavar=("CERT", "KEY"))
    parser.add_argument("--sni-tls", nargs=3, metavar=("HOST", "CERT", "KEY"))
    options = parser.parse_args()
    if options.sni_tls and not options.tls:
        parser.error("--sni-tls requires --tls")
    stop = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener, GatewayServer(options) as server:
        listener.bind(options.udp_bind)
        listener.setblocking(False)

        def media():
            try:
                forward_udp(listener, options.udp_target, stop)
            finally:
                stop.set()

        worker = threading.Thread(target=media, daemon=True)
        worker.start()
        print("HomeLine FRP HTTP origin and UDP listeners ready", flush=True)
        while not stop.is_set():
            server.handle_request()
        print("UDP worker stopped; restarting both listeners", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
