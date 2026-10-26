# Peer watchdog

Part of the [node_exporter helper](README.md), but installed separately with `install-peer-watchdog.sh`. It runs on one always-on machine — the one that already runs the monitoring stack — and probes the other machines so it can record their downtime from the outside, with its own clock and its own disk.

## Why it exists

Prometheus already scrapes every machine's native `node_exporter` on port 9100, so "the peer is down" is, in principle, already covered. It is not enough for the case this was written for: a laptop that intermittently becomes completely unresponsive, where recovery takes hours and sometimes the machine has to be force-powered-off.

A frozen machine cannot report anything, so the only thing Prometheus ever learns is `up == 0`, and it learns it only after the scrape's `for:` window. That is fine for detection and useless for timing: Prometheus cannot know when the outage truly began or truly ended, to the second. Worse, a machine that hard-resets looks identical in a time series to a machine that was cleanly rebooted, so the distinction that matters most when debugging an intermittent hang is exactly the distinction a scrape throws away.

So this is a second, **independent witness**. Two records of the same event, written by two machines that did not share a failure, are worth more than either one. If the target's own on-disk heartbeat latch (see [host-heartbeat.md](host-heartbeat.md)) and this history disagree about when a freeze began, that disagreement is itself a finding: a network partition, a clock problem, or a hang that also took the network stack down all look different on the two sides, and the diff says which.

**What it cannot do.** It cannot repair a wedged machine, and no amount of cleverness will. If the peer is truly frozen there is no shell to SSH into, no agent on it to execute anything, and no remote channel that is not itself going through the same dead kernel. What this buys is an accurate, independent, second-resolution timeline that survives for the retention period, plus an alert path that still fires because the notification happens on the healthy machine. It is a witness and a fire alarm, not a fire brigade. The main value is the history: an intermittent hang is exactly the thing that is never caught in the act, and durable per-window records make the pattern visible after the fact.

**No new container and no new port.** The observing machine already runs `node_exporter`, and its textfile collector already reads one directory. This writes its metrics into that directory and stops, so Prometheus picks them up through the scrape that is already happening and the metrics inherit the same `job`, `instance` and `host` labels as everything else on that machine. A dedicated exporter for peer state would be one more container to keep alive on the one machine that must never be the thing that breaks.

## What it probes

For each configured peer it requests `http://<host>:<port>/metrics` with `curl`. A peer counts as up only if **both** conditions hold: the transfer succeeded, and the body looks like a Prometheus exporter — at least one `# HELP`/`# TYPE` comment **and** at least one well-formed sample line with a numeric value.

Requiring an HTTP 200 alone is the tempting wrong approach, because a router answering on the port, a captive portal, a reverse proxy returning an HTML error page, or a different service bound to 9100 after a config change all answer instantly with a 200 or a 404. Each of those would be recorded as "the laptop was fine", corrupting the very timeline the script exists to keep. The sample-line check is what rejects an HTML error page that merely contains the word `HELP`, and an empty 200 from a service that accepted the connection and had nothing to say.

Each probe is wrapped in `--max-time` and `--connect-timeout` equal to `PEER_WATCHDOG_TIMEOUT`, so a peer that accepts the TCP connection and then stops sending costs exactly that many seconds and no more. Probes run through a concurrency pool rather than one at a time, so a run where every peer is down still finishes inside the interval instead of stacking on the next tick.

## Settings

All settings live in `peer-watchdog.env` (or the shared `.env`) next to `install-peer-watchdog.sh`; see [peer-watchdog.env.example](peer-watchdog.env.example). Every setting is optional and has a default that works on a stock systemd Linux next to an existing `node_exporter`.

| Variable | Default | Meaning |
|---|---|---|
| `PEER_WATCHDOG_INTERVAL` | `60s` | timer interval; must be meaningfully longer than the probe timeout |
| `PEER_WATCHDOG_TIMEOUT` | `5` | per-probe wall-clock cap in seconds |
| `PEER_WATCHDOG_CONCURRENCY` | `8` | how many peers may be probed at once; worst case is `ceil(peers/concurrency) * timeout` |
| `PEER_WATCHDOG_CONFIG` | `/etc/peer-watchdog/peers.conf` | the peer list; kept outside the repository because it holds the fleet's addresses |
| `PEER_WATCHDOG_STATE_DIR` | `/var/lib/peer-watchdog` | per-peer state and the append-only down-window history |
| `PEER_WATCHDOG_TEXTFILE_DIR` | node_exporter textfile dir | where `peer_watchdog.prom` is written; must be the directory the local exporter reads |
| `PEER_WATCHDOG_HISTORY_RETENTION` | `2592000` | how long completed down windows are kept; 30 days |
| `PEER_WATCHDOG_HISTORY_MAX_LINES` | `5000` | line cap on each history file |
| `PEER_WATCHDOG_USER` | `node_exporter` | account the service runs as; must own the textfile directory |
| `PEER_WATCHDOG_GROUP` | `node_exporter` | group the service runs as |
| `PEER_WATCHDOG_INSTALL_DIR` | `/usr/local/bin` | where the script is installed |
| `PEER_WATCHDOG_UNIT_DIR` | `/etc/systemd/system` | where the units are installed |
| `PEER_WATCHDOG_WAIT` | `90` | how long the installer waits for the first metrics file |
| `PEER_WATCHDOG_SEED_CONFIG` | `1` | create a placeholder `peers.conf` when none exists |
| `PEER_WATCHDOG_LOCAL_LISTEN` | `:9100` | local exporter address used only for the installer's verification scrape |

