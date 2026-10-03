#!/usr/bin/env python3
"""Connect Music Assistant to its audio sources, declaratively.

  music-assistant-sources sources        radio, podcasts, video channels
  music-assistant-sources audiobookshelf the Audiobookshelf library

Both read the desired state from the JSON file named by MA_SOURCES_CONFIG and
make Music Assistant match it, so they are safe to run again at any time. The
Audiobookshelf link is a separate run because Audiobookshelf lives on the
workload layer: it exists only while the layer is unlocked, and Music Assistant
refuses to add the provider while the server is unreachable.

Environment: MA_URL, OWNER_USERNAME, OWNER_PASSWORD (Music Assistant's admin,
the Home Assistant owner), MA_SOURCES_CONFIG.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import aiohttp
from music_assistant_client import MusicAssistantClient
from music_assistant_client.exceptions import MusicAssistantClientException
from music_assistant_models.enums import MediaType
from music_assistant_models.errors import MusicAssistantError
from radios import FilterBy, Order, RadioBrowser, RadioBrowserError

MA_URL = os.environ.get("MA_URL", "http://127.0.0.1:8095").rstrip("/")
OWNER_USERNAME = os.environ["OWNER_USERNAME"]
OWNER_PASSWORD = os.environ["OWNER_PASSWORD"]
CONFIG: dict[str, Any] = json.loads(Path(os.environ["MA_SOURCES_CONFIG"]).read_text())

# Radio providers whose search finds a named station, best first.
STATION_PROVIDERS = ("radiobrowser", "tunein")


def log(message: str) -> None:
    print(f"music-assistant-sources: {message}", flush=True)


def wait_for_http(url: str, attempts: int = 60, delay: float = 5.0) -> None:
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


async def with_ma_client(session: aiohttp.ClientSession, token: str, operation: Any) -> Any:
    last_error: Exception | None = None
    for _ in range(5):
        try:
            async with MusicAssistantClient(MA_URL, session, token=token) as client:
                return await operation(client)
        except (aiohttp.ClientError, OSError, MusicAssistantClientException) as exc:
            last_error = exc
            await asyncio.sleep(3)
    raise RuntimeError(f"music assistant api connection failed: {last_error}")


def values_of(config: Any) -> dict[str, Any]:
    """A provider config's stored values: the API returns each as a ConfigEntry."""
    return {
        key: getattr(entry, "value", entry) for key, entry in (config.values or {}).items()
    }


async def ensure_provider(
    client: MusicAssistantClient, domain: str, values: dict[str, Any]
) -> bool:
    """Make the single instance of a provider exist with at least these values."""
    configs = await client.config.get_provider_configs(
        provider_domain=domain, include_values=True
    )
    if not configs:
        log(f"adding the {domain} provider")
        await client.config.save_provider_config(domain, values)
        return True
    config = configs[0]
    current = values_of(config)
    wanted = {key: value for key, value in values.items() if current.get(key) != value}
    if not wanted:
        return False
    log(f"updating the {domain} provider")
    await client.config.save_provider_config(domain, wanted, instance_id=config.instance_id)
    return True


async def ensure_podcast_feeds(client: MusicAssistantClient) -> list[str]:
    """One podcastfeed instance per feed URL: the listed podcasts, and the
    bridge's channels (which are also removed once they leave the list)."""
    failures: list[str] = []
    bridge_prefix = CONFIG["bridge"]["prefix"]
    bridged = {f"{bridge_prefix}{name}.xml" for name in CONFIG["bridge"]["feeds"]}
    wanted = list(dict.fromkeys([*CONFIG["podcasts"], *sorted(bridged)]))

    existing = {
        values_of(config).get("feed_url"): config
        for config in await client.config.get_provider_configs(
            provider_domain="podcastfeed", include_values=True
        )
    }
    for url in wanted:
        if url in existing:
            continue
        log(f"subscribing to {url}")
        try:
            await client.config.save_provider_config("podcastfeed", {"feed_url": url})
        except MusicAssistantError as exc:
            log(f"could not subscribe to {url}: {exc}")
            failures.append(url)
    for url, config in existing.items():
        if url and url.startswith(bridge_prefix) and url not in bridged:
            log(f"unsubscribing from {url}, no longer configured")
            await client.config.remove_provider_config(config.instance_id)
    return failures


async def library_stations(client: MusicAssistantClient) -> tuple[set[str], set[str]]:
    """The names and stream URLs of the radio stations already in the library."""
    names: set[str] = set()
    streams: set[str] = set()
    for radio in await client.music.get_library_radios(limit=5000):
        names.add(radio.name.casefold())
        streams.update(mapping.item_id for mapping in radio.provider_mappings)
    return names, streams


