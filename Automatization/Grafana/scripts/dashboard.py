"""Builds the single Infrastructure Grafana dashboard.

A dashboard is: a Host query variable (label_values over node_uname_info, so
every device that scrapes shows up on its own), the 13 base panels, the Memory
pressure section, and (per the fleet-wide flags) the Battery and NVIDIA GPU
sections. The JSON is written raw to disk, so PromQL/Grafana templating uses
single-$ variables like $host, $__rate_interval and $__range.
"""

import panels

BUILT_IN_ANNOTATION = {
    "datasource": {"type": "grafana", "uid": "-- Grafana --"},
    "enable": True,
    "hide": True,
    "iconColor": "rgba(0, 211, 255, 1)",
    "name": "Annotations & Alerts",
    "type": "dashboard",
}

# A red vertical marker whenever the kernel or LACT logged a GPU/DRM line. It
# shares its window with the heartbeat gap panel, so a marker overlapping a gap
# is the visual correlation the whole watchdog exists to provide.
EVENT_ANNOTATION = {
    "datasource": {"type": "prometheus", "uid": "prometheus"},
    "enable": True,
    "expr": ('changes(node_journal_events_total{job="node", host="$host", '
             'source=~"nvrm|drm|lact-error"}[2m]) > 0'),
    "hide": False,
    "iconColor": "red",
    "name": "Kernel/GPU events",
    "step": "60s",
    "titleFormat": "kernel/GPU event",
}


def _host_variable():
    """Host dropdown fed by Prometheus, so new devices appear by themselves."""
    query = 'label_values(node_uname_info{job="node"}, host)'
    return {
        "current": {},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "definition": query,
        "hide": 0,
        "includeAll": False,
        "label": "Host",
        "multi": False,
        "name": "host",
        "options": [],
        "query": query,
        "refresh": 1,
        "regex": "",
        "skipUrlSync": False,
        "sort": 1,
        "type": "query",
    }


def build(*, battery=False, gpu=False):
    """Return the dashboard dict, with sections per the fleet-wide flags."""
    panels.reset()

    plist = panels.base_panels()
    y = 34
    mem, y = panels.memory_pressure_section(y)
    plist.extend(mem)
    if battery:
        bat, y = panels.battery_section(y)
        plist.extend(bat)
    if gpu:
        gpu_panels, y = panels.gpu_section(y)
        plist.extend(gpu_panels)

    return {
        "annotations": {"list": [BUILT_IN_ANNOTATION, EVENT_ANNOTATION]},
        "editable": True,
        "graphTooltip": 1,
        "id": None,
        "links": [],
        "panels": plist,
        "refresh": "30s",
        "schemaVersion": 39,
        "tags": ["infrastructure", "monitoring"],
        "templating": {"list": [_host_variable()]},
        "time": {"from": "now-24h", "to": "now"},
        "timepicker": {},
        "timezone": "",
        "title": "Infrastructure",
        "uid": "infrastructure",
        "version": 1,
    }
