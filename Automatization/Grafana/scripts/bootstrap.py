#!/usr/bin/env python3
"""Grafana bootstrap: seed the datasource/provider and generate one dashboard
per device from the Devices/ registry.

Runs first in the Grafana stack (depends_on: service_completed_successfully).
Mount layout:
  /scripts       this directory                (read-only, from the repo clone)
  /devices       the Devices/ registry         (read-only, from the repo clone)
  /provisioning  provisioning output           (written under PATH_TO_CONTAINERS)

The datasource and provider files are seeded only when missing/empty, so
server-side edits survive an update. The per-device dashboards are always
regenerated (stale files are deleted first), so adding/removing a device only
means adding/removing one .env and updating the stack.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dashboard

NAME_RE = re.compile(r"^[A-Za-z0-9 ._-]+$")

PROVISIONING = os.environ.get("P", "/provisioning")
DEVICES = os.environ.get("DEVICES", "/devices")
DATASOURCES = os.path.join(PROVISIONING, "datasources")
DASHBOARDS = os.path.join(PROVISIONING, "dashboards")
DEVICE_DIR = os.path.join(DASHBOARDS, "devices")
LEGACY_DASHBOARDS = ("server-overview.json", "client-1-overview.json")

DATASOURCE_YML = (
    "apiVersion: 1\n"
    "\n"
    "datasources:\n"
    "  - name: Prometheus\n"
    "    uid: prometheus\n"
    "    type: prometheus\n"
    "    access: proxy\n"
    "    url: http://prometheus:9090\n"
    "    isDefault: true\n"
    "    editable: false\n"
)

PROVIDER_YML = (
    "apiVersion: 1\n"
    "\n"
    "providers:\n"
    "  - name: \"Infrastructure\"\n"
    "    orgId: 1\n"
    "    folder: \"Infrastructure\"\n"
    "    type: file\n"
    "    disableDeletion: false\n"
    "    updateIntervalSeconds: 30\n"
    "    allowUiUpdates: false\n"
    "    options:\n"
    "      path: /etc/grafana/provisioning/dashboards\n"
)


def parse_device_env(path):
    """Read one Devices/<device>/.env and return (name, battery, gpu)."""
    values = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            values[key.strip()] = val.strip().strip('"').strip("'")
    name = values.get("DEVICE_NAME", "")
    if not NAME_RE.match(name):
        raise SystemExit(
            f"[bootstrap] ERROR: {path}: DEVICE_NAME {name!r} is missing or has "
            f"characters outside [A-Za-z0-9 ._-]"
        )
    battery = values.get("DEVICE_BATTERY", "0") == "1"
    gpu = values.get("DEVICE_GPU", "0") == "1"
    return name, battery, gpu


def seed_if_empty(path, content, label):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)
    print(f"[bootstrap] seeded {label}: {path}")
    return True


def remove_legacy_dashboards():
    for name in LEGACY_DASHBOARDS:
        path = os.path.join(DASHBOARDS, name)
        if os.path.exists(path):
            os.remove(path)
            print(f"[bootstrap] removed legacy dashboard: {path}")


def generate_dashboards(devices):
    os.makedirs(DEVICE_DIR, exist_ok=True)
    for old in os.listdir(DEVICE_DIR):
        os.remove(os.path.join(DEVICE_DIR, old))
    for name, battery, gpu in devices:
        doc = dashboard.build(name, battery=battery, gpu=gpu)
        path = os.path.join(DEVICE_DIR, f"{doc['uid']}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
        rows = "base"
        if battery:
            rows += "+battery"
        if gpu:
            rows += "+gpu"
        print(f"[bootstrap] dashboard {doc['uid']} (title {name!r}, rows {rows}) -> {path}")


def main():
    print("[bootstrap] dirs")
    os.makedirs(DATASOURCES, exist_ok=True)
    os.makedirs(DASHBOARDS, exist_ok=True)

    print("[bootstrap] 1/3 datasource")
    seed_if_empty(os.path.join(DATASOURCES, "prometheus.yml"), DATASOURCE_YML, "datasource")

    print("[bootstrap] 2/3 provider")
    seed_if_empty(os.path.join(DASHBOARDS, "dashboards.yml"), PROVIDER_YML, "provider")

    print(f"[bootstrap] 3/3 dashboards from {DEVICES}/<device>/.env")
    remove_legacy_dashboards()
    devices = []
    for entry in sorted(os.listdir(DEVICES)):
        env_path = os.path.join(DEVICES, entry, ".env")
        if os.path.isfile(env_path):
            devices.append(parse_device_env(env_path))
    if not devices:
        raise SystemExit(
            "[bootstrap] ERROR: no device entries found under /devices.\n"
            "[bootstrap]        Create one Devices/<device>/.env per machine inside the\n"
            "[bootstrap]        cloned repository, then Update the stack."
        )
    generate_dashboards(devices)
    print(f"[bootstrap] dashboards OK: {len(devices)} device(s)")
    print("[bootstrap] done")


if __name__ == "__main__":
    main()