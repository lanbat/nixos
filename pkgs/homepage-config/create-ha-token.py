#!/usr/bin/env python3
"""Create a Home Assistant long-lived access token for Homepage."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import socket
import ssl
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request


def request_json(
    method: str,
    url: str,
    payload: dict | None = None,
    headers: dict[str, str] | None = None,
) -> dict:
    data = None
    req_headers = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode()
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode())


def post_form(url: str, fields: dict[str, str]) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode())


class SimpleWebSocket:
    def __init__(self, url: str) -> None:
        parsed = urllib.parse.urlparse(url)
        self.host = parsed.hostname or "localhost"
        self.port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        self.path = parsed.path or "/"
        self.secure = parsed.scheme == "wss"
        self.sock = socket.create_connection((self.host, self.port), timeout=30)
        if self.secure:
            context = ssl.create_default_context()
            self.sock = context.wrap_socket(self.sock, server_hostname=self.host)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("websocket handshake failed")
            response += chunk
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError(f"websocket handshake rejected: {response[:200]!r}")

    def recv(self) -> str:
        while True:
            header = self._recv_exact(2)
            length = header[1] & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]
            masked = header[1] & 0x80
            if masked:
                mask = self._recv_exact(4)
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            opcode = header[0] & 0x0F
            if opcode == 0x8:
                raise RuntimeError("websocket closed by peer")
            if opcode == 0x1:
                return payload.decode()

    def send(self, message: str) -> None:
        data = message.encode()
        frame = bytearray([0x81])
        length = len(data)
        if length < 126:
            frame.append(length)
        elif length < 65536:
            frame.append(126)
            frame.extend(struct.pack("!H", length))
        else:
            frame.append(127)
            frame.extend(struct.pack("!Q", length))
        frame.extend(data)
        self.sock.sendall(frame)

    def close(self) -> None:
        self.sock.close()

    def _recv_exact(self, size: int) -> bytes:
        chunks: list[bytes] = []
        remaining = size
        while remaining > 0:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise RuntimeError("websocket connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


def create_token() -> str:
    base_url = os.environ.get("HA_URL", "http://127.0.0.1:8123").rstrip("/")
    public_url = os.environ.get("HA_PUBLIC_URL", base_url).rstrip("/") + "/"
    username = os.environ["OWNER_USERNAME"]
    password = os.environ["OWNER_PASSWORD"]
    client_name = os.environ.get("TOKEN_CLIENT_NAME", "homepage")

    flow = request_json(
        "POST",
        f"{base_url}/auth/login_flow",
        {
            "client_id": public_url,
            "redirect_uri": public_url,
            "handler": ["homeassistant", None],
        },
    )
    result = request_json(
        "POST",
        f"{base_url}/auth/login_flow/{flow['flow_id']}",
        {
            "client_id": public_url,
            "username": username,
            "password": password,
        },
    )
    if result.get("type") != "create_entry":
        raise RuntimeError(f"unexpected login flow result: {result.get('type')}")

    tokens = post_form(
        f"{base_url}/auth/token",
        {
            "grant_type": "authorization_code",
            "code": result["result"],
            "client_id": public_url,
            "redirect_uri": public_url,
        },
    )
    access_token = tokens["access_token"]

    ws_url = base_url.replace("http://", "ws://").replace("https://", "wss://")
    ws_url = f"{ws_url}/api/websocket"
    ws = SimpleWebSocket(ws_url)
    try:
        greeting = json.loads(ws.recv())
        if greeting.get("type") != "auth_required":
            raise RuntimeError(f"unexpected websocket greeting: {greeting}")
        ws.send(json.dumps({"type": "auth", "access_token": access_token}))
        auth_ok = json.loads(ws.recv())
        if auth_ok.get("type") != "auth_ok":
            raise RuntimeError(f"websocket auth failed: {auth_ok}")
        ws.send(
            json.dumps(
                {
                    "id": 1,
                    "type": "auth/long_lived_access_token",
                    "lifespan": 3650,
                    "client_name": client_name,
                }
            )
        )
        token_result = json.loads(ws.recv())
        if not token_result.get("success"):
            raise RuntimeError(f"failed to create long-lived token: {token_result}")
        return token_result["result"]
    finally:
        ws.close()


def main() -> int:
    try:
        print(create_token())
        return 0
    except (urllib.error.URLError, RuntimeError, KeyError) as exc:
        print(f"create-ha-token: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
