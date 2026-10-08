"""assistant-router --port 8092 --local-url ... --cloud-url ... --mode local-first"""
from __future__ import annotations

import argparse
import logging

from aiohttp import web

from .server import Config, make_app


def main() -> None:
    p = argparse.ArgumentParser(prog="assistant-router")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8092)
    p.add_argument("--local-url", required=True)
    p.add_argument("--local-model", required=True)
    p.add_argument("--cloud-url", required=True)
    p.add_argument("--cloud-model", default="smart")
    p.add_argument("--mode", choices=["local-first", "cloud-first", "local-only"], default="local-first")
    p.add_argument("--log-path")
    a = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    cfg = Config(a.local_url, a.local_model, a.cloud_url, a.cloud_model, a.mode, log_path=a.log_path)
    web.run_app(make_app(cfg), host=a.host, port=a.port, print=None)


if __name__ == "__main__":
    main()
