# node_exporter + NVIDIA GPU heartbeat

Installs a native `node_exporter` on a Linux client, plus an optional GPU
heartbeat that runs every few seconds on a timer. Generic on purpose: it works
on any systemd Linux and every setting is an environment variable, so the same
folder deploys to every client of the monitoring stack.

The server side is the [Prometheus stack](../Prometheus/README.md). The server's
own `node_exporter` runs as a container; this one runs natively, because the
values that matter on a client are the ones only the host can see: real sensor
chips, real block devices, real systemd unit states.

## Why this is not just "download node_exporter"

Three things here exist because the obvious version of each one is wrong in a
way that is invisible until you need it.

**btrfs is not excluded.** Most hardening examples add `btrfs` to
`--collector.filesystem.fs-types-exclude`. On a btrfs root that silently removes
`/` from every filesystem metric, so `FilesystemAlmostFull` and
`DiskFillPredicted` never fire and the panels quietly show nothing. The disk
fills up and nothing says so.

**`/run` is not excluded wholesale.** Removable disks mount under
`/run/media/<user>/<label>`, so excluding all of `/run` hides every external
drive. `/run` itself is tmpfs, which the fstype filter already removes, so there
is nothing to gain by excluding the path.

**The heartbeat exists because a scrape cannot see a freeze.** When the machine
locks up, Prometheus stops getting scrapes. When the machine comes back, the
local timestamps are fresh again. The gap never appears in any time series, so
`up == 0` is the only trace, and it cannot tell you how long the box was dead
or whether it rebooted. The heartbeat writes a file locally on a timer; if the
timer stops, nothing updates the file, and the worst gap is **latched to disk**
and exported as a metric. That latch is the only hard-freeze evidence that can
reach Prometheus, because by definition the box is down while a freeze is
happening. The same file is logged to journald, so the record also survives on
the machine itself.

## Requirements

- systemd, `curl`, `tar`, `awk`, `logger` (`util-linux`), `sha256sum` (`coreutils`)
- root, to install the binary, the units and the exporter's own service account
- port 9100 reachable from the Prometheus server
- for the GPU part only: `nvidia-smi` on `PATH` and a working proprietary driver.
  `GPU_HEARTBEAT_ENABLE=0` skips the whole thing on non-NVIDIA machines.

## Install

```bash
sudo ./install-node-exporter.sh
```

The installer downloads, verifies the checksum, creates the `node_exporter`
service account, installs the units, opens the port in whichever firewall is
actually active, starts everything, and then **verifies the result**: it scrapes
the exporter, counts the metrics, and checks that each important metric family is
present. It specifically checks that `mountpoint="/"` is reported, because that
is the btrfs exclusion bug above, and it tells you the fstype it found.

To change anything, copy `.env.example` to `.env` and edit that first. `.env` is
gitignored and is the only place a real value belongs.

## What the heartbeat exposes

Written to a textfile that `node_exporter` picks up, so the metrics carry the
same `job`, `instance` and `host` labels as everything else and can be joined
with it.

| Metric | Meaning |
|---|---|
| `node_gpu_present` | 1 if `nvidia-smi` is there at all |
| `node_gpu_query_success` | 1 if the last query succeeded, 0 if it timed out or failed |
| `node_gpu_query_duration_seconds` | how long the query took, useful as a leading indicator |
| `node_gpu_last_query_timestamp_seconds` | when the heartbeat last refreshed the file |
| `node_gpu_heartbeat_gap_seconds` | seconds since the previous run; above the threshold the box was not running this script |
| `node_gpu_heartbeat_max_gap_seconds` | **latched** worst gap, the hard-freeze evidence |
| `node_gpu_heartbeat_max_gap_timestamp_seconds` | when that worst gap happened, or 0 |
| `node_gpu_temperature_celsius` | core temperature |
| `node_gpu_utilization_percent` | busy percentage |
| `node_gpu_memory_used_bytes` / `_total_bytes` | in **bytes**, converted from the MiB `nvidia-smi` reports |
| `node_gpu_power_draw_watts` / `node_gpu_power_max_limit_watts` | draw and cap |
| `node_gpu_clocks_sm_mhz` / `node_gpu_clocks_mem_mhz` | core and memory clock |
| `node_gpu_pcie_link_gen_current` / `_width_current` | negotiated PCIe link, for "is it running at x1 again" |
| `node_gpu_pstate_info` | power state as a label (`P0`..`P8`) |
| `node_gpu_clocks_event_reasons_active` | throttle bitmask |
| `node_gpu_throttle_reason_active` | one series per reason, 1 while asserted |