async def find_station(client: MusicAssistantClient, name: str) -> str | None:
    """The URI of the radio station called exactly name: from the first radio
    provider that has one, and of those the most popular (a name is often
    taken by several stations)."""
    results = await client.music.search(name, [MediaType.RADIO], limit=50)
    matches = [radio for radio in results.radio if radio.name.casefold() == name.casefold()]

    def rank(radio: Any) -> tuple[int, int]:
        order = list(STATION_PROVIDERS)
        provider = order.index(radio.provider) if radio.provider in order else len(order)
        return provider, -(radio.metadata.popularity or 0)

    return min(matches, key=rank).uri if matches else None


async def find_station_in_country(name: str, country: str) -> str | None:
    """The URI of RadioBrowser's most popular station called exactly name in
    that country (two-letter code), for names several countries use."""
    async with aiohttp.ClientSession() as session:
        browser = RadioBrowser(user_agent="lanbat-music-assistant-sources", session=session)
        try:
            stations = await browser.stations(
                filter_by=FilterBy.NAME_EXACT,
                filter_term=name,
                hide_broken=True,
                order=Order.CLICK_COUNT,
                reverse=True,
                limit=500,
            )
        except (RadioBrowserError, aiohttp.ClientError, TimeoutError) as exc:
            raise MusicAssistantError(f"RadioBrowser lookup of {name!r} failed: {exc}") from exc
    for station in stations:
        if station.country_code.upper() == country.upper():
            return f"radiobrowser://radio/{station.uuid}"
    return None


async def ensure_stations(client: MusicAssistantClient) -> list[str]:
    """Put the configured stations in the library: by name, found through the
    radio providers, or by stream URL."""
    failures: list[str] = []
    names, streams = await library_stations(client)
    for station in CONFIG["stations"]:
        name, url = station["name"], station.get("url")
        if url in streams or name.casefold() in names:
            continue
        try:
            country = station.get("country")
            if url:
                uri = url
            elif country:
                uri = await find_station_in_country(name, country)
            else:
                uri = await find_station(client, name)
            if not uri:
                where = f" in {country}" if country else ""
                log(f"no radio station called {name!r}{where} found")
                failures.append(name)
                continue
            # Slow: adding a station scans its metadata.
            log(f"adding the radio station {name}")
            await client.music.add_item_to_library(uri)
        except MusicAssistantError as exc:
            log(f"could not add the radio station {name}: {exc}")
            failures.append(name)
    return failures


async def configure_sources(client: MusicAssistantClient) -> list[str]:
    failures: list[str] = []
    for domain, values in CONFIG["providers"].items():
        try:
            await ensure_provider(client, domain, values)
        except MusicAssistantError as exc:
            log(f"could not set up the {domain} provider: {exc}")
            failures.append(domain)
    failures += await ensure_podcast_feeds(client)
    failures += await ensure_stations(client)
    return failures


async def configure_audiobookshelf(client: MusicAssistantClient) -> list[str]:
    values = {
        "url": CONFIG["audiobookshelf"]["url"],
        "username": OWNER_USERNAME,
        "password": OWNER_PASSWORD,
    }
    configs = await client.config.get_provider_configs(provider_domain="audiobookshelf")
    try:
        changed = await ensure_provider(client, "audiobookshelf", values)
        if configs and not changed:
            # Added or edited, Music Assistant loads it; otherwise it may still
            # be failing from before the layer was unlocked.
            await client.config.reload_provider(configs[0].instance_id)
            log("reloaded the audiobookshelf provider")
    except MusicAssistantError as exc:
        log(f"could not connect to audiobookshelf: {exc}")
        return ["audiobookshelf"]
    return []


async def async_main(mode: str) -> int:
    if mode == "audiobookshelf":
        wait_for_http(f"{CONFIG['audiobookshelf']['url']}/healthcheck")
        operation = configure_audiobookshelf
    else:
        operation = configure_sources
    wait_for_http(f"{MA_URL}/info")
    timeout = aiohttp.ClientTimeout(total=120)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await ma_login(session)
        failures = await with_ma_client(session, token, operation)
    if failures:
        log(f"failed: {', '.join(failures)}")
        return 1
    log("complete")
    return 0


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in ("sources", "audiobookshelf"):
        sys.exit(__doc__)
    try:
        sys.exit(asyncio.run(async_main(sys.argv[1])))
    except Exception as exc:  # noqa: BLE001
        log(f"failed: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
