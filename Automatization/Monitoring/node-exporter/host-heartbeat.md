# Host heartbeat

Part of the [node_exporter helper](README.md). `install-node-exporter.sh` installs the host heartbeat unconditionally on every machine, because the one thing it exists for — noticing that the box stayed powered on while nothing ran on it — depends on no hardware at all. The NVIDIA GPU query is an optional section of the same script, and journal correlation is another, so there is one timer and one state machine instead of several competing over the same question.

The heartbeat writes into the `node_exporter` textfile directory, so its metrics carry the same `job`, `instance` and `host` labels as everything else the exporter serves and can be joined with it.

## Why a scrape cannot see a freeze

A `node_exporter` scrape cannot detect a hard lock. When the machine freezes, the scrape fails and the series goes stale, which looks exactly like "the box was rebooted" or "the network died", and by the time it answers again the local timestamps are fresh again, so the gap never appears in any series at all. `up == 0` is the only trace, and it cannot tell you how long the box was dead or whether it rebooted.

The heartbeat writes a local file on a timer instead, and the interesting case is the one where it does **not** run: the machine was powered on and this timer did not fire, which is only knowable from a timestamp the script left behind earlier. Prometheus can never see that gap directly, because Prometheus is, by definition, not running while it happens. So the script latches the worst gap to disk and exports it as a metric; that latch is the only hard-freeze evidence that can reach Prometheus, and the same record is logged to journald so it also survives on the machine itself.

## How a gap is classified

The previous NVIDIA-only heartbeat kept one number: the largest gap it had ever seen, latched for 30 days. One number cannot describe an intermittent fault, and the old script could not tell a suspend from a freeze, so every ordinary night of sleep raised a hard-freeze alert. The rewrite classifies every gap instead, in a fixed order from cheapest and most unambiguous to most speculative:

| Order | Class | Condition | Meaning |
|---|---|---|---|
| 1 | `unknown` | state file missing, unreadable, malformed or from another schema version | not evidence of anything; rebase |
| 2 | `reboot` | the boot id changed, or the stored uptime is greater than the current one | the machine went down and came back; the cause is indeterminate |
| 3 | `clock-step` | the wall clock moved backwards | a clock correction, not a gap |
| 4 | `suspend` | a completed sleep transition spans the gap (from the systemd-sleep hook) | the machine was asleep, not stuck |
| 5 | `freeze` | same boot id, uptime did not decrease, gap above the threshold | the real signal: powered on, but this timer did not run for that long |
| 6 | `unknown` | a gap above the absolute sanity bound | the stored value is corrupt; rebase |

Steps 1, 2, 3 and 6 are state-integrity problems evaluated regardless of gap size. Steps 4 and 5 only apply above `HOST_HEARTBEAT_GAP_THRESHOLD`, because anything at or below it is a healthy run and produces no event. A reboot is reported as "indeterminate" on purpose: a user reboot, a power cut, a crash and a kernel panic with auto-reboot are indistinguishable from user space, and writing "freeze" there would invent evidence.

**Suspend is detected with a hook, not with a clock.** Comparing the wall clock across the gap is useless because `/proc/uptime` is `CLOCK_BOOTTIME`, which advances during a deep suspend exactly like `CLOCK_REALTIME`, so both sides of a naive comparison advance together. The companion file `host-heartbeat-sleep` is installed into `/usr/lib/systemd/system-sleep/` and writes a small marker around each sleep transition, which the heartbeat consumes. The honest caveat: an EC-initiated sleep or a hand-written `echo mem > /sys/power/state` never runs the hook, so such a gap is still classified `freeze`.

## Settings

All settings live in `.env` next to `install-node-exporter.sh` (see [.env.example](.env.example)). The names below are the current `HOST_HEARTBEAT_*` spellings; older installations know the GPU-related ones as `GPU_HEARTBEAT_*`, and the installer still reads those as a fallback, but everything new is spelled `HOST_HEARTBEAT_*`.

