import sqlite3
import unittest
from unittest.mock import Mock

from radio import Radio


class SMSRetentionTests(unittest.TestCase):
    def test_db_failure_leaves_modem_slot_for_retry(self):
        modem = Mock(usable=True)
        modem._command.return_value = ["+CMGR: 1,,5", "001122"]
        archive = Mock()
        archive.ingest.side_effect = [sqlite3.OperationalError("busy"), False]
        radio = Radio(modem, archive, "test", pcm_fd=-1)
        radio.sms_storage = "SM"
        slot = ("SM", "7")
        radio.events[slot] = 0
        radio.poll_sms()
        self.assertIn(slot, radio.events)
        modem._command.assert_called_once_with("AT+CMGR=7")
        radio.sms_retry_at[slot] = 0
        radio.poll_sms()
        modem._command.assert_called_with("AT+CMGD=7")
        self.assertNotIn(slot, radio.events)

    def test_scans_received_read_and_unread_without_queueing_outgoing(self):
        modem = Mock(usable=True)
        modem._command.side_effect = lambda command: (
            ["+CMGL: 1,0,,5", "001122", "+CMGL: 2,1,,5", "003344", "+CMGL: 3,3,,5", "005566"]
            if command == "AT+CMGL=4" else [])
        radio = Radio(modem, Mock(), "test", pcm_fd=-1)
        radio.scan_sms()
        self.assertEqual(set(radio.events), {("SM", "1"), ("ME", "1"), ("SM", "2"), ("ME", "2")})
