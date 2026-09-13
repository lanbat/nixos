#!/usr/bin/env python3
"""Bootstrap Music Assistant for Home Assistant integration and HA OAuth login."""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import aiohttp
from music_assistant_client import MusicAssistantClient

MA_URL = os.environ.get("MA_URL", "http://127.0.0.1:8095").rstrip("/")
MA_PUBLIC_URL = os.environ["MA_PUBLIC_URL"].rstrip("/")
HA_INTERNAL_URL = os.environ.get("HA_INTERNAL_URL", "http://127.0.0.1:8123").rstrip("/")
HA_PUBLIC_URL = os.environ["HA_PUBLIC_URL"].rstrip("/")
OWNER_USERNAME = os.environ["OWNER_USERNAME"]
OWNER_PASSWORD = os.environ["OWNER_PASSWORD"]
STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/music-assistant/.lanbat-setup"))
COMPLETE_MARKER = STATE_DIR / "complete"
HA_TOKEN_PATH = STATE_DIR / "ha-token"
MA_TOKEN_PATH = STATE_DIR / "ma-token"
# Added later than the rest, so servers set up before still get it.
SNAPCAST_MARKER = STATE_DIR / "snapcast-provider"
SNAPSERVER_HOST = os.environ.get("SNAPSERVER_HOST", "127.0.0.1")
SNAPSERVER_CONTROL_PORT = int(os.environ.get("SNAPSERVER_CONTROL_PORT", "1705"))
HA_CONFIG_ENTRIES = Path(os.environ.get("HA_CONFIG_ENTRIES", "/var/lib/hass/.storage/core.config_entries"))
HASS_BIN = os.environ["HASS_BIN"]
HASS_CONFIG = os.environ.get("HASS_CONFIG", "/var/lib/hass")
HA_TOKEN_CLIENT_NAME = "Music Assistant"
MA_TOKEN_NAME = "Home Assistant"


def log(message: str) -> None:
    print(f"music-assistant-setup: {message}", flush=True)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def wait_for_http(url: str, attempts: int = 30, delay: float = 5.0) -> None:
    import urllib.error
    import urllib.request

    for _ in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                if response.status < 500:
                    return
        except urllib.error.HTTPError as exc:
            if exc.code < 500:
                return
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(delay)
    raise RuntimeError(f"timed out waiting for {url}")


async def fetch_server_info(session: aiohttp.ClientSession) -> dict[str, Any]:
    async with session.get(f"{MA_URL}/info") as response:
        response.raise_for_status()
        return await response.json()


async def ma_login(session: aiohttp.ClientSession) -> str:
    async with session.post(
        f"{MA_URL}/auth/login",
        json={"credentials": {"username": OWNER_USERNAME, "password": OWNER_PASSWORD}},
    ) as response:
        body = await response.json()
        if response.status == 401 or not body.get("success"):
            raise RuntimeError(body.get("error") or "music assistant login failed")
        token = body.get("token") or body.get("access_token")
        if not token:
            raise RuntimeError(f"music assistant login returned no token: {body}")
        return str(token)


async def ensure_ma_admin(session: aiohttp.ClientSession) -> None:
    log(f"ensuring music assistant admin user {OWNER_USERNAME}")
    async with session.post(
        f"{MA_URL}/setup",
        json={
            "username": OWNER_USERNAME,
            "password": OWNER_PASSWORD,
            "device_name": "lanbat-setup",
        },
    ) as response:
        if response.status == 400:
            body = await response.json()
            if body.get("error") == "Setup already completed":
                return
        response.raise_for_status()
        await response.json()


async def create_ma_token_for_ha(
    session: aiohttp.ClientSession, access_token: str
) -> str:
    existing = load_secret(MA_TOKEN_PATH)
    if existing:
        log("reusing existing music assistant token for home assistant")
        return existing

    async def create_token(client: MusicAssistantClient) -> str:
        return await client.auth.create_token(MA_TOKEN_NAME)

    log("creating long-lived music assistant token for home assistant")
    token = await with_ma_client(session, access_token, create_token)
    save_secret(MA_TOKEN_PATH, token)
    return token


