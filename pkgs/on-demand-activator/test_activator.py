"""Tests for the on-demand activator proxy, against a local fake service.

Run: python3 -m unittest discover -s pkgs/on-demand-activator
"""

import argparse
import http.server
import os
import socket
import tempfile
import threading
import unittest

import activator


class FakeService:
    """A raw-socket stand-in for the real service. A plain GET gets "ok"; a
    request carrying `Connection: Upgrade` and `Upgrade: websocket` gets
    101 Switching Protocols and then every byte is echoed back, as a
    WebSocket server keeps the connection open after the upgrade."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.port = self.sock.getsockname()[1]
        self.upgrade_requests = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with conn:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
            header_block, rest = head.split(b"\r\n\r\n", 1)
            lines = header_block.decode("latin-1").split("\r\n")
            headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:])}
            upgrading = (
                "upgrade" in headers.get("connection", "").lower()
                and headers.get("upgrade", "").lower() == "websocket"
            )
            if not upgrading:
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                return
            self.upgrade_requests.append((lines[0], headers))
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            )
            if rest:
                conn.sendall(rest)
            while True:
                data = conn.recv(4096)
                if not data:
                    return
                conn.sendall(data)

    def close(self):
        self.sock.close()


class ActivatorTest(unittest.TestCase):
    def setUp(self):
        self.service = FakeService()
        self.tmp = tempfile.TemporaryDirectory()
        activator.ARGS = argparse.Namespace(
            listen_port=0,
            real_port=self.service.port,
            target_svc="podman-demo.service",
            stamp_file=os.path.join(self.tmp.name, "stamp"),
        )
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), activator.ActivatorHandler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.service.close()
        self.tmp.cleanup()

    def _connect(self):
        client = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(client.close)
        return client

    @staticmethod
    def _read_head(client):
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = client.recv(4096)
            if not chunk:
                break
            head += chunk
        return head

    def test_plain_request_is_proxied(self):
        client = self._connect()
        client.sendall(b"GET /api/heartbeat HTTP/1.1\r\nHost: demo.example\r\nConnection: close\r\n\r\n")
        response = b""
        while chunk := client.recv(4096):
            response += chunk
        self.assertTrue(response.startswith(b"HTTP/1.0 200") or response.startswith(b"HTTP/1.1 200"))
        self.assertTrue(response.endswith(b"ok"))

    def test_websocket_upgrade_stays_open_both_ways(self):
        # RomM starts library scans over a socket.io WebSocket; a proxy that
        # answers 101 and then ends the exchange drops the connection at once.
        client = self._connect()
        client.sendall(
            b"GET /ws/socket.io/?EIO=4&transport=websocket HTTP/1.1\r\n"
            b"Host: demo.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        head = self._read_head(client)
        self.assertIn(b" 101 ", head.split(b"\r\n", 1)[0])
        for message in (b"hello", b"and again"):
            client.sendall(message)
            self.assertEqual(client.recv(4096), message)

        request_line, headers = self.service.upgrade_requests[0]
        self.assertEqual(request_line, "GET /ws/socket.io/?EIO=4&transport=websocket HTTP/1.1")
        self.assertEqual(headers["host"], "demo.example")
        self.assertIn("x-forwarded-for", headers)

    def test_websocket_traffic_counts_as_activity(self):
        # The idle timer stops the service when the stamp goes stale; a long
        # scan driven over the WebSocket must keep it fresh.
        client = self._connect()
        client.sendall(
            b"GET /ws HTTP/1.1\r\nHost: demo.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        )
        self._read_head(client)
        os.remove(activator.ARGS.stamp_file)
        client.sendall(b"ping")
        self.assertEqual(client.recv(4096), b"ping")
        self.assertTrue(os.path.exists(activator.ARGS.stamp_file))


if __name__ == "__main__":
    unittest.main()