The service runs as `node_exporter`, never root: everything it writes is the textfile directory and its own state directory, and a script that makes outbound HTTP requests to whatever is on the network should not be root on the machine that has to keep working.

## The peer list

`peers.conf` holds one peer per line, `name=host:port`. Only reachable hosts belong in it: the watchdog records a down window for every peer that does not answer, so a peer it cannot reach becomes a permanent outage record that pollutes the history forever.

```
# <peer-name>=<host>:<port>
```

The name becomes a metric label, so keep it short, stable and free of spaces; it is the join key against the rest of the monitoring stack, and renaming it orphans that peer's history (the old windows stay on disk under the old name, and the new name starts from zero). Names are sanitised before being used as a file name, so two names that differ only by punctuation can collide; the parser rejects a duplicate name and any name whose sanitised form is already taken, because two machines silently sharing one state file would cross-contaminate their timelines. A line with no port is ignored rather than defaulted, because defaulting would probe port 80 and report a bogus outage.

The installer seeds the file with placeholder comments only, and only when it does not already exist. The addresses are yours to fill in locally and never belong in a tracked file.

## Install

```bash
sudo ./install-peer-watchdog.sh
```

The installer creates the `node_exporter` account if the exporter installer has not run yet, creates the state and textfile directories owned by that account, seeds `peers.conf` with placeholders, installs the script and both units (with an interval drop-in written for both `OnActiveSec` and `OnUnitActiveSec`, since either alone schedules nothing on a fresh boot), starts the timer, and then verifies two separate things: that `peer_watchdog.prom` is being written, and that the local exporter is actually serving `node_watchdog_last_run_timestamp_seconds`. It fails the two checks separately on purpose, because they fail for unrelated reasons and you need to know which one broke — the file existing means the script ran, the metric appearing on `/metrics` means the exporter is reading that file.

## What it exposes

Written to `peer_watchdog.prom` and served by the local `node_exporter`.

| Metric | Meaning |
|---|---|
| `node_watchdog_last_run_timestamp_seconds` | when the last run completed; a value that stops advancing is a dead watchdog |
| `node_watchdog_run_duration_seconds` | wall-clock seconds the last run took, including waiting for the slowest peer |
| `node_watchdog_peers_configured` | peers read from the config on the last run; 0 means the config is missing or empty, not that everything is up |
| `node_watchdog_peers_up` | configured peers that answered with something that looks like an exporter |
| `node_watchdog_peer_up{peer,target}` | 1 if that peer answered with an exporter-like body last probe |
| `node_watchdog_peer_probe_duration_seconds{peer,target}` | how long the last probe took, a leading indicator for a peer about to stop |
| `node_watchdog_peer_down_since_timestamp_seconds{peer,target}` | when the current down window began, or 0 when there is none |
| `node_watchdog_peer_last_success_timestamp_seconds{peer,target}` | when the peer last answered, or 0 if it never has |
| `node_watchdog_peer_down_windows_total{peer,target}` | monotonic count of completed down windows |
| `node_watchdog_peer_last_down_duration_seconds{peer,target}` | duration of the most recently completed down window, or 0 |
| `node_watchdog_peer_down_seconds{peer,target}` | seconds since the current down window began; present only while the peer is down |
| `node_watchdog_peer_total_down_seconds{peer,target}` | total seconds down over the retained history plus the open window; a gauge, because it falls when old entries age out |

`node_watchdog_peer_down_seconds` is emitted only while a peer is down. Emitting `0` while up would be a fabricated value: the honest reading while up is "there is no down window", and a rule that alerts on it handles the series being absent, which `node_watchdog_peer_up == 0` already tells it.

## State and history

Everything lives under `PEER_WATCHDOG_STATE_DIR`:

| File | Purpose |
|---|---|
| `<peer>.state` | per-peer state, replaced atomically: `up`, `down_since`, `last_ok`, `events`, `last_duration` |
| `<peer>.history` | append-only history, one line per **completed** down window: `<end_epoch> <start_epoch> <duration> <start_iso8601> <end_iso8601>` |
| `lastrun` | epoch of the last completed run |
| `work.*` | per-run scratch directory for probe results, removed on exit |

A down window opens **once**. The start time is not refreshed on subsequent failures: a peer that is down for an hour and fails every check is one outage of an hour, not 24 outages of 150 seconds, and re-stamping on every miss would destroy the timeline. The window closes on the first successful probe, and the duration is computed from values actually observed — the start from the run that first failed, the end from now — never from an estimate.

The history is bounded on two axes: `PEER_WATCHDOG_HISTORY_RETENTION` (30 days) and `PEER_WATCHDOG_HISTORY_MAX_LINES` (5000 lines). Either bound alone has a failure mode — retention alone lets a flapping peer grow a file that is expensive to rewrite every run, and a line count alone silently discards the history the moment the count is reached — and pruning always keeps the newest entries. Because a bounded window can shrink, `node_watchdog_peer_total_down_seconds` is a gauge, not a counter.

`<peer>.state` is replaced with a rename within the same directory, so a reader after a power cut sees either the previous state or the new one, never a half-written mixture. A corrupt state file that says "down" with no start time is treated as up, so the next real failure opens a fresh window instead of fabricating a zero-length one. The last run is stamped as soon as the run finishes, so a run that dies mid-way does not look like a hung watchdog on the next tick.

## Verification

```bash
systemctl list-timers peer-watchdog.timer           # NEXT and LAST must not be "-"
systemctl status peer-watchdog.service
journalctl -u peer-watchdog.service -n 30 --no-pager   # one line per window opened/closed

# the metrics file and the exporter's view of it
cat /var/lib/node_exporter/textfile_collector/peer_watchdog.prom
curl -s http://127.0.0.1:9100/metrics | grep '^node_watchdog_peer_up'
```

Run it by hand — which shows the failure without the unit in the way — and check it can write both directories:

```bash
sudo -u node_exporter /usr/local/bin/peer-watchdog
sudo -u node_exporter test -w /var/lib/peer-watchdog \
  -a -w /var/lib/node_exporter/textfile_collector && echo writable
```

## Troubleshooting

- **`peer_watchdog.prom` is never written.** The timer has to schedule a first run. Confirm `systemctl list-timers peer-watchdog.timer` shows a `NEXT`/`LAST`, then run the script by hand as above and read its stderr.
- **The file exists but the metric is not on `/metrics`.** That is the exporter, not the watchdog: check that `PEER_WATCHDOG_TEXTFILE_DIR` matches `--collector.textfile.directory` in `node-exporter.service`, and that `node_scrape_collector_success{collector="textfile"} == 1`.
- **A peer shows down but you can reach it.** Peer reachability is not something a local script can verify. The usual causes are an application firewall on the **peer** that filters per process (Portmaster and similar, so every conventional service reads `inactive`), a packet filter on **this** host with the peer's port closed, or an upstream router, hypervisor security group or Wi-Fi power saving between the two. Probe by hand from this machine with the same timeout:

  ```bash
  curl -s --max-time 5 http://<host>:<port>/metrics | head -3
  ```

  An exporter prints `# HELP` and metric lines; an HTML page, a router login form or an empty answer means something that is not an exporter answered the port, which is recorded as down on purpose.
- **A peer you cannot reach stays down forever.** Remove it from `peers.conf`. Only reachable hosts belong there.
- **The run duration is close to the interval.** Lower the peer count per run by raising `PEER_WATCHDOG_CONCURRENCY`, rather than raising `PEER_WATCHDOG_TIMEOUT`: a timeout longer than the interval means a run can still be in flight when the next tick arrives.

## Uninstall

```bash
sudo systemctl disable --now peer-watchdog.timer
sudo rm -f /etc/systemd/system/peer-watchdog.service \
           /etc/systemd/system/peer-watchdog.timer \
           /usr/local/bin/peer-watchdog
sudo rm -rf /etc/systemd/system/peer-watchdog.timer.d \
            /etc/systemd/system/peer-watchdog.service.d
sudo systemctl daemon-reload
```

The state directory and `peers.conf` are left in place on purpose: they hold the history. The metrics disappear on their own once `peer_watchdog.prom` is removed from the textfile directory. The generic exporter is removed in [README.md](README.md#uninstall), and the heartbeat in [host-heartbeat.md](host-heartbeat.md#uninstall).