async def with_ma_client(
    session: aiohttp.ClientSession,
    access_token: str,
    operation: Any,
) -> Any:
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            async with MusicAssistantClient(MA_URL, session, token=access_token) as client:
                return await operation(client)
        except (aiohttp.ClientError, RuntimeError, OSError) as exc:
            last_error = exc
            await asyncio.sleep(3)
    raise RuntimeError(f"music assistant api connection failed: {last_error}")


async def configure_ma_webserver(client: MusicAssistantClient) -> bool:
    current = await client.config.get_core_config_value("webserver", "base_url")
    if current == MA_PUBLIC_URL:
        return False
    log(f"setting music assistant base_url to {MA_PUBLIC_URL}")
    await client.config.save_core_config("webserver", {"base_url": MA_PUBLIC_URL})
    return True


async def configure_ma_hass_provider(
    client: MusicAssistantClient, ha_token: str
) -> bool:
    providers = await client.config.get_provider_configs(
        provider_domain="hass", include_values=True
    )
    # Public URL is required for browser OAuth redirects; skip TLS verify because
    # Music Assistant talks to Caddy's internal certificate, not a public CA.
    values = {"url": HA_PUBLIC_URL, "token": ha_token, "verify_ssl": False}
    if providers:
        provider = providers[0]
        current = provider.values or {}
        if (
            current.get("url") == values["url"]
            and current.get("token") == values["token"]
            and current.get("verify_ssl") == values["verify_ssl"]
        ):
            return False
        log("updating home assistant provider in music assistant")
        await client.config.save_provider_config(
            "hass", values, instance_id=provider.instance_id
        )
        return True

    log("adding home assistant provider to music assistant")
    await client.config.save_provider_config("hass", values)
    return True


async def configure_ma_snapcast_provider(client: MusicAssistantClient) -> bool:
    """Use the host's snapserver, so its Snapcast clients become players."""
    values = {
        "snapcast_use_external_server": True,
        "snapcast_server_host": SNAPSERVER_HOST,
        "snapcast_server_control_port": SNAPSERVER_CONTROL_PORT,
    }
    providers = await client.config.get_provider_configs(
        provider_domain="snapcast", include_values=True
    )
    if providers:
        provider = providers[0]
        current = provider.values or {}
        if all(current.get(key) == value for key, value in values.items()):
            return False
        log("updating the snapcast player provider in music assistant")
        await client.config.save_provider_config(
            "snapcast", values, instance_id=provider.instance_id
        )
        return True

    log("adding the snapcast player provider to music assistant")
    await client.config.save_provider_config("snapcast", values)
    return True


def mark_done(marker: Path) -> None:
    marker.write_text("ok\n")
    os.chmod(marker, 0o600)


def clear_ha_ip_bans() -> None:
    bans_file = Path(HASS_CONFIG) / "ip_bans.yaml"
    if not bans_file.exists():
        return
    bans_file.write_text("{}\n")
    run(["chown", "hass:hass", str(bans_file)])


