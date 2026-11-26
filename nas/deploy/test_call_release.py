"""Regression checks for the modem leg after an iPhone picks up a call."""
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import gateway

class CallReleaseTests(unittest.TestCase):
    def setUp(self):
        for mapping in (gateway.calls, gateway.ringing_legs, gateway.connected_legs, gateway.pickups):
            mapping.clear()
        gateway.waiting.clear()

    @patch("gateway.subprocess.run")
    def test_connected_call_releases_after_ringing_deadline_and_only_once(self, run):
        run.return_value = SimpleNamespace(returncode=0)
        gateway.calls["call-a"] = time.monotonic() - 90
        gateway.connected_legs["call-a"] = "Quectel/ec20-040000002b"
        gateway.connected_legs["call-b"] = "Quectel/ec20-040000002c"
        gateway.release_core_call("call-a")
        gateway.release_core_call("call-a")
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][-1], "channel request hangup Quectel/ec20-040000002b")
        self.assertIn("call-b", gateway.connected_legs)

    @patch("gateway.subprocess.run")
    def test_failed_hangup_remains_retryable(self, run):
        gateway.connected_legs["call-a"] = "Quectel/ec20-040000002b"
        run.return_value = SimpleNamespace(returncode=1)
        with self.assertRaises(OSError):
            gateway.release_core_call("call-a")
        self.assertIn("call-a", gateway.connected_legs)
        run.return_value = SimpleNamespace(returncode=0)
        gateway.release_core_call("call-a")
        self.assertNotIn("call-a", gateway.connected_legs)

    @patch("gateway.subprocess.run")
    def test_reject_still_releases_ringing_channel(self, run):
        run.return_value = SimpleNamespace(returncode=0)
        gateway.ringing_legs["call-a"] = "Quectel/ec20-040000002b"
        gateway.release_core_call("call-a")
        self.assertEqual(run.call_count, 1)
        self.assertFalse(gateway.ringing_legs)

if __name__ == "__main__":
    unittest.main()
