"""Panel builders for the per-device Grafana dashboard.

Replicates the classic 13-panel overview and adds the optional Battery row
(5 stats, shown when DEVICE_BATTERY=1) and the NVIDIA GPU row (8 panels in a
collapsed row, shown when DEVICE_GPU=1). Every query targets the shared
Prometheus datasource (uid "prometheus") and filters on job="node" and
host="$host".
"""

import itertools

DATASOURCE = {"type": "prometheus", "uid": "prometheus"}

_ids = itertools.count(1)

STAT_OPTIONS = {
    "colorMode": "value",
    "graphMode": "none",
    "justifyMode": "auto",
    "orientation": "auto",
    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
    "textMode": "auto",
}

TIMESERIES_OPTIONS = {
    "legend": {
        "calcs": ["last", "max", "mean"],
        "displayMode": "list",
        "placement": "bottom",
        "showLegend": True,
    },
    "tooltip": {"mode": "multi", "sort": "desc"},
}

CPU_STEPS = (("green", None), ("yellow", 80), ("red", 90))
DISK_STEPS = (("green", None), ("yellow", 85), ("red", 95))
TEMP_STEPS = (("green", None), ("yellow", 80), ("red", 95))
BATTERY_STEPS = (("green", None), ("yellow", 50), ("red", 20))


def reset():
    """Restart the panel id counter (each dashboard gets its own ids)."""
    global _ids
    _ids = itertools.count(1)


def _targets(exprs, instant=False):
    out = []
    for i, (expr, legend) in enumerate(exprs):
        target = {
            "refId": chr(ord("A") + i),
            "expr": expr,
            "legendFormat": legend,
            "datasource": DATASOURCE,
        }
        if instant:
            target.update({"range": False, "instant": True})
        out.append(target)
    return out


def _thresholds(*steps):
    return {
        "mode": "absolute",
        "steps": [{"color": color, "value": value} for color, value in steps],
    }


def stat(title, exprs, grid, unit, *, steps=(("green", None),), mappings=None,
         min=None, max=None, decimals=None):
    defaults = {
        "color": {"mode": "thresholds"},
        "mappings": mappings or [],
        "thresholds": _thresholds(*steps),
        "unit": unit,
    }
    if min is not None:
        defaults["min"] = min
    if max is not None:
        defaults["max"] = max
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": next(_ids),
        "type": "stat",
        "title": title,
        "datasource": DATASOURCE,
        "gridPos": grid,
        "targets": _targets(exprs, instant=True),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": STAT_OPTIONS,
    }


def timeseries(title, exprs, grid, unit, *, steps=(("green", None),), min=None,
               max=None, decimals=None):
    defaults = {
        "color": {"mode": "palette-classic"},
        "custom": {
            "axisCenteredZero": False,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {"viz": False, "legend": False, "tooltip": False, "graph": False},
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {"type": "linear"},
            "showPoints": "never",
            "spanNulls": False,
            "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"},
        },
        "mappings": [],
        "thresholds": _thresholds(*steps),
        "unit": unit,
    }
    if min is not None:
        defaults["min"] = min
    if max is not None:
        defaults["max"] = max
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": next(_ids),
        "type": "timeseries",
        "title": title,
        "datasource": DATASOURCE,
        "gridPos": grid,
        "targets": _targets(exprs),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": TIMESERIES_OPTIONS,
    }