| Variable | Default | Meaning |
|---|---|---|
| `HOST_HEARTBEAT_ENABLE` | `1` | install the heartbeat at all; `0` removes it and its timer, and this host reports no freeze evidence |
| `HOST_HEARTBEAT_INTERVAL` | `15s` | timer interval; it sets the resolution of a freeze report |
| `HOST_HEARTBEAT_GPU_ENABLE` | `auto` | `auto` queries `nvidia-smi` when it is present, `1` forces the query, `0` skips it |
| `HOST_HEARTBEAT_TIMEOUT` | `5` | seconds before `nvidia-smi` (and `journalctl`) are killed by `timeout(1)` |
| `HOST_HEARTBEAT_GAP_THRESHOLD` | `60` | a gap longer than this is an event; must comfortably exceed the interval |
| `HOST_HEARTBEAT_SANITY_GAP` | `5184000` | a gap longer than this (60 days) is treated as corrupt and rebases |
| `HOST_HEARTBEAT_MAX_GAP_TTL` | `2592000` | how long a latched freeze keeps firing `GpuFreezeDetected`; 30 days, `0` latches forever |
| `HOST_HEARTBEAT_EVENT_RETENTION` | `2592000` | how long the classified event history is kept; 30 days |
| `HOST_HEARTBEAT_EVENT_MAX` | `5000` | line cap on the event history, so a reboot loop cannot fill the disk |
| `HOST_HEARTBEAT_MARKER_DIR` | textfile dir | where `host-heartbeat-sleep` leaves its marker |
| `HOST_HEARTBEAT_SLEEP_HOOK_DIR` | `/usr/lib/systemd/system-sleep` | where the sleep hook is installed |
| `HOST_HEARTBEAT_WAIT` | `45` | how long the installer waits for the first heartbeat metric |
| `HOST_HEARTBEAT_JOURNAL` | `auto` | `auto` reads the kernel and LACT journals when `journalctl` is present, `1` forces it, `0` turns it off |
| `HOST_HEARTBEAT_JOURNAL_RECENT` | `900` | how long a matched journal line keeps `node_journal_event_recent` at 1 |

The installer writes these into a drop-in under the internal `NODE_HOST_*` names the script reads; you set the `HOST_HEARTBEAT_*` names and never touch the drop-in by hand.

## What the heartbeat exposes

Written to `host_heartbeat.prom` and picked up by the textfile collector.

| Metric | Meaning |
|---|---|
| `node_heartbeat_schema_version` | layout version of the state file; a jump means the state was rebaselined |
| `node_heartbeat_gap_seconds` | seconds since the previous run; absent when there is no previous run to measure against |
| `node_heartbeat_last_event_class{class}` | class of the most recent gap, as a label with value 1 |
| `node_heartbeat_last_event_duration_seconds` | duration of that gap; `0` for a clock-step, whose real delta is negative |
| `node_heartbeat_last_event_timestamp_seconds` | when the most recent classified gap was detected |
| `node_heartbeat_events_total` | counter of every classified event (freeze, suspend, reboot, clock-step) |
| `node_freeze_events_total` | counter of gaps classified as a hard freeze, the count behind an intermittent hang |
| `node_heartbeat_suspend_events_total` | counter of gaps explained by a completed sleep |
| `node_heartbeat_events_by_class_total{class}` | per-class counters, one series per class seen |
| `node_heartbeat_rebases_total{reason}` | runs where the state was unusable and had to be rebased (`missing`, `malformed`, `absurd`) |
| `node_heartbeat_boot_id_info{boot_id}` | current kernel boot id as an info series; its change is the reboot signal |

The counters are carried in the state file, never derived by counting the event log, because a counter read from a log that retention trims would go down. A value the system does not know emits no metric at all rather than a zero.

## The GPU section

A discrete NVIDIA GPU normally does not appear in `node_hwmon_temp_celsius` at all. `nvidia-smi` is a separate interface to the driver, and it is the only source of GPU temperature, utilisation, VRAM, power draw, clocks and throttle reasons. When `HOST_HEARTBEAT_GPU_ENABLE` is `auto` and `nvidia-smi` is on `PATH`, the heartbeat queries it every run and writes `nvidia_gpu.prom`.

| Metric | Meaning |
|---|---|
| `node_gpu_present` | 1 if `nvidia-smi` is there at all |
| `node_gpu_query_success` | 1 if the last query succeeded, 0 if it timed out or failed |
| `node_gpu_query_duration_seconds` | how long the query took, useful as a leading indicator |
| `node_gpu_last_query_timestamp_seconds` | when the heartbeat last refreshed the file |
| `node_gpu_heartbeat_gap_seconds` | seconds since the previous run; kept under the historical `node_gpu_` name, but now measured by the generic heartbeat |
| `node_gpu_heartbeat_max_gap_seconds` | **latched** worst gap, latched only for gaps classified as a hard freeze |
| `node_gpu_heartbeat_max_gap_timestamp_seconds` | when that worst freeze gap happened, or 0 |
| `node_gpu_collectors_count` | number of GPUs reported by `nvidia-smi` |
| `node_gpu_temperature_celsius` | core temperature |
| `node_gpu_utilization_percent` | busy percentage |
| `node_gpu_memory_utilization_percent` | memory-controller busy percentage |
| `node_gpu_memory_used_bytes` / `node_gpu_memory_total_bytes` | in **bytes**, converted from the MiB `nvidia-smi` reports |
| `node_gpu_power_draw_watts` / `node_gpu_power_max_limit_watts` | draw and cap |
| `node_gpu_clocks_sm_mhz` / `node_gpu_clocks_mem_mhz` | core and memory clock |
| `node_gpu_pcie_link_gen_current` / `node_gpu_pcie_link_width_current` | negotiated PCIe link, for "is it running at x1 again" |
| `node_gpu_pstate_info{gpu,pstate}` | power state as a label (`P0`..`P8`) |
| `node_gpu_clocks_event_reasons_active{gpu}` | throttle bitmask |
| `node_gpu_throttle_reason_active{gpu,reason}` | one series per reason, 1 while asserted |

Deliberate omissions, each verified against a real driver:

- `power.limit` is not used. It returns `[N/A]` on some laptop drivers even when the limit is perfectly readable, so `power.max_limit` is used instead.
- `temperature.memory` is not used; most laptop drivers report `[N/A]`.
- `clocks_throttle_reasons.display_clock_setting` is not used; `nvidia-smi` rejects the **entire** query if one field is unknown, which is why the field lists here are short and tested rather than exhaustive.
- No `--collector.hwmon.chip-include` filter. It matches hardware IDs, not friendly names, so a filter that works on one machine silently matches nothing on the next. Use the max across sensors in the panel instead.
- A value the driver does not report produces **no metric at all**, not a zero. A rule can then never act on a value that was never measured.

The GPU fields come in two tiers: the full set above, and a reduced set (`index`, `temperature.gpu`, `utilization.gpu`, `memory.used`, `memory.total`, `power.draw`, `pstate`) that the script falls back to if the driver rejects any field of the full set. Throttle reasons need a second query because they come back as `Active`/`Not Active` strings; if that query fails the run keeps going and only the throttle detail is lost.

Success is judged by `nvidia-smi`'s **exit code** and by the first CSV field being a numeric GPU index, never by stdout being non-empty: some failures — `Failed to initialize NVML: Driver/library version mismatch` after a partially applied driver update, for instance — print to stdout, and a check based on non-empty stdout alone would report a broken driver as healthy.

## The GPU is not in the temperature panel

A discrete NVIDIA GPU normally does not appear in `node_hwmon_temp_celsius` at all. On a laptop with both an NVIDIA and an integrated AMD GPU, the hwmon chips that do appear belong to the rest of the platform: the AMD SoC, the AMD iGPU, the NVMe drive, the WiFi card and the PCI host bridges.

So a temperature panel that looks complete can still be telling you nothing about the GPU most likely to overheat. Two consequences:

- `--collector.hwmon.chip-include` is useless here. It filters on hardware IDs, and the NVIDIA's ID is not in that list to begin with.
- Any alert about a hot or throttling GPU has to be built on the heartbeat metrics above, never on `node_hwmon_*`.

### Sensor names in the panels

`node_hwmon_temp_celsius` labels come from the kernel, so they are not self-explanatory. On a typical AMD + NVIDIA laptop:

| Chip label | What it actually is |
|---|---|
| `k10temp` | the AMD SoC: CPU package plus uncore sensors |
| `amdgpu` | the integrated AMD GPU |
| `nvme` | the NVMe drive, one series per temperature sensor |
| `ath10k_hwmon` | the WiFi card |
| `pci0000:00_0000:00:18_3` | some other PCI device, named by bus address |

That last form is the one to be careful with: it is a PCI BDF address, not a product name, and different hardware puts different things there. It is not a GPU unless the address matches your GPU's `lspci` line. Identify one before trusting it:

