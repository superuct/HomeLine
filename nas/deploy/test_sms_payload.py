import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
import gateway


class SMSPayloadTests(unittest.TestCase):
    def test_delivery_health_retains_latest_failure_and_accepted_time(self):
        with tempfile.TemporaryDirectory() as state, patch.object(gateway, "STATE", Path(state)), \
                patch.dict(gateway.C, {"token": "test"}), patch.object(gateway.time, "time", side_effect=[100.5, 102.5]):
            gateway.initialize_state()
            gateway.record_push("alert", "Timeout")
            gateway.record_push("alert")
            self.assertEqual(gateway.push_status(), {
                "alert": {"lastAccepted": 102.5, "lastFailed": 100.5, "lastError": "Timeout"}
            })

    def test_notification_identifies_exact_message_sim_and_installation(self):
        with patch.dict(gateway.C, {"device": "ec20"}):
            value = gateway.sms_payload(82, "10000", "收到信息", "sim-a", "installation-a")
        self.assertEqual((value["message_id"], value["sender"], value["device_id"], value["imsi"], value["installation"]),
                         (82, "10000", "ec20", "sim-a", "installation-a"))
        self.assertEqual(value["aps"]["mutable-content"], 1)

    def test_preview_is_bounded_without_losing_message_identity(self):
        value = gateway.sms_payload(83, "10000", "中" * 2000, None, "installation-a")
        self.assertEqual(len(value["aps"]["alert"]["body"]), 600)
        self.assertEqual(value["message_id"], 83)
        self.assertEqual(value["imsi"], "")
        self.assertEqual(value["aps"]["thread-id"], gateway.sms_payload(84, "10000", "new", "b", "x")["aps"]["thread-id"])


    def test_resume_pending_pushes_after_unregister_and_token_refresh(self):
        with tempfile.TemporaryDirectory() as state, patch.object(gateway, "STATE", Path(state)), \
                patch.dict(gateway.C, {"token": "test"}), patch.object(gateway, "latest_sms", return_value=80):
            gateway.initialize_state()
            gateway.register_phone("owner", "old-sms", "old-voip", True)
            gateway.register_phone("owner", "", "", False)
            with patch.object(gateway, "latest_sms", return_value=95):
                gateway.register_phone("owner", "new-sms", "new-voip", True)
                gateway.register_phone("alias", "new-sms", "new-voip", True)
            with gateway.database() as db:
                self.assertEqual(db.execute("select owner, sms, cursor from phone").fetchone(),
                                 ("alias", "new-sms", 80))


if __name__ == "__main__":
    unittest.main()