def base_panels():
    """The 13 classic overview panels (y 0..34, rows as in the seed dashboard)."""
    node = 'job="node", host="$host"'
    fs_filter = 'fstype!~"tmpfs|overlay|cgroup.*|proc|sysfs|devpts|fuse.*|squashfs|autofs", ' \
                'mountpoint!~"^/(proc|sys|dev|run|var/lib/docker).*"'
    disk_filter = 'device!~"loop.*|ram.*|dm-.*|md.*|sr.*|fd.*|.*p[0-9]+$"'
    net_filter = 'device!~"lo|veth.*|docker.*|br-.*|virbr.*|tun.*|tailscale.*"'

    panels = [
        stat("Uptime",
             [(f'time() - node_boot_time_seconds{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 0, "y": 0},
             "dtdurations"),
        stat("Load (1/5/15)",
             [(f'node_load1{{{node}}}', "load1"),
              (f'node_load5{{{node}}}', "load5"),
              (f'node_load15{{{node}}}', "load15")],
             {"h": 4, "w": 4, "x": 4, "y": 0},
             "short"),
        stat("CPU usage",
             [(f'100 - (avg(rate(node_cpu_seconds_total{{{node}, mode="idle"}}[$__rate_interval])) * 100)',
               "cpu")],
             {"h": 4, "w": 4, "x": 8, "y": 0},
             "percent", steps=CPU_STEPS, min=0, max=100),
        stat("Memory usage",
             [(f'100 * (1 - (node_memory_MemAvailable_bytes{{{node}}} / node_memory_MemTotal_bytes{{{node}}}))',
               "memory")],
             {"h": 4, "w": 4, "x": 12, "y": 0},
             "percent", steps=CPU_STEPS, min=0, max=100),
        stat("Disk used (fullest FS)",
             [(f'max((1 - node_filesystem_avail_bytes{{{node}, {fs_filter}}} / '
               f'node_filesystem_size_bytes{{{node}, {fs_filter}}}) * 100)', "disk")],
             {"h": 4, "w": 4, "x": 16, "y": 0},
             "percent", steps=DISK_STEPS, min=0, max=100),
        stat("Reboots (range)",
             [(f'changes(node_boot_time_seconds{{{node}}}[$__range])', "reboots")],
             {"h": 4, "w": 4, "x": 20, "y": 0},
             "none", min=0, decimals=0),
        timeseries("CPU usage",
                   [(f'100 - (avg by (host) (rate(node_cpu_seconds_total{{{node}, mode="idle"}}[$__rate_interval])) * 100)',
                     "{{host}}")],
                   {"h": 8, "w": 12, "x": 0, "y": 4},
                   "percent", steps=CPU_STEPS, min=0, max=100),
        timeseries("Load average",
                   [(f'node_load1{{{node}}}', "load1"),
                    (f'node_load5{{{node}}}', "load5"),
                    (f'node_load15{{{node}}}', "load15")],
                   {"h": 8, "w": 12, "x": 12, "y": 4},
                   "short", min=0),
        timeseries("Memory & swap",
                   [(f'node_memory_MemTotal_bytes{{{node}}}', "total"),
                    (f'node_memory_MemTotal_bytes{{{node}}} - node_memory_MemAvailable_bytes{{{node}}}', "used"),
                    (f'node_memory_SwapTotal_bytes{{{node}}} - node_memory_SwapFree_bytes{{{node}}}', "swap used")],
                   {"h": 8, "w": 12, "x": 0, "y": 12},
                   "bytes", decimals=1),
        timeseries("Network traffic",
                   [(f'rate(node_network_receive_bytes_total{{{node}, {net_filter}}}[$__rate_interval])',
                     "{{device}} rx"),
                    (f'rate(node_network_transmit_bytes_total{{{node}, {net_filter}}}[$__rate_interval])',
                     "{{device}} tx")],
                   {"h": 8, "w": 12, "x": 12, "y": 12},
                   "Bps", decimals=1),
        timeseries("Disk I/O",
                   [(f'rate(node_disk_read_bytes_total{{{node}, {disk_filter}}}[$__rate_interval])',
                     "{{device}} read"),
                    (f'rate(node_disk_written_bytes_total{{{node}, {disk_filter}}}[$__rate_interval])',
                     "{{device}} write")],
                   {"h": 8, "w": 12, "x": 0, "y": 20},
                   "Bps", decimals=1),
        timeseries("Filesystem usage",
                   [(f'(1 - node_filesystem_avail_bytes{{{node}, {fs_filter}}} / '
                     f'node_filesystem_size_bytes{{{node}, {fs_filter}}}) * 100', "{{mountpoint}}")],
                   {"h": 8, "w": 12, "x": 12, "y": 20},
                   "percent", steps=DISK_STEPS, min=0, max=100),
        timeseries("Temperature",
                   [(f'node_hwmon_temp_celsius{{{node}, chip!~"pci.*"}}', "{{chip}} {{sensor}}")],
                   {"h": 6, "w": 24, "x": 0, "y": 28},
                   "celsius", steps=TEMP_STEPS),
    ]
    return panels


def battery_row(y):
    """Battery stats row (visible), 5 panels high, starting at grid y."""
    node = 'job="node", host="$host"'
    ac_steps = (("red", None), ("green", 1))
    ac_mappings = [{
        "type": "value",
        "options": {
            "0": {"color": "red", "text": "On battery"},
            "1": {"color": "green", "text": "AC connected"},
        },
    }]
    row = [
        stat("Battery level",
             [(f'node_power_supply_capacity{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 0, "y": y},
             "percent", steps=BATTERY_STEPS, min=0, max=100),
        stat("Battery health",
             [("100 * node_power_supply_energy_full{job=\"node\", host=\"$host\"} / "
               "node_power_supply_energy_full_design{job=\"node\", host=\"$host\"}", "__auto")],
             {"h": 4, "w": 4, "x": 4, "y": y},
             "percent", steps=DISK_STEPS, min=0, max=100),
        stat("Cycle count",
             [(f'node_power_supply_cyclecount{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 8, "y": y},
             "none", min=0, decimals=0),
        stat("Power draw",
             [(f'node_power_supply_power_watt{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 12, "y": y},
             "watt", decimals=0),
        stat("Power source",
             [(f'node_power_supply_online{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 16, "y": y},
             "none", steps=ac_steps, mappings=ac_mappings),
    ]
    return row


def gpu_row(y):
    """Collapsed NVIDIA GPU row (8 panels) starting at grid y."""
    node = 'job="node", host="$host"'
    children = [
        timeseries("GPU temperature",
                   [(f'node_gpu_temperature_celsius{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 0, "y": 0},
                   "celsius", steps=TEMP_STEPS),
        timeseries("GPU utilisation",
                   [(f'node_gpu_utilization_percent{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 12, "y": 0},
                   "percent", steps=CPU_STEPS, min=0, max=100),
        timeseries("GPU memory",
                   [(f'node_gpu_memory_used_bytes{{{node}}}', "__auto"),
                    (f'node_gpu_memory_total_bytes{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 0, "y": 8},
                   "bytes"),
        timeseries("GPU power draw",
                   [(f'node_gpu_power_draw_watts{{{node}}}', "__auto"),
                    (f'node_gpu_power_max_limit_watts{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 12, "y": 8},
                   "watt"),
        timeseries("GPU clocks",
                   [(f'node_gpu_clocks_sm_mhz{{{node}}}', "__auto"),
                    (f'node_gpu_clocks_mem_mhz{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 0, "y": 16},
                   "mhertz"),
        timeseries("GPU PCIe link",
                   [(f'node_gpu_pcie_link_gen_current{{{node}}}', "__auto"),
                    (f'node_gpu_pcie_link_width_current{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 12, "y": 16},
                   "none"),
        timeseries("GPU throttle reasons",
                   [(f'node_gpu_throttle_reason_active{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 0, "y": 24},
                   "none"),
        timeseries("GPU heartbeat",
                   [(f'node_gpu_heartbeat_gap_seconds{{{node}}}', "__auto"),
                    (f'node_gpu_heartbeat_max_gap_seconds{{{node}}}', "__auto")],
                   {"h": 8, "w": 12, "x": 12, "y": 24},
                   "s"),
    ]
    return {
        "id": next(_ids),
        "collapsed": True,
        "title": "NVIDIA GPU",
        "type": "row",
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "panels": children,
    }