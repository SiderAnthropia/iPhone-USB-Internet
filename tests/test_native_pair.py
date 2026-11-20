"""Native enrollment tests. No real phone or route changes."""
from pathlib import Path
import json
import socket
import sys
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import native_pair
import phone_network as protocol
CONFIG = {'serial': 'TEST-DEVICE-1234', 'token': 'a' * 64}

class PairTests(unittest.TestCase):
    def exchange(self, response):
        client, server = socket.socketpair()
        requests = []
        def phone():
            with server:
                requests.append(json.loads(protocol.read_frame(server, 4096)))
                protocol.reply(server, **response)
        worker = threading.Thread(target=phone); worker.start()
        try:
            with patch.object(native_pair.pc_test, 'connect_phone', return_value=client) as connect:
                result = native_pair.enroll(CONFIG)
                connect.assert_called_once_with(CONFIG, 18764)
            return result, requests
        finally:
            client.close(); worker.join(3)
    def test_code_matches_swift(self):
        self.assertEqual(native_pair.code(CONFIG), '891902')
    def test_confirmed_pairing(self):
        result, requests = self.exchange(dict(ok=True, service='native-ios', version=1, code='891902'))
        self.assertIn('Start sharing', result)
        self.assertEqual(requests[0]['op'], 'pair-native')
        self.assertEqual(requests[0]['token'], CONFIG['token'])
        self.assertNotIn(CONFIG['token'], result)
    def test_rejection_and_wrong_confirmation(self):
        for change in [dict(ok=False), dict(ok='yes'), dict(service='other'), dict(code='000000'), dict(version=2), dict(version=True)]:
            response=dict(ok=True, service='native-ios', version=1, code='891902'); response.update(change)
            with self.subTest(change=change), self.assertRaises(RuntimeError): self.exchange(response)
    def test_missing_listener(self):
        with patch.object(native_pair.pc_test, 'connect_phone', side_effect=OSError('closed')):
            with self.assertRaisesRegex(RuntimeError, 'tap Pair with PC'): native_pair.enroll(CONFIG)
    def test_invalid_configuration_never_opens_usb(self):
        with patch.object(native_pair.pc_test, 'connect_phone') as connect:
            with self.assertRaises(ValueError): native_pair.enroll(dict(serial='bad',token='bad'))
            connect.assert_not_called()

if __name__ == '__main__': unittest.main(verbosity=2)
