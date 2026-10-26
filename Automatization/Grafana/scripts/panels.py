"""Panel builders for the single Infrastructure dashboard.

Replicates the classic 13-panel overview (y 0..34), then adds the Memory pressure
section (expanded, always shown, the early warning for memory thrash: pressure
stall, OOM kills, major page faults, D-state tasks, hung task warnings and the
swap/commit headroom), the optional Battery section (expanded, 6 stats, shown
when any device has DEVICE_BATTERY=1) and the NVIDIA GPU section (collapsed by
default, 10 panels, shown when any device has DEVICE_GPU=1). Every panel carries
an absolute gridPos: Grafana treats the gridPos of panels nested in a row as
dashboard-absolute coordinates, so a relative y makes the whole section render
on top of the base panels. Every query targets the shared Prometheus datasource
(uid "prometheus") and filters on job="node" and host="$host".
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
BATTERY_TEMP_STEPS = (("green", None), ("yellow", 40), ("red", 55))
PSI_STEPS = (("green", None), ("yellow", 1), ("red", 10))


def reset():
    """Restart the panel ids (one set per dashboard)."""
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
         min=None, max=None, decimals=None, description=None):
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
    panel = {
        "id": next(_ids),
        "type": "stat",
        "title": title,
        "datasource": DATASOURCE,
        "gridPos": grid,
        "targets": _targets(exprs, instant=True),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": STAT_OPTIONS,
    }
    if description:
        panel["description"] = description
    return panel


def timeseries(title, exprs, grid, unit, *, steps=(("green", None),), min=None,
               max=None, decimals=None, description=None):
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
    panel = {
        "id": next(_ids),
        "type": "timeseries",
        "title": title,
        "datasource": DATASOURCE,
        "gridPos": grid,
        "targets": _targets(exprs),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": TIMESERIES_OPTIONS,
    }
    if description:
        panel["description"] = description
    return panel


def base_panels():
    """The 13 classic overview panels (y 0..34), flat, no rows."""
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
                   [(f'node_hwmon_temp_celsius{{{node}, chip!~"pci.*|applesmc.*"}}', "{{chip}} {{sensor}}")],
                   {"h": 6, "w": 24, "x": 0, "y": 28},
                    "celsius", steps=TEMP_STEPS),
    ]
    return panels


def memory_pressure_section(y):
    """Expanded Memory pressure section starting at grid y.

    Returns (panels, next_y): the row header at y, then the 11 panels with
    absolute gridPos from y+1, and the y where the next section can start.
    """
    node = 'job="node", host="$host"'
    oom_steps = (("green", None), ("red", 1))
    swap_steps = (("red", None), ("yellow", 20), ("green", 50))
    commit_steps = (("green", None), ("yellow", 90), ("red", 100))
    blocked_steps = (("green", None), ("yellow", 1), ("red", 5))
    header = {
        "id": next(_ids),
        "collapsed": False,
        "panels": [],
        "title": "Memory pressure",
        "description": "What to look at when the machine stops responding: pressure stall information for memory and IO, the OOM killer's kill count, the major page-fault rate, D-state processes and the swap and commit headroom that decide whether the next allocation is survivable. The HighMemoryUsage alert needs more than 90% sustained, which is far too late because by then the desktop is already unresponsive, so these panels are for the window that comes before that. Anything here that is empty on an older kernel is a collector that does not exist there, not a mistake in the dashboard.",
        "type": "row",
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
    }
    y += 1
    children = [
        timeseries("PSI memory stall",
                   [(f'100 * rate(node_pressure_memory_stalled_seconds_total{{{node}}}[5m])',
                     "all tasks stalled")],
                   {"h": 8, "w": 12, "x": 0, "y": 0},
                   "percent", steps=PSI_STEPS, min=0, max=100, decimals=2,
                   description="Percentage of wall-clock time in which every runnable task on the device was stalled waiting for memory, which is the Linux pressure stall information (PSI) 'full' stall exported by node_exporter's pressure collector. Flat at 0% is healthy, anything sustained above 1% already means the machine is thrashing, and a spike to 100% is the signature of the whole desktop freezing while the kernel pages to disk. The collector is enabled by default but needs kernel >= 4.20 built with CONFIG_PSI=y; when /proc/pressure is missing these series simply do not exist, so an empty panel there is expected and not a bug."),
        timeseries("PSI memory wait",
                   [(f'increase(node_pressure_memory_waiting_seconds_total{{{node}}}[$__rate_interval])',
                     "summed per task")],
                   {"h": 8, "w": 12, "x": 12, "y": 0},
                   "s", min=0, decimals=1,
                   description="Stall-seconds on memory accumulated by all waiting tasks together inside one $__rate_interval window, which is the PSI 'some' stall. It is summed per task, so the value is unbounded and is deliberately shown in seconds instead of a percentage: a value equal to the window length means that on average one task was stalled the whole window, and ten times the window means ten tasks. This one rises before the system actually stalls, which makes it the early-warning shape, and it is the panel to watch when the machine starts to feel sluggish but the stall panel is still at 0%. Same collector caveat as PSI memory stall: no /proc/pressure, no series."),
        timeseries("PSI IO stall",
                   [(f'100 * rate(node_pressure_io_stalled_seconds_total{{{node}}}[5m])',
                     "all tasks stalled")],
                   {"h": 8, "w": 12, "x": 0, "y": 8},
                   "percent", steps=PSI_STEPS, min=0, max=100, decimals=2,
                   description="Percentage of wall-clock time in which every runnable task was stalled waiting for I/O, the PSI 'full' stall for the io resource. On a healthy machine this sits at 0% and any sustained value above 1% already deserves attention, because it means the whole system is waiting on the storage stack. Together with a non-zero PSI memory stall it confirms real thrash rather than a merely busy disk: memory pressure evicts the working set, the kernel re-reads it from the same disk, and every task queues behind that. Absent on kernels without /proc/pressure, in which case the panel stays empty."),
        timeseries("PSI IO wait",
                   [(f'increase(node_pressure_io_waiting_seconds_total{{{node}}}[$__rate_interval])',
                     "summed per task")],
                   {"h": 8, "w": 12, "x": 12, "y": 8},
                   "s", min=0, decimals=1,
                   description="I/O stall-seconds accumulated by all waiting tasks together inside one $__rate_interval window, the PSI 'some' stall for io. Summed per task like its memory counterpart, so it is shown in seconds and not as a percentage. A rising line here with a flat PSI memory wait means the machine is waiting on storage rather than on memory, which is a different problem and a different fix, so the two are worth reading side by side. No /proc/pressure means no series."),
        stat("OOM kills (range)",
             [(f'increase(node_vmstat_oom_kill{{{node}}}[$__range])', "oom kills")],
             {"h": 4, "w": 6, "x": 0, "y": 16},
             "none", steps=oom_steps, min=0, decimals=0,
             description="Number of processes killed by the kernel out-of-memory killer over the selected time range, a count and not a rate, so zero means no kill happened in the whole range you are looking at. The underlying node_vmstat_oom_kill counter is exported untyped and resets on reboot, which is why a count over the range is used instead of the raw cumulative value that would be misleading after a restart. Any value above 0 is a hard failure, because a process you cared about was sacrificed, and this is the panel that turns a suspected memory incident into a confirmed one."),
        stat("Hung task warnings (range)",
             [(f'increase(node_kernel_hung_tasks_total{{{node}}}[$__range])', "warnings")],
             {"h": 4, "w": 6, "x": 6, "y": 16},
             "none", steps=oom_steps, min=0, decimals=0,
             description="Kernel hung-task warnings raised over the selected time range, a count and not a rate. The metric node_kernel_hung_tasks_total only exists on kernels that expose the kernel.hung_task_detect_count tunable, so on kernels without it this panel is empty and that is expected rather than a bug. A non-zero value means the kernel found a task stuck in uninterruptible sleep for longer than the hung-task timeout, which on a thrashing machine usually means a task blocked on I/O behind page reclaim rather than a driver that happens to hang."),
        stat("Swap free",
             [(f'100 * (node_memory_SwapFree_bytes{{{node}}} / '
               f'(node_memory_SwapTotal_bytes{{{node}}} > 0))', "swap free")],
             {"h": 4, "w": 6, "x": 12, "y": 16},
             "percent", steps=swap_steps, min=0, max=100,
             description="Swap headroom left as a percentage of the configured swap (SwapFree/SwapTotal). It shows No data on a machine with no swap configured, which is the more dangerous case, because then the kernel has no way to absorb a memory spike at all and the OOM killer is the only remaining outcome. Watch this instead of waiting for the memory usage stat to cross 90%, which is far too late: a low value here together with high memory usage is the classic warning that the next large allocation kills something."),
        stat("Commit ratio",
             [(f'100 * (node_memory_Committed_AS_bytes{{{node}}} / node_memory_CommitLimit_bytes{{{node}}})',
               "commit ratio")],
             {"h": 4, "w": 6, "x": 18, "y": 16},
             "percent", steps=commit_steps, min=0, decimals=1,
             description="Committed virtual memory (Committed_AS) as a percentage of the commit limit (CommitLimit), the kernel's promise of how much memory it can still back. Crossing 100% exhausts the overcommit allowance, so further allocations fail and the OOM killer starts choosing victims, which is exactly how a host with plenty of SwapTotal can still be killed. This is the panel that catches the overcommit case that swap headroom alone cannot see, because SwapTotal can be a comfortable-looking 16 GB while the commit limit is already full."),
        timeseries("Major page faults",
                   [(f'rate(node_vmstat_pgmajfault{{{node}}}[5m])', "major faults/s")],
                   {"h": 8, "w": 12, "x": 0, "y": 20},
                   "ops", min=0, decimals=2,
                   description="Rate of major page faults over a 5 minute window, that is faults that had to be served by reading from disk instead of being satisfied from the page cache. This is the closest thing to a direct thrash signal that works on every kernel, because while memory pressure keeps evicting the working set the kernel re-reads it from storage, so sustained non-zero values during an unresponsiveness episode are the cause and not merely the symptom. Spikes next to a high Disk I/O read curve confirm swapping or page reclaim, whereas a flat zero during a freeze points somewhere else entirely, such as I/O wait, a driver or the GPU."),
        timeseries("Blocked procs (D-state)",
                   [(f'max_over_time(node_procs_blocked{{{node}}}[$__rate_interval])', "blocked")],
                   {"h": 8, "w": 12, "x": 12, "y": 20},
                   "none", steps=blocked_steps, min=0, decimals=0,
                   description="Worst number of processes blocked on I/O in uninterruptible sleep, D-state, during each $__rate_interval window. node_procs_blocked is a gauge that rises and falls, so it is read with max_over_time and never with increase(). A non-zero value during a freeze is the smoking gun: those processes cannot be killed and are waiting for the block device, which is what a thrashing kernel looks like from the outside, and the spikes usually arrive shortly before the only remaining option is a forced power-off."),
        timeseries("Memory commitment",
                   [(f'node_memory_Committed_AS_bytes{{{node}}}', "committed"),
                    (f'node_memory_CommitLimit_bytes{{{node}}}', "limit")],
                    {"h": 8, "w": 24, "x": 0, "y": 28},
                    "bytes", decimals=1,
                    description="Committed virtual memory against the commit limit over time. A committed curve that reaches the limit and stays there is the kernel running out of commitment: further allocations fail and the OOM killer starts selecting victims. Unlike the memory usage panels this is about the total amount of memory the system has promised, which is resident memory plus swap, rather than about what happens to be resident right now, so it can predict an OOM kill before the resident memory stat moves much."),
    ]
    y0 = y
    for panel in children:
        panel["gridPos"]["y"] += y0
    return [header] + children, y0 + 36


def battery_section(y):
    """Expanded Battery section starting at grid y.

    Returns (panels, next_y): the row header at y, then 6 stats of w4 that fill
    the 24 columns from y+1, and the y where the next section can start.
    """
    node = 'job="node", host="$host"'
    ac_steps = (("red", None), ("green", 1))
    ac_mappings = [{
        "type": "value",
        "options": {
            "0": {"color": "red", "text": "On battery"},
            "1": {"color": "green", "text": "AC connected"},
        },
    }]
    panels = [{
        "id": next(_ids),
        "collapsed": False,
        "panels": [],
        "title": "Battery",
        "type": "row",
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
    }]
    y += 1
    panels += [
        stat("Battery level",
             [(f'node_power_supply_capacity{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 0, "y": y},
             "percent", steps=BATTERY_STEPS, min=0, max=100),
        stat("Battery health",
             [(f'100 * (node_power_supply_energy_full{{{node}}} / '
               f'node_power_supply_energy_full_design{{{node}}} or '
               f'node_power_supply_charge_full{{{node}}} / '
               f'node_power_supply_charge_full_design{{{node}}})', "__auto")],
             {"h": 4, "w": 4, "x": 4, "y": y},
             "percent", steps=DISK_STEPS, min=0, max=100),
        stat("Cycle count",
             [(f'node_power_supply_cyclecount{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 8, "y": y},
             "none", min=0, decimals=0),
        stat("Power draw",
             [(f'(node_power_supply_power_watt{{{node}}} or '
               f'node_hwmon_curr_amps{{{node}, chip=~"power_supply.*"}} * on(chip) '
               f'node_hwmon_in_volts{{{node}, chip=~"power_supply.*"}})', "__auto")],
             {"h": 4, "w": 4, "x": 12, "y": y},
             "watt", decimals=0),
        stat("Power source",
             [(f'node_power_supply_online{{{node}}}', "__auto")],
             {"h": 4, "w": 4, "x": 16, "y": y},
             "none", steps=ac_steps, mappings=ac_mappings),
        stat("Battery temp",
             [(f'node_power_supply_temp_celsius{{{node}, power_supply=~"BAT.*"}}', "__auto")],
             {"h": 4, "w": 4, "x": 20, "y": y},
             "celsius", steps=BATTERY_TEMP_STEPS, min=0, max=60, decimals=1,
             description="Battery temperature from the power_supply class (node_power_supply_temp_celsius, only for supplies whose name starts with BAT). Sustained heat above 40 degrees ages the cell, and charging normally throttles or stops around 55-60, so a reading climbing while the machine is idle points at a stuck charge controller rather than at workload. Laptops whose battery does not export the temp attribute simply show No data here."),
    ]
    return panels, y + 4


def gpu_section(y):
    """Collapsed NVIDIA GPU section starting at grid y.

    Returns (panels, next_y): one collapsed row whose 10 children carry
    absolute gridPos from y+1 (Grafana stores collapsed-row children with
    dashboard-absolute coordinates), and the y after the row bar. The
    children keep their band below the bar, so expanding the row never
    overlaps the panels that follow.
    """
    node = 'job="node", host="$host"'
    query_mappings = [{
        "type": "value",
        "options": {
            "0": {"color": "red", "text": "Failed"},
            "1": {"color": "green", "text": "OK"},
        },
    }]
    children = [
        timeseries("GPU temperature",
                   [(f'node_gpu_temperature_celsius{{{node}}}', "{{gpu}}")],
                   {"h": 8, "w": 12, "x": 0, "y": y + 1},
                   "celsius", steps=TEMP_STEPS),
        timeseries("GPU utilisation",
                   [(f'node_gpu_utilization_percent{{{node}}}', "{{gpu}}")],
                   {"h": 8, "w": 12, "x": 12, "y": y + 1},
                   "percent", steps=CPU_STEPS, min=0, max=100),
        timeseries("GPU memory",
                   [(f'node_gpu_memory_used_bytes{{{node}}}', "{{gpu}} used"),
                    (f'node_gpu_memory_total_bytes{{{node}}}', "{{gpu}} total")],
                   {"h": 8, "w": 12, "x": 0, "y": y + 9},
                   "bytes"),
        timeseries("GPU power draw",
                   [(f'node_gpu_power_draw_watts{{{node}}}', "{{gpu}} draw"),
                    (f'node_gpu_power_max_limit_watts{{{node}}}', "{{gpu}} limit")],
                   {"h": 8, "w": 12, "x": 12, "y": y + 9},
                   "watt"),
        timeseries("GPU clocks",
                   [(f'node_gpu_clocks_sm_mhz{{{node}}}', "{{gpu}} SM"),
                    (f'node_gpu_clocks_mem_mhz{{{node}}}', "{{gpu}} MEM")],
                   {"h": 8, "w": 12, "x": 0, "y": y + 17},
                   "mhertz"),
        timeseries("GPU PCIe link",
                   [(f'node_gpu_pcie_link_gen_current{{{node}}}', "{{gpu}} gen"),
                    (f'node_gpu_pcie_link_width_current{{{node}}}', "{{gpu}} width")],
                   {"h": 8, "w": 12, "x": 12, "y": y + 17},
                   "none"),
        timeseries("GPU throttle reasons",
                   [(f'node_gpu_throttle_reason_active{{{node}}}', "{{gpu}} {{reason}}")],
                   {"h": 8, "w": 8, "x": 0, "y": y + 25},
                   "none"),
        timeseries("Host heartbeat gap",
                   [(f'node_gpu_heartbeat_gap_seconds{{{node}}}', "gap"),
                    (f'node_gpu_heartbeat_max_gap_seconds{{{node}}}', "max gap")],
                   {"h": 8, "w": 8, "x": 8, "y": y + 25},
                   "s",
                   description="Host-level heartbeat gap (generic). The series keep the historical node_gpu_heartbeat_* names for compatibility; on hosts without an NVIDIA GPU this is still normal."),
        stat("GPU query",
             [(f'node_gpu_query_success{{{node}}}', "__auto")],
             {"h": 8, "w": 8, "x": 16, "y": y + 25},
             "none", steps=(("red", None), ("green", 1)), mappings=query_mappings,
             description="1 if the last nvidia-smi query succeeded (exit code 0 and a numeric GPU index). 0 means timeout or failure — e.g. a driver/library version mismatch after a partially applied update — in which case GpuQueryFailed will fire and the rest of the GPU panels go empty until fixed (usually a reboot)."),
        timeseries("GPU / DRM / LACT journal events",
                   [(f'node_journal_event_recent{{{node}, source="nvrm"}}', "NVRM/Xid"),
                    (f'node_journal_event_recent{{{node}, source="drm"}}', "DRM/amdgpu"),
                    (f'node_journal_event_recent{{{node}, source="lact"}}', "LACT reload"),
                    (f'node_journal_event_recent{{{node}, source="lact-error"}}', "LACT error")],
                   {"h": 8, "w": 24, "x": 0, "y": y + 33},
                   "none", min=0, max=1,
                   description="1 while a matching kernel or LACT line was seen within the recent window, else 0. A step next to a heartbeat gap means the GPU or its LACT userspace driver logged something just before the machine stopped. A hard freeze usually wedges the kernel before anything is written, so no step proves nothing and a step is a correlation, never a cause. A volatile journal (no /var/log/journal) loses lines across a reboot."),
    ]
    row = {
        "id": next(_ids),
        "collapsed": True,
        "title": "NVIDIA GPU",
        "type": "row",
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "panels": children,
    }
    return [row], y + 1
