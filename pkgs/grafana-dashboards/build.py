#!/usr/bin/env python3
"""Generate Grafana dashboard JSON for Telegraf → InfluxDB metrics."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

DS = {"type": "influxdb", "uid": "influxdb-homelab"}
BUCKET = "metrics"


def flux(query: str) -> str:
    return query.strip()


def ts(
    panel_id: int,
    title: str,
    query: str,
    *,
    x: int,
    y: int,
    w: int = 12,
    h: int = 8,
    unit: str | None = None,
    min_val: float | None = None,
    max_val: float | None = None,
    description: str | None = None,
) -> dict[str, Any]:
    defaults: dict[str, Any] = {
        "custom": {
            "drawStyle": "line",
            "lineWidth": 1,
            "fillOpacity": 15,
            "showPoints": "never",
            "stacking": {"mode": "none"},
        }
    }
    if unit:
        defaults["unit"] = unit
    if min_val is not None:
        defaults["min"] = min_val
    if max_val is not None:
        defaults["max"] = max_val
    panel: dict[str, Any] = {
        "id": panel_id,
        "type": "timeseries",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "query": flux(query)}],
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom"},
            "tooltip": {"mode": "multi"},
        },
    }
    if description:
        panel["description"] = description
    return panel


def stat(
    panel_id: int,
    title: str,
    query: str,
    *,
    x: int,
    y: int,
    w: int = 6,
    h: int = 4,
    unit: str = "short",
    thresholds: list[tuple[float | None, str]] | None = None,
    description: str | None = None,
) -> dict[str, Any]:
    steps = [{"color": color, "value": value} for value, color in (thresholds or [(None, "green")])]
    panel: dict[str, Any] = {
        "id": panel_id,
        "type": "stat",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "query": flux(query)}],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "thresholds": {"mode": "absolute", "steps": steps},
            },
            "overrides": [],
        },
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "orientation": "auto",
            "textMode": "value_and_name",
            "colorMode": "value",
            "graphMode": "area",
        },
    }
    if description:
        panel["description"] = description
    return panel


def row(panel_id: int, title: str, y: int, description: str | None = None) -> dict[str, Any]:
    panel: dict[str, Any] = {
        "id": panel_id,
        "type": "row",
        "title": title,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "collapsed": False,
        "panels": [],
    }
    if description:
        panel["description"] = description
    return panel


def table(
    panel_id: int,
    title: str,
    query: str,
    *,
    x: int,
    y: int,
    w: int = 24,
    h: int = 8,
    renames: dict[str, str] | None = None,
) -> dict[str, Any]:
    panel: dict[str, Any] = {
        "id": panel_id,
        "type": "table",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "query": flux(query)}],
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
    }
    if renames:
        panel["transformations"] = [
            {"id": "organize", "options": {"renameByName": renames}}
        ]
    return panel


def bargauge(
    panel_id: int,
    title: str,
    query: str,
    *,
    x: int,
    y: int,
    w: int = 12,
    h: int = 8,
) -> dict[str, Any]:
    return {
        "id": panel_id,
        "type": "bargauge",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "query": flux(query)}],
        "fieldConfig": {
            "defaults": {
                "unit": "percent",
                "min": 0,
                "max": 100,
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "yellow", "value": 80},
                        {"color": "red", "value": 95},
                    ],
                },
            },
            "overrides": [],
        },
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": True},
            "orientation": "horizontal",
            "displayMode": "gradient",
            "showUnfilled": True,
        },
    }


def pie(panel_id: int, title: str, query: str, *, x: int, y: int, w: int = 8, h: int = 8) -> dict[str, Any]:
    return {
        "id": panel_id,
        "type": "piechart",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "query": flux(query)}],
        "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
        "options": {
            "legend": {"displayMode": "table", "placement": "right", "values": ["value"]},
            "pieType": "donut",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": True},
        },
    }


def dashboard(uid: str, title: str, panels: list[dict[str, Any]], **extra: Any) -> dict[str, Any]:
    return {
        "uid": uid,
        "title": title,
        "tags": extra.pop("tags", ["homelab", "telegraf"]),
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 1,
        "refresh": "30s",
        "time": {"from": "now-6h", "to": "now"},
        "panels": panels,
        **extra,
    }


def range_query(measurement: str, field: str, *, host: str | None = None, extra_filter: str = "", agg: bool = True) -> str:
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    agg_line = (
        "\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)"
        if agg
        else ""
    )
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "{measurement}")
  |> filter(fn: (r) => r._field == "{field}"){host_filter}{extra_filter}{agg_line}
"""


