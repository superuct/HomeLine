import json
import socket
import threading
import unittest

from frp_gateway import forward_udp, public_answer


class FRPGatewayTests(unittest.TestCase):
    def test_rewrites_only_the_configured_host_candidate(self):
        sdp = ("m=audio 20119 UDP/TLS/RTP/SAVPF 111\r\n"
               "c=IN IP4 127.0.0.1\r\n"
               "a=candidate:a 1 udp 1 127.0.0.1 20119 typ host\r\n"
               "a=candidate:b 1 udp 1 127.0.0.2 20119 typ host\r\n")
        answer = json.dumps({"type": "answer", "sdp": sdp})
        result = json.loads(public_answer(answer, ("127.0.0.1", 20119), ("192.0.2.3", 63501)))["sdp"]
        self.assertIn("c=IN IP4 192.0.2.3", result)
        self.assertIn("m=audio 63501 ", result)
        self.assertIn("192.0.2.3 63501 typ host", result)
        self.assertIn("127.0.0.2 20119 typ host", result)

    def test_udp_return_path_preserves_each_client(self):
        stop = threading.Event()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as backend, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as a, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as b:
            for sock in (udp, backend, a, b):
                sock.bind(("127.0.0.1", 0))
                sock.settimeout(2)
            udp.setblocking(False)
            worker = threading.Thread(target=forward_udp, args=(udp, backend.getsockname(), stop))
            worker.start()
            try:
                for peer, value in ((a, b"a"), (b, b"b")):
                    peer.sendto(value, udp.getsockname())
                    received, address = backend.recvfrom(20)
                    self.assertEqual(received, value)
                    backend.sendto(received * 2, address)
                    self.assertEqual(peer.recv(20), value * 2)
            finally:
                stop.set()
                worker.join(timeout=2)
            self.assertFalse(worker.is_alive())
