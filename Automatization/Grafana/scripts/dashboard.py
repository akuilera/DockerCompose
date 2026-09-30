"""Builds a single per-device Grafana dashboard.

A dashboard is: title/uid from the device name, the Host variable pinned to
that device, the 13 base panels and (per the flags) the Battery and NVIDIA
GPU rows. The JSON is written raw to disk, so PromQL/Grafana templating uses
single-$ variables like $host, $__rate_interval and $__range.
"""

import re

import panels

BUILT_IN_ANNOTATION = {
    "datasource": {"type": "grafana", "uid": "-- Grafana --"},
    "enable": True,
    "hide": True,
    "iconColor": "rgba(0, 211, 255, 1)",
    "name": "Annotations & Alerts",
    "type": "dashboard",
}


def slug(name):
    """URL-safe uid from a device name (e.g. "My Laptop" -> "my-laptop")."""
    s = re.sub(r"[^A-Za-z0-9]+", "-", name.strip().lower()).strip("-")
    return s or "device"


def _host_variable(device):
    return {
        "current": {"selected": True, "text": device, "value": device},
        "definition": device,
        "hide": 0,
        "includeAll": False,
        "label": "Host",
        "multi": False,
        "name": "host",
        "options": [{"selected": True, "text": device, "value": device}],
        "query": device,
        "refresh": 0,
        "regex": "",
        "skipUrlSync": False,
        "type": "custom",
    }


def build(device, *, battery=False, gpu=False):
    """Return the dashboard dict for `device`, with rows per the flags."""
    panels.reset()

    plist = panels.base_panels()
    y = 34
    if battery:
        plist.extend(panels.battery_row(y))
        y += 4
    if gpu:
        plist.append(panels.gpu_row(y))

    return {
        "annotations": {"list": [BUILT_IN_ANNOTATION]},
        "editable": True,
        "graphTooltip": 1,
        "id": None,
        "links": [],
        "panels": plist,
        "refresh": "30s",
        "schemaVersion": 39,
        "tags": ["infrastructure", "monitoring"],
        "templating": {"list": [_host_variable(device)]},
        "time": {"from": "now-24h", "to": "now"},
        "timepicker": {},
        "timezone": "",
        "title": device,
        "uid": slug(device),
        "version": 1,
    }