def disk_path_filter() -> str:
    return '\n  |> filter(fn: (r) => r.path == "/" or r.path =~ /^\\/mnt\\// or r.path =~ /^\\/srv\\//)'


def disk_capacity_table(*, host: str | None = None) -> str:
    """Pivot used/free/total/used_percent into table rows per mount."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    group_cols = '["path", "_field"]' if host else '["host", "path", "_field"]'
    pivot_key = '["path"]' if host else '["host", "path"]'
    sort_cols = '["path"]' if host else '["host", "path"]'
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "used_percent" or r._field == "used" or r._field == "free" or r._field == "total"){host_filter}{disk_path_filter()}
  |> group(columns: {group_cols})
  |> last()
  |> pivot(rowKey: {pivot_key}, columnKey: ["_field"], valueColumn: "_value")
  |> group()
  |> sort(columns: {sort_cols})
"""


def disk_used_percent_last(*, host: str | None = None) -> str:
    """Latest used_percent per mount (for bargauge panels)."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    group_after = '["path"]' if host else '["host", "path"]'
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "used_percent"){host_filter}{disk_path_filter()}
  |> last()
  |> group(columns: {group_after})
"""


def disk_inodes_last(*, host: str | None = None) -> str:
    """Latest inodes_used_percent per mount (for bargauge panels)."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    group_after = '["path"]' if host else '["host", "path"]'
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "inodes_used_percent"){host_filter}{disk_path_filter()}
  |> last()
  |> group(columns: {group_after})
"""


def disk_highest_usage_stat() -> str:
    """Per-host max filesystem usage across filtered mounts."""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "used_percent"){disk_path_filter()}
  |> group(columns: ["host", "path"])
  |> last()
  |> group(columns: ["host"])
  |> max(column: "_value")
"""


def disk_used_percent_timeseries(*, host: str | None = None) -> str:
    """Filesystem usage over time."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "used_percent"){host_filter}{disk_path_filter()}
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
"""


def disk_inodes_timeseries(*, host: str | None = None) -> str:
    """Inode usage over time."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk")
  |> filter(fn: (r) => r._field == "inodes_used_percent"){host_filter}{disk_path_filter()}
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
"""


def cpu_usage_from_idle(
    *,
    host: str | None = None,
    cpu_filter: str = "",
    agg: bool = True,
    last_only: bool = False,
) -> str:
    """Derive CPU usage as 100 - usage_idle (Telegraf omits usage_active)."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    agg_line = (
        "\n  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)"
        if agg and not last_only
        else ""
    )
    last_line = '\n  |> last()\n  |> group(columns: ["host"])' if last_only else ""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "cpu")
  |> filter(fn: (r) => r._field == "usage_idle"){host_filter}{cpu_filter}
  |> map(fn: (r) => ({{ r with _field: "usage", _value: 100.0 - r._value }})){agg_line}{last_line}
"""


def cpu_usage_per_core(*, host: str | None = None) -> str:
    """Per-core CPU usage derived from usage_idle."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "cpu")
  |> filter(fn: (r) => r._field == "usage_idle")
  |> filter(fn: (r) => r.cpu != "cpu-total"){host_filter}
  |> map(fn: (r) => ({{ r with _field: "usage", _value: 100.0 - r._value }}))
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
"""


def swap_used_percent(*, host: str | None = None) -> str:
    """Compute swap_used_percent over time from swap_free and swap_total."""
    host_filter = f'\n  |> filter(fn: (r) => r.host == "{host}")' if host else ""
    return f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mem")
  |> filter(fn: (r) => r._field == "swap_free" or r._field == "swap_total"){host_filter}
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> pivot(rowKey: ["_time", "host"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({{
    r with
    _field: "swap_used_percent",
    _value: if exists r.swap_total and r.swap_total > 0.0 then
      float(v: r.swap_total - r.swap_free) / float(v: r.swap_total) * 100.0
    else
      0.0
  }}))
"""


