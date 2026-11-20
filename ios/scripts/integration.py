"""Exercise the actual compiled Swift relay with Python wire clients on macOS."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = 'a' * 64

def exact(s, n):
    b = b''
    while len(b) < n:
        p = s.recv(n-len(b))
        if not p: raise EOFError()
        b += p
    return b

def frame(data): return struct.pack('!I', len(data)) + data
def receive(s): return exact(s, struct.unpack('!I', exact(s, 4))[0])
def open_relay(op, **kwargs):
    s = socket.create_connection(('127.0.0.1', 18766), timeout=8)
    s.sendall(frame(json.dumps(dict(token=TOKEN, op=op, **kwargs)).encode()))
    return s, json.loads(receive(s))

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while b := self.request.recv(32768): self.request.sendall(b)
        self.request.sendall(b'END')

class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, s = self.request
        s.sendto(data, self.client_address)

class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

class ProtocolTests(unittest.TestCase):
    def test_01_ping_and_fragmentation(self):
        with socket.create_connection(('127.0.0.1',18766), timeout=8) as s:
            message = frame(json.dumps(dict(op='ping',token=TOKEN)).encode())
            for b in message: s.sendall(bytes([b]))
            r = json.loads(receive(s))
            self.assertTrue(r['ok']); self.assertIn('native-ios',r['capabilities']); self.assertEqual(r['max_sessions'],128)

    def test_02_invalid_auth_and_frames(self):
        for data in [frame(b'[]'), frame(b'{'), frame(b'{"op":"ping","token":"wrong"}'), b'\0\0\0\0', struct.pack('!I',65537)]:
            with socket.create_connection(('127.0.0.1',18766), timeout=8) as s:
                s.sendall(data)
                try: self.assertFalse(json.loads(receive(s))['ok'])
                except (EOFError, ConnectionResetError): pass

    def test_03_tcp_bytes_and_half_close(self):
        s, r = open_relay('tcp',host='127.0.0.1',port=tcp.server_address[1])
        with s:
            self.assertTrue(r['ok'],r)
            data = os.urandom(2*1024*1024)
            def upload(): s.sendall(data); s.shutdown(socket.SHUT_WR)
            t = threading.Thread(target=upload); t.start()
            self.assertEqual(exact(s,len(data)+3),data+b'END'); t.join(10)

    def test_04_udp_multiple_destinations(self):
        s,r = open_relay('udp')
        with s:
            self.assertTrue(r['ok'])
            for _ in range(3):
                for server in (udp1,udp2):
                    data = os.urandom(1000)
                    packet = b'\0\0\0\1'+socket.inet_aton('127.0.0.1')+struct.pack('!H',server.server_address[1])+data
                    s.sendall(frame(packet)); self.assertEqual(receive(s),packet)

    def test_05_concurrency(self):
        def one(_):
            s,r = open_relay('tcp',host='127.0.0.1',port=tcp.server_address[1])
            with s:
                self.assertTrue(r['ok'],r); s.sendall(b'hello'); self.assertEqual(exact(s,5),b'hello')
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool: list(pool.map(one,range(60)))

    def test_06_bad_destinations(self):
        for host,port in [('10.0.0.1',80),('::1',80),('localhost',0),('localhost',True),('localhost',1.5),('bad host',80)]:
            s,r = open_relay('tcp',host=host,port=port)
            with s: self.assertFalse(r['ok'],r)

    def test_07_pairing(self):
        with socket.create_connection(('127.0.0.1',18764),timeout=8) as s:
            s.sendall(frame(json.dumps(dict(op='pair-native',version=1,token=TOKEN,name='Test PC')).encode()))
            r=json.loads(receive(s)); self.assertTrue(r['ok']); self.assertEqual(r['service'],'native-ios')
            expected=f'{int.from_bytes(hashlib.sha256(TOKEN.encode()).digest()[:4],"big")%1000000:06d}'
            self.assertEqual(r['code'],expected)

if __name__ == '__main__':
    tcp=TCPServer(('127.0.0.1',0),Echo); udp1=socketserver.UDPServer(('127.0.0.1',0),UDP); udp2=socketserver.UDPServer(('127.0.0.1',0),UDP)
    for server in (tcp,udp1,udp2): threading.Thread(target=server.serve_forever,daemon=True).start()
    binary=subprocess.check_output(['swift','build','--package-path',str(ROOT/'Core'),'--show-bin-path'],text=True).strip()
    process=subprocess.Popen([str(Path(binary)/'RelayHarness'),'--allow-loopback'])
    try:
        for _ in range(100):
            try:
                s,r=open_relay('ping'); s.close(); break
            except OSError: time.sleep(.1)
        else: raise RuntimeError('Swift relay did not start')
        result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ProtocolTests))
        if not result.wasSuccessful(): raise SystemExit(1)
    finally:
        process.terminate(); process.wait(timeout=10)
        for server in (tcp,udp1,udp2): server.shutdown(); server.server_close()