```bash
lspci -s 00:18.3                    # what is this chip, really?
lspci -nn | grep -iE 'vga|3d|display'   # which GPUs exist at all?
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader
```

The `Temperature` panel in the Grafana dashboards hides the `pci0000:*` chips for exactly this reason: they are unidentified, on some machines they are the hottest reading on the panel, and showing an unlabelled BDF next to real sensor names invites reading it as something it is not.

### Hosts without an NVIDIA GPU

The heartbeat itself is installed everywhere now. Only the GPU section is conditional: with `HOST_HEARTBEAT_GPU_ENABLE=auto` a machine without `nvidia-smi` gets the full generic heartbeat and an honest `node_gpu_present 0`, with no dead entries in `systemctl list-timers` and no `MISSING GPU heartbeat` line in the installer output. That is the normal case for a server.

Set `HOST_HEARTBEAT_GPU_ENABLE=0` to suppress the query on a machine that does have the driver but not the intent, or `=1` to force it on. The old `GPU_HEARTBEAT_ENABLE` name is still read as a fallback for the GPU section; the new spelling is the documented one.

## Journal correlation

The heartbeat can also read the kernel ring buffer and the LACT daemon journal and count lines that match a known GPU-failure signature, writing `journal_events.prom`. This does **not** detect a freeze. By definition a hard lock usually wedges the kernel before anything is logged, so a present event is a correlation to line up against a heartbeat gap, never a cause.

| Source | Journal | Signature |
|---|---|---|
| `nvrm` | kernel (`journalctl -k`) | `NVRM:|nvAssert|fallen off the bus` |
| `drm` | kernel (`journalctl -k`) | `[*]ERROR[*]|GPU reset|ring .* timeout|VM_L2_PROTECTION_FAULT|amdgpu` |
| `lact` | `journalctl -u lactd.service` | `configuration reloaded|GPU list reloaded|reloading GPUs|kernel drm subsystem event|resume event detected|configuration applied` |
| `lact-error` | `journalctl -u lactd.service` | `could not apply|could not reapply|could not load GPU controllers|no GPUs were found|could not find GPU with id` |

| Metric | Meaning |
|---|---|
| `node_journal_enabled` | 1 when the host exports journal correlation, 0 when the section is off or `journalctl` is absent |
| `node_journal_scan_success` | 1 when both journal reads succeeded on the last run; 0 means an empty chart must not be read as "nothing happened" |
| `node_journal_last_scan_timestamp_seconds` | when the journal was last scanned |
| `node_journal_events_total{source}` | monotonic counter of matching lines per source, counted in a state file so pruning logs cannot make it decrease |
| `node_journal_last_event_timestamp_seconds{source}` | when the most recent matching line per source was logged, or 0 |
| `node_journal_event_recent{source}` | 1 while a matching line for this source was seen within the recent window |

The honest limits, stated rather than hidden:

- A hard freeze usually wedges the kernel before it can log anything, so a freeze with **no** journal event is common and expected. The journal is corroboration for the freezes that did manage to say something, not a detector.
- The journal has to be readable. `journalctl` must be present (the `auto` default skips the section otherwise), and if `/var/log/journal` does not exist the journal may be volatile and lose the lines across a reboot.
- Counters are per source and monotonic; the cursor never moves backwards, and a fresh install baselines the cursor at now rather than replaying history and inventing events no gap of ours can be matched to.

## The state files

The heartbeat writes several small files into the textfile directory. None of the state files carries a `.prom` extension, so the textfile collector ignores them: only the `.prom` files are scraped.

| File | Purpose |
|---|---|
| `host_heartbeat.prom` | the generic heartbeat metrics, replaced atomically every run |
| `host_heartbeat.state` | schema version, last epoch, boot id, uptime, per-class counters, last event and rebase counters |
| `host_heartbeat.events` | append-only classified gap history (`<epoch> <gap> <class> <boot-changed>`) |
| `nvidia_gpu.prom` | the GPU metrics, replaced atomically every run (historical name kept) |
| `nvidia_gpu.maxgap` | the latched worst freeze gap and when it happened, as `<epoch> <gap>` |
| `journal_events.prom` | the journal-correlation metrics |
| `host_heartbeat.journal.state` | journal counters and cursor, in its own file and schema |
| `.hb_suspend.marker` | the marker the systemd-sleep hook writes and the heartbeat consumes |