def overview() -> dict[str, Any]:
    panels: list[dict[str, Any]] = []
    pid = 1

    panels.append(row(pid, "Headline", 0))
    pid += 1
    y = 1

    for i, (title, query, unit, thresholds) in enumerate(
        [
            (
                "CPU usage",
                cpu_usage_from_idle(
                    cpu_filter='\n  |> filter(fn: (r) => r.cpu == "cpu-total")',
                    agg=False,
                    last_only=True,
                ),
                "percent",
                [(None, "green"), (70, "yellow"), (90, "red")],
            ),
            (
                "Memory usage",
                range_query("mem", "used_percent", agg=False) + "\n  |> last()\n  |> group(columns: [\"host\"])",
                "percent",
                [(None, "green"), (75, "yellow"), (90, "red")],
            ),
            (
                "Highest disk usage",
                disk_highest_usage_stat(),
                "percent",
                [(None, "green"), (80, "yellow"), (95, "red")],
            ),
        ]
    ):
        panels.append(
            stat(
                pid,
                title,
                query,
                x=i * 8,
                y=y,
                w=8,
                h=5,
                unit=unit,
                thresholds=thresholds,
            )
        )
        pid += 1

    panels.append(row(pid, "Trends", 6))
    pid += 1
    panels.extend(
        [
            ts(
                pid,
                "CPU usage",
                cpu_usage_from_idle(cpu_filter='\n  |> filter(fn: (r) => r.cpu == "cpu-total")'),
                x=0,
                y=7,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(pid + 1, "Memory usage", range_query("mem", "used_percent"), x=12, y=7),
            ts(
                pid + 2,
                "Network receive",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net")
  |> filter(fn: (r) => r._field == "bytes_recv")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=15,
                unit="Bps",
            ),
            ts(
                pid + 3,
                "Network transmit",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net")
  |> filter(fn: (r) => r._field == "bytes_sent")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=15,
                unit="Bps",
            ),
            ts(pid + 4, "Load average (1m)", range_query("system", "load1"), x=0, y=23),
            ts(
                pid + 5,
                "Temperature",
                range_query("temp", "temp"),
                x=12,
                y=23,
                unit="celsius",
            ),
        ]
    )
    pid += 6

    panels.append(row(pid, "Storage & swap", 31))
    pid += 1
    panels.extend(
        [
            ts(
                pid,
                "Disk usage by mount",
                disk_used_percent_timeseries(),
                x=0,
                y=32,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 1,
                "Swap usage",
                swap_used_percent(),
                x=12,
                y=32,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 2,
                "Disk read throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "read_bytes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=40,
                unit="Bps",
            ),
            ts(
                pid + 3,
                "Disk write throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "write_bytes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=40,
                unit="Bps",
            ),
        ]
    )

    return dashboard(
        "homelab-overview",
        "Homelab Overview",
        panels,
        links=[
            {"title": "Host detail", "type": "link", "url": "/d/homelab-host/homelab-host-detail", "icon": "dashboard"},
            {"title": "Storage", "type": "link", "url": "/d/homelab-storage/homelab-storage", "icon": "dashboard"},
            {"title": "Services", "type": "link", "url": "/d/homelab-services/homelab-services", "icon": "dashboard"},
        ],
    )


def host_detail() -> dict[str, Any]:
    panels: list[dict[str, Any]] = []
    pid = 1
    host_var = "${host}"

    panels.append(row(pid, "Compute", 0))
    pid += 1
    panels.extend(
        [
            ts(
                pid,
                "CPU total",
                cpu_usage_from_idle(
                    host=host_var,
                    cpu_filter='\n  |> filter(fn: (r) => r.cpu == "cpu-total")',
                ),
                x=0,
                y=1,
                w=8,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 1,
                "CPU by core",
                cpu_usage_per_core(host=host_var),
                x=8,
                y=1,
                w=8,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 2,
                "CPU breakdown",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "cpu")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r.cpu == "cpu-total")
  |> filter(fn: (r) => r._field == "usage_user" or r._field == "usage_system" or r._field == "usage_iowait" or r._field == "usage_steal")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=16,
                y=1,
                w=8,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 3,
                "Memory",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mem")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "used" or r._field == "available" or r._field == "cached" or r._field == "buffered")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=9,
                unit="bytes",
            ),
            ts(
                pid + 4,
                "Swap",
                swap_used_percent(host=host_var),
                x=12,
                y=9,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 5,
                "Load average",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "system")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "load1" or r._field == "load5" or r._field == "load15")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=17,
                w=8,
            ),
            ts(
                pid + 6,
                "Temperature",
                range_query("temp", "temp", host=host_var),
                x=8,
                y=17,
                w=8,
                unit="celsius",
            ),
            ts(
                pid + 7,
                "Processes",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "processes")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "running" or r._field == "sleeping" or r._field == "zombies" or r._field == "blocked")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=16,
                y=17,
                w=8,
            ),
        ]
    )
    pid += 8

    panels.append(row(pid, "Storage & network", 25))
    pid += 1
    panels.extend(
        [
            bargauge(
                pid,
                "Filesystem usage",
                disk_used_percent_last(host=host_var),
                x=0,
                y=26,
            ),
            bargauge(
                pid + 1,
                "Inode usage",
                disk_inodes_last(host=host_var),
                x=12,
                y=26,
            ),
            ts(
                pid + 2,
                "Disk I/O throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "read_bytes" or r._field == "write_bytes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=34,
                unit="Bps",
            ),
            ts(
                pid + 3,
                "Disk I/O operations",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "reads" or r._field == "writes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=34,
                unit="iops",
            ),
            ts(
                pid + 4,
                "Network throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net")
  |> filter(fn: (r) => r.host == "{host_var}")
  |> filter(fn: (r) => r._field == "bytes_recv" or r._field == "bytes_sent")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=42,
                w=24,
                unit="Bps",
            ),
            table(
                pid + 5,
                "Filesystem capacity",
                disk_capacity_table(host=host_var),
                x=0,
                y=50,
                h=9,
                renames={
                    "path": "Mount",
                    "free": "Free",
                    "total": "Total",
                    "used": "Used",
                    "used_percent": "Used %",
                },
            ),
        ]
    )

    return dashboard(
        "homelab-host",
        "Homelab Host Detail",
        panels,
        templating={
            "list": [
                {
                    "name": "host",
                    "label": "Host",
                    "type": "query",
                    "datasource": DS,
                    "query": {
                        "query": f'import "influxdata/influxdb/schema"\nschema.tagValues(bucket: "{BUCKET}", tag: "host")',
                        "refId": "InfluxVariableQuery",
                    },
                    "refresh": 2,
                    "sort": 1,
                    "includeAll": False,
                    "multi": False,
                    "current": {"selected": True, "text": "core", "value": "core"},
                }
            ]
        },
        links=[
            {"title": "Overview", "type": "link", "url": "/d/homelab-overview/homelab-overview", "icon": "dashboard"},
            {"title": "Storage", "type": "link", "url": "/d/homelab-storage/homelab-storage", "icon": "dashboard"},
        ],
    )