def ensure_ha_password() -> None:
    """Align the HA owner password with hass-bootstrap-env (source of truth)."""
    result = subprocess.run(
        [
            "sudo",
            "-u",
            "hass",
            HASS_BIN,
            "--script",
            "auth",
            "-c",
            HASS_CONFIG,
            "validate",
            OWNER_USERNAME,
            OWNER_PASSWORD,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if "Auth invalid" not in result.stdout:
        return
    log(f"syncing home assistant password for {OWNER_USERNAME}")
    run(
        [
            "sudo",
            "-u",
            "hass",
            HASS_BIN,
            "--script",
            "auth",
            "-c",
            HASS_CONFIG,
            "change_password",
            OWNER_USERNAME,
            OWNER_PASSWORD,
        ]
    )


def save_secret(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value + "\n")
    os.chmod(path, 0o600)


def load_secret(path: Path) -> str | None:
    if not path.exists():
        return None
    return path.read_text().strip() or None


def ha_refresh_token_exists_for_ma() -> bool:
    auth_file = Path(HASS_CONFIG) / ".storage/auth"
    if not auth_file.exists():
        return False
    data = json.loads(auth_file.read_text())
    return any(
        entry.get("client_name") == HA_TOKEN_CLIENT_NAME
        and entry.get("token_type") == "long_lived_access_token"
        for entry in data.get("data", {}).get("refresh_tokens", [])
    )


def remove_ha_refresh_token_for_ma() -> None:
    auth_file = Path(HASS_CONFIG) / ".storage/auth"
    if not auth_file.exists():
        return
    data = json.loads(auth_file.read_text())
    tokens = data.get("data", {}).get("refresh_tokens", [])
    filtered = [
        entry
        for entry in tokens
        if entry.get("client_name") != HA_TOKEN_CLIENT_NAME
        or entry.get("token_type") != "long_lived_access_token"
    ]
    if len(filtered) == len(tokens):
        return
    log("removing stale home assistant refresh token for music assistant")
    data["data"]["refresh_tokens"] = filtered
    auth_file.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(auth_file, 0o600)
    run(["chown", "hass:hass", str(auth_file)])
    run(["systemctl", "restart", "home-assistant.service"])
    wait_for_http(f"{HA_INTERNAL_URL}/", attempts=60)
    time.sleep(5)


def existing_ha_token_for_ma() -> str | None:
    return load_secret(HA_TOKEN_PATH)


async def ha_token_is_valid(session: aiohttp.ClientSession, token: str) -> bool:
    async with session.get(
        f"{HA_INTERNAL_URL}/api/",
        headers={"Authorization": f"Bearer {token}"},
    ) as response:
        return response.status == 200


async def create_ha_token_for_ma(session: aiohttp.ClientSession) -> str:
    existing = existing_ha_token_for_ma()
    if existing and await ha_token_is_valid(session, existing):
        log("reusing existing home assistant token for music assistant")
        return existing
    if existing:
        log("existing home assistant token is invalid; recreating")
        HA_TOKEN_PATH.unlink(missing_ok=True)

    if ha_refresh_token_exists_for_ma():
        remove_ha_refresh_token_for_ma()

    log("creating long-lived home assistant token for music assistant")
    clear_ha_ip_bans()
    ensure_ha_password()
    client_id = f"{HA_PUBLIC_URL}/"
    redirect_uri = client_id
    async with session.post(
        f"{HA_INTERNAL_URL}/auth/login_flow",
        json={
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "handler": ["homeassistant", None],
        },
    ) as response:
        response.raise_for_status()
        flow = await response.json()

    async with session.post(
        f"{HA_INTERNAL_URL}/auth/login_flow/{flow['flow_id']}",
        json={
            "client_id": client_id,
            "username": OWNER_USERNAME,
            "password": OWNER_PASSWORD,
        },
    ) as response:
        response.raise_for_status()
        result = await response.json()

    if result.get("type") != "create_entry":
        raise RuntimeError(f"unexpected home assistant login flow result: {result.get('type')}")

    auth_code = result["result"]
    async with session.post(
        f"{HA_INTERNAL_URL}/auth/token",
        data={
            "grant_type": "authorization_code",
            "code": auth_code,
            "client_id": client_id,
            "redirect_uri": redirect_uri,
        },
    ) as response:
        response.raise_for_status()
        tokens = await response.json()

    access_token = tokens["access_token"]
    return await create_ha_long_lived_token_ws(session, access_token)


async def create_ha_long_lived_token_ws(
    session: aiohttp.ClientSession, access_token: str
) -> str:
    ws_url = HA_INTERNAL_URL.replace("http://", "ws://").replace("https://", "wss://")
    ws_url = f"{ws_url}/api/websocket"

    last_error: Exception | None = None
    for attempt in range(5):
        try:
            async with session.ws_connect(ws_url, heartbeat=30) as ws:
                auth_required = await ws.receive_json()
                if auth_required.get("type") != "auth_required":
                    raise RuntimeError(f"unexpected websocket greeting: {auth_required}")

                await ws.send_json({"type": "auth", "access_token": access_token})
                auth_ok = await ws.receive_json()
                if auth_ok.get("type") != "auth_ok":
                    raise RuntimeError(f"home assistant websocket auth failed: {auth_ok}")

                await ws.send_json(
                    {
                        "id": 1,
                        "type": "auth/long_lived_access_token",
                        "lifespan": 365,
                        "client_name": HA_TOKEN_CLIENT_NAME,
                    }
                )
                result = await ws.receive_json()
                if not result.get("success"):
                    raise RuntimeError(
                        f"failed to create home assistant long-lived token: {result}"
                    )
                token = result["result"]
                save_secret(HA_TOKEN_PATH, token)
                return token
        except (aiohttp.ClientError, RuntimeError) as exc:
            last_error = exc
            await asyncio.sleep(3)
    raise RuntimeError(f"home assistant websocket disconnected: {last_error}")


def update_ha_config_entry(ma_token: str) -> None:
    if not HA_CONFIG_ENTRIES.exists():
        log("home assistant config entries not found yet; skipping token update")
        return

    data = json.loads(HA_CONFIG_ENTRIES.read_text())
    entries = data.get("data", {}).get("entries", [])
    updated = False
    for entry in entries:
        if entry.get("domain") != "music_assistant":
            continue
        entry_data = entry.setdefault("data", {})
        if entry_data.get("url") != f"{MA_URL}":
            entry_data["url"] = f"{MA_URL}"
            updated = True
        if entry_data.get("token") != ma_token:
            entry_data["token"] = ma_token
            updated = True

    if not updated:
        for entry in entries:
            if entry.get("domain") == "music_assistant":
                log("home assistant music_assistant entry already configured")
                return

        log("adding home assistant music_assistant config entry")
        now = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
        import secrets

        entry_id = secrets.token_hex(13).upper()
        entries.append(
            {
                "created_at": now,
                "data": {"url": f"{MA_URL}", "token": ma_token},
                "disabled_by": None,
                "discovery_keys": {},
                "domain": "music_assistant",
                "entry_id": entry_id,
                "minor_version": 1,
                "modified_at": now,
                "options": {},
                "pref_disable_new_entities": False,
                "pref_disable_polling": False,
                "source": "user",
                "subentries": [],
                "title": "Music Assistant",
                "unique_id": None,
                "version": 1,
            }
        )
        updated = True

    if not updated:
        return

    log("updating home assistant music_assistant config entry")
    run(["systemctl", "stop", "home-assistant.service"])
    HA_CONFIG_ENTRIES.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(HA_CONFIG_ENTRIES, 0o600)
    run(["chown", "hass:hass", str(HA_CONFIG_ENTRIES)])
    run(["systemctl", "start", "home-assistant.service"])


async def async_main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)

    if COMPLETE_MARKER.exists() and SNAPCAST_MARKER.exists():
        log("already complete")
        return

    wait_for_http(f"{MA_URL}/info")
    wait_for_http(f"{HA_INTERNAL_URL}/")

    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        if COMPLETE_MARKER.exists():
            # Set up before the Snapcast provider was added: add only that.
            ma_access_token = await ma_login(session)
            await with_ma_client(session, ma_access_token, configure_ma_snapcast_provider)
            mark_done(SNAPCAST_MARKER)
            log("complete")
            return

        await ensure_ma_admin(session)

        ha_token = await create_ha_token_for_ma(session)
        ma_access_token = await ma_login(session)

        async def configure_ma(client: MusicAssistantClient) -> bool:
            hass_changed = await configure_ma_hass_provider(client, ha_token)
            web_changed = await configure_ma_webserver(client)
            snapcast_changed = await configure_ma_snapcast_provider(client)
            return hass_changed or web_changed or snapcast_changed

        changed = await with_ma_client(session, ma_access_token, configure_ma)

        if changed:
            log("restarting music assistant to apply configuration")
            run(["systemctl", "restart", "music-assistant.service"])
            wait_for_http(f"{MA_URL}/info")
            await asyncio.sleep(5)
            ma_access_token = await ma_login(session)

        ma_token = await create_ma_token_for_ha(session, ma_access_token)
        update_ha_config_entry(ma_token)

        providers = await session.get(f"{MA_URL}/auth/providers")
        providers.raise_for_status()
        provider_ids = [item["provider_id"] for item in await providers.json()]
        if "homeassistant" not in provider_ids:
            log(
                "warning: homeassistant oauth provider not registered yet "
                "(hass plugin may still be starting)"
            )
        else:
            log("home assistant oauth login is available on the music assistant web ui")

    mark_done(SNAPCAST_MARKER)
    mark_done(COMPLETE_MARKER)
    log("complete")


def main() -> None:
    try:
        asyncio.run(async_main())
    except Exception as exc:  # noqa: BLE001
        log(f"failed: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