`nvidia_gpu.maxgap` ages out after `HOST_HEARTBEAT_MAX_GAP_TTL` (30 days by default) so a single freeze does not nag forever. Only a `freeze` ever reaches it: a suspend, a reboot or a clock step must never latch, which is the false positive the rewrite exists to remove. To clear a freeze after you have finished investigating, remove that file and restart the timer:

```bash
sudo rm -f /var/lib/node_exporter/textfile_collector/nvidia_gpu.maxgap
sudo systemctl restart host-heartbeat.timer
```

The event history is bounded on two axes: `HOST_HEARTBEAT_EVENT_RETENTION` (30 days) and `HOST_HEARTBEAT_EVENT_MAX` (5000 lines). Either bound alone leaves a hole — 30 days of a box that rebooted every 30 seconds is a quarter of a million lines — and pruning always keeps the newest events.

The latch is deliberately the same file and the same `<epoch> <gap>` format as the old NVIDIA-only heartbeat used, so an existing alert rule and any file kept as evidence keep working. When upgrading, the installer moves the old `nvidia-gpu-heartbeat` units and binary to `.bak`, supersedes `nvidia_gpu.lastrun`, and **keeps** `nvidia_gpu.maxgap` — but warns that the old script could classify an ordinary night of sleep as a freeze, so read it before trusting it.

## Troubleshooting

```bash
# is it scheduled at all? NEXT and LAST must not be "-"
systemctl list-timers host-heartbeat.timer

# what does it think happened?
systemctl status host-heartbeat.service
journalctl -u host-heartbeat.service -n 50 --no-pager
journalctl -t host-heartbeat --no-pager      # gap classifications only

# look at the files directly
cat /var/lib/node_exporter/textfile_collector/host_heartbeat.prom
cat /var/lib/node_exporter/textfile_collector/nvidia_gpu.maxgap
cat /var/lib/node_exporter/textfile_collector/host_heartbeat.events

# exercise every classification branch without freezing the machine:
./host-heartbeat.sh --self-test
```

A few things that look like bugs and are not:

- **`MISSING host heartbeat after 45s` at install time.** The timer has to schedule a first run, not just repeat one. A timer with only `OnUnitActiveSec` and no `OnActiveSec` schedules nothing on a fresh boot; check `systemctl list-timers host-heartbeat.timer` and `systemctl cat host-heartbeat.timer`.
- **`MISSING sleep hook`.** Without `/usr/lib/systemd/system-sleep/host-heartbeat-sleep`, every suspend is reported as a freeze. Re-run the installer; the heartbeat is installed with the hook.
- **`GpuQueryFailed` firing while everything looks fine.** The heartbeat is stricter than an interactive `nvidia-smi`: it wraps the query in `timeout`, so it reports a GPU that is slow to answer as a failure. Check `node_gpu_query_duration_seconds` before believing it.
- **The journal panel is empty.** Distinguish "this host never logs GPU errors" from "the section is off": `node_journal_enabled 0` means off or no `journalctl`, and `node_journal_scan_success 0` means the journal could not be read this run.
- **A freeze shows no journal event.** Expected. A hard lock usually wedges the kernel before it logs; see [Journal correlation](#journal-correlation).
- **No `node_hwmon_*` for the NVIDIA chip.** Expected — see [The GPU is not in the temperature panel](#the-gpu-is-not-in-the-temperature-panel).

## Uninstall

```bash
sudo systemctl disable --now host-heartbeat.timer
sudo rm -f /etc/systemd/system/host-heartbeat.service \
           /etc/systemd/system/host-heartbeat.timer \
           /usr/local/bin/host-heartbeat \
           /usr/lib/systemd/system-sleep/host-heartbeat-sleep \
           /etc/default/host-heartbeat
sudo rm -rf /etc/systemd/system/host-heartbeat.timer.d \
            /etc/systemd/system/host-heartbeat.service.d
sudo systemctl daemon-reload
```

Setting `HOST_HEARTBEAT_ENABLE=0` and re-running the installer does the same: it disables the timer and removes the service, binary and sleep hook, leaving the state directory in place. The heartbeat's files are ordinary files in the `node_exporter` textfile directory, so removing them is safe once nothing else reads them. The generic exporter itself is removed in [README.md](README.md#uninstall), and the peer watchdog in [peer-watchdog.md](peer-watchdog.md).