Deliberate omissions, each verified against a real driver:

- `power.limit` is not used. It returns `[N/A]` on some laptop drivers even when
  the limit is perfectly readable, so `power.max_limit` is used instead.
- `temperature.memory` is not used; most laptop drivers report `[N/A]`.
- `clocks_throttle_reasons.display_clock_setting` is not used; `nvidia-smi`
  rejects the **entire** query if one field is unknown, which is why the field
  lists here are short and tested rather than exhaustive.
- No `--collector.hwmon.chip-include` filter. It matches hardware IDs, not
  friendly names, so a filter that works on one machine silently matches nothing
  on the next. Use the max across sensors in the panel instead.
- A value the driver does not report produces **no metric at all**, not a zero.
  A rule can then never act on a value that was never measured.

## The state files

Three small files live next to the metrics, none with a `.prom` extension so the
textfile collector ignores them:

| File | Purpose |
|---|---|
| `nvidia_gpu.prom` | the metrics, replaced atomically every run |
| `nvidia_gpu.lastrun` | epoch of the previous run, for the gap calculation |
| `nvidia_gpu.maxgap` | the latched worst gap and when it happened |

`nvidia_gpu.maxgap` ages out after 30 days (`GPU_HEARTBEAT_MAX_GAP_TTL`, written into the service drop-in by the installer) so a single freeze does not nag forever. To clear it after you have finished investigating a freeze, remove that file and restart the timer.

## Finishing the setup

The installer prints the `NODE_TARGETS` line to add. Add it in Portainer to the
[Prometheus stack](../Prometheus/README.md) as `Update the stack`:

```
NODE_TARGETS=server=node-exporter:9100,<name>=<this-host>:9100
```

The `name=` prefix is what sets `labels.host`, and the Grafana dashboards filter
on it, so a target added without it scrapes fine and renders as `No data`. Do not
edit `targets/nodes.yml` on the server; it is regenerated from `NODE_TARGETS` on
every stack start.

The rules that consume these metrics are in
[../Prometheus/prometheus/rules/alerts.yml](../Prometheus/prometheus/rules/alerts.yml).

## Troubleshooting

```bash
# is it up?
systemctl status node-exporter nvidia-gpu-heartbeat.timer

# what does it think happened?
journalctl -u nvidia-gpu-heartbeat.service -n 50 --no-pager
journalctl -t nvidia-gpu-heartbeat --no-pager      # gap warnings only

# look at the heartbeat output directly
cat /var/lib/node_exporter/textfile_collector/nvidia_gpu.prom

# check the exporter's own view of its collectors
curl -s localhost:9100/metrics | grep node_scrape_collector_success
```

A few things that look like bugs and are not:

- **`node_scrape_collector_success{collector="rapl"} == 0`** and similar. Those
  collectors are absent on most hardware and report 0 by design. The alerting
  rule is scoped to an allowlist of collectors that should always work.
- **No `node_hwmon_*` for a chip you can read with `sensors`.** The hwmon
  collector needs permission to the chip; check the exporter's own error above.
- **`GpuQueryFailed` firing while everything looks fine.** The heartbeat is
  stricter than an interactive `nvidia-smi`: it uses a timeout, so it reports a
  GPU that is slow to answer as a failure. Check
  `node_gpu_query_duration_seconds` before believing it.
- **The port is open but the target is `down`.** Check the firewall and that
  `NODE_EXPORTER_LISTEN` matches what the server is actually dialling.

## Uninstall

```bash
sudo systemctl disable --now node-exporter nvidia-gpu-heartbeat.timer
sudo rm -f /etc/systemd/system/node-exporter.service \
           /etc/systemd/system/nvidia-gpu-heartbeat.{service,timer} \
           /usr/local/bin/node_exporter /usr/local/bin/nvidia-gpu-heartbeat
sudo systemctl daemon-reload
```

The `node_exporter` service account, `/var/lib/node_exporter` and the firewall
rule are left in place on purpose; remove them by hand if you are sure nothing
else uses them. Remove the target from `NODE_TARGETS` too, or Prometheus will
keep trying to scrape a host that is gone.