def services() -> dict[str, Any]:
    panels: list[dict[str, Any]] = []
    pid = 1
    systemd_base = f"""
from(bucket: "{BUCKET}")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "systemd_units")
  |> filter(fn: (r) => r.host == "core")
  |> filter(fn: (r) => r._field == "active_code")
"""
    systemd_range = f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "systemd_units")
  |> filter(fn: (r) => r.host == "core")
  |> filter(fn: (r) => r._field == "active_code")
"""
    nfs_base = f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "nfsstat")
  |> filter(fn: (r) => r.host == "core")
"""

    panels.append(row(pid, "Systemd (server)", 0, "Collected by Telegraf systemd_units input on the server only."))
    pid += 1
    panels.extend(
        [
            stat(
                pid,
                "Failed units",
                systemd_base
                + """
  |> filter(fn: (r) => r.active == "failed")
  |> group(columns: ["name"])
  |> last()
  |> group()
  |> count()
""",
                x=0,
                y=1,
                w=6,
                thresholds=[(None, "green"), (1, "red")],
            ),
            stat(
                pid + 1,
                "Inactive units",
                systemd_base
                + """
  |> filter(fn: (r) => r.active == "inactive")
  |> group(columns: ["name"])
  |> last()
  |> group()
  |> count()
""",
                x=6,
                y=1,
                w=6,
                thresholds=[(None, "green"), (1, "yellow")],
            ),
            stat(
                pid + 2,
                "Active units",
                systemd_base
                + """
  |> filter(fn: (r) => r.active == "active")
  |> group(columns: ["name"])
  |> last()
  |> group()
  |> count()
""",
                x=12,
                y=1,
                w=6,
            ),
            pie(
                pid + 3,
                "Units by state",
                systemd_base
                + """
  |> group(columns: ["name"])
  |> last()
  |> group(columns: ["active"])
  |> count()
""",
                x=18,
                y=1,
                w=6,
                h=5,
            ),
            table(
                pid + 4,
                "Non-active systemd units",
                systemd_base
                + """
  |> filter(fn: (r) => r.active != "active")
  |> group(columns: ["name"])
  |> last()
  |> keep(columns: ["name", "active", "sub", "load"])
  |> sort(columns: ["active", "name"])
""",
                x=0,
                y=6,
                h=10,
                renames={"name": "Unit", "active": "Active", "sub": "Sub", "load": "Load"},
            ),
            ts(
                pid + 5,
                "Failed units over time",
                systemd_range
                + """
  |> filter(fn: (r) => r.active == "failed")
  |> group(columns: ["name"])
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
  |> group(columns: ["_time"])
  |> count()
""",
                x=0,
                y=16,
                w=12,
            ),
            ts(
                pid + 6,
                "Inactive units over time",
                systemd_range
                + """
  |> filter(fn: (r) => r.active == "inactive")
  |> group(columns: ["name"])
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
  |> group(columns: ["_time"])
  |> count()
""",
                x=12,
                y=16,
                w=12,
            ),
        ]
    )
    pid += 7

    panels.append(
        row(
            pid,
            "NFS client (server)",
            24,
            "Per-mount stats from Telegraf nfsclient input (measurement nfsstat).",
        )
    )
    pid += 1
    panels.extend(
        [
            ts(
                pid,
                "NFS operations",
                nfs_base
                + """
  |> filter(fn: (r) => r._field == "ops")
  |> group(columns: ["mountpoint", "operation"])
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=25,
                unit="ops",
            ),
            ts(
                pid + 1,
                "NFS latency",
                nfs_base
                + """
  |> filter(fn: (r) => r._field == "rtt_per_op")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=25,
                unit="ms",
            ),
            ts(
                pid + 2,
                "NFS retransmits",
                nfs_base
                + """
  |> filter(fn: (r) => r._field == "retrans")
  |> group(columns: ["mountpoint", "operation"])
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=33,
                w=12,
            ),
            ts(
                pid + 3,
                "NFS throughput",
                nfs_base
                + """
  |> filter(fn: (r) => r._field == "bytes")
  |> group(columns: ["mountpoint", "operation"])
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=33,
                w=12,
                unit="Bps",
            ),
        ]
    )

    return dashboard(
        "homelab-services",
        "Homelab Services",
        panels,
        tags=["homelab", "telegraf", "systemd"],
        links=[
            {"title": "Overview", "type": "link", "url": "/d/homelab-overview/homelab-overview", "icon": "dashboard"},
        ],
    )


