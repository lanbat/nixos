#!/usr/bin/env python3
"""
On-demand service activator proxy.

Sits in front of a service that should only run when needed.
- When the real service is up: transparently proxies requests to it.
- When the real service is down: starts it, returns a loading page.
- After the service is up: first request that finds it healthy gets proxied.

Usage (via systemd — see modules/server/on-demand.nix):
  python3 activator.py \
    --listen-port 3332 \
    --real-port   3333 \
    --target-svc  podman-bitmagnet.service \
    --stamp-file  /run/ondemand-bitmagnet.stamp
"""

import argparse
import http.client
import http.server
import os
import subprocess
import sys
import threading
import time
import urllib.request
from urllib.parse import urlparse

LOADING_PAGE = """\
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="5">
  <title>Starting service…</title>
  <style>
    body {{
      font-family: system-ui, sans-serif;
      display: flex; flex-direction: column;
      align-items: center; justify-content: center;
      min-height: 100vh; margin: 0;
      background: #0f172a; color: #e2e8f0;
    }}
    .card {{
      background: #1e293b; border-radius: 12px;
      padding: 2rem 3rem; text-align: center;
      box-shadow: 0 4px 24px rgba(0,0,0,.4);
    }}
    h1 {{ font-size: 1.5rem; margin: 0 0 .5rem; }}
    p  {{ color: #94a3b8; margin: 0 0 1.5rem; }}
    .spinner {{
      width: 40px; height: 40px;
      border: 4px solid #334155;
      border-top-color: #6366f1;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto;
    }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    small {{ display: block; margin-top: 1rem; color: #475569; font-size: .8rem; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>Starting {name}…</h1>
    <p>This service is starting up. This page will refresh automatically.</p>
    <div class="spinner"></div>
    <small>Page refreshes every 5 seconds</small>
  </div>
</body>
</html>
"""


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--listen-port", type=int, required=True)
    p.add_argument("--real-port",   type=int, required=True)
    p.add_argument("--target-svc",  required=True)
    p.add_argument("--stamp-file",  required=True)
    return p.parse_args()


ARGS = None
START_LOCK = threading.Lock()
_starting = False


def is_service_healthy(port: int, path: str = "/") -> bool:
    """Return True if we get a non-502 HTTP response from real service."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        conn.request("GET", path)
        r = conn.getresponse()
        conn.close()
        return r.status < 500
    except Exception:
        return False


def start_target_service(svc: str):
    global _starting
    with START_LOCK:
        if _starting:
            return
        _starting = True
    try:
        subprocess.run(
            ["systemctl", "start", svc],
            check=False, capture_output=True,
        )
    finally:
        # Reset after a short delay so we can retry if start failed.
        def _reset():
            time.sleep(30)
            global _starting
            _starting = False
        threading.Thread(target=_reset, daemon=True).start()


def write_stamp(path: str):
    try:
        with open(path, "w") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass


class ActivatorHandler(http.server.BaseHTTPRequestHandler):
    def do_request(self, method: str):
        if is_service_healthy(ARGS.real_port):
            # Service is up — proxy the request.
            write_stamp(ARGS.stamp_file)
            try:
                body_len = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(body_len) if body_len else b""

                conn = http.client.HTTPConnection("127.0.0.1", ARGS.real_port, timeout=30)
                headers = {k: v for k, v in self.headers.items()
                           if k.lower() not in ("host", "connection")}
                headers["Host"] = f"127.0.0.1:{ARGS.real_port}"
                conn.request(method, self.path, body=body or None, headers=headers)
                resp = conn.getresponse()
                resp_body = resp.read()

                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() in ("transfer-encoding", "connection"):
                        continue
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp_body)
                conn.close()
            except Exception as exc:
                self._send_loading(f"Proxy error: {exc}")
        else:
            # Service is not up — trigger start and show loading page.
            start_target_service(ARGS.target_svc)
            self._send_loading()

    def _send_loading(self, msg: str = ""):
        name = ARGS.target_svc.replace("podman-", "").replace(".service", "").title()
        body = LOADING_PAGE.format(name=name).encode()
        self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Retry-After", "5")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):    self.do_request("GET")
    def do_POST(self):   self.do_request("POST")
    def do_PUT(self):    self.do_request("PUT")
    def do_DELETE(self): self.do_request("DELETE")
    def do_HEAD(self):   self.do_request("HEAD")

    def log_message(self, fmt, *args):
        # Only log errors to keep the journal clean.
        if args and str(args[1]) not in ("200", "304"):
            sys.stderr.write(f"[activator] {self.address_string()} - {fmt % args}\n")


def main():
    global ARGS
    ARGS = parse_args()
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", ARGS.listen_port), ActivatorHandler
    )
    print(
        f"[activator] listening on :{ARGS.listen_port} → "
        f":{ARGS.real_port} ({ARGS.target_svc})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