def storage() -> dict[str, Any]:
    panels: list[dict[str, Any]] = []
    pid = 1

    panels.append(row(pid, "Capacity", 0))
    pid += 1
    panels.extend(
        [
            table(
                pid,
                "Filesystem usage (all hosts)",
                disk_capacity_table(),
                x=0,
                y=1,
                h=10,
                renames={
                    "host": "Host",
                    "path": "Mount",
                    "free": "Free",
                    "total": "Total",
                    "used": "Used",
                    "used_percent": "Used %",
                },
            ),
            bargauge(
                pid + 1,
                "Highest usage per mount",
                disk_used_percent_last(),
                x=0,
                y=11,
                h=9,
                w=24,
            ),
        ]
    )
    pid += 2

    panels.append(row(pid, "Trends", 20))
    pid += 1
    panels.extend(
        [
            ts(
                pid,
                "Disk usage over time",
                disk_used_percent_timeseries(),
                x=0,
                y=21,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 1,
                "Inode usage over time",
                disk_inodes_timeseries(),
                x=12,
                y=21,
                unit="percent",
                min_val=0,
                max_val=100,
            ),
            ts(
                pid + 2,
                "Disk read throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "read_bytes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=29,
                unit="Bps",
            ),
            ts(
                pid + 3,
                "Disk write throughput",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "write_bytes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=29,
                unit="Bps",
            ),
            ts(
                pid + 4,
                "Disk read IOPS",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "reads")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=0,
                y=37,
                unit="iops",
            ),
            ts(
                pid + 5,
                "Disk write IOPS",
                f"""
from(bucket: "{BUCKET}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "diskio")
  |> filter(fn: (r) => r._field == "writes")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
""",
                x=12,
                y=37,
                unit="iops",
            ),
        ]
    )

    return dashboard(
        "homelab-storage",
        "Homelab Storage",
        panels,
        tags=["homelab", "telegraf", "storage"],
        links=[
            {"title": "Overview", "type": "link", "url": "/d/homelab-overview/homelab-overview", "icon": "dashboard"},
            {"title": "Host detail", "type": "link", "url": "/d/homelab-host/homelab-host-detail", "icon": "dashboard"},
        ],
    )


def main() -> None:
    out = Path(__file__).parent
    dashboards = {
        "homelab-overview.json": overview(),
        "homelab-host.json": host_detail(),
        "homelab-services.json": services(),
        "homelab-storage.json": storage(),
    }
    for name, data in dashboards.items():
        (out / name).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {name}")


if __name__ == "__main__":
    main()
