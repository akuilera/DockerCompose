# Monitoring — Prometheus + Alertmanager + Node Exporter

Infrastructure monitoring stack: Prometheus scrapes Node Exporter on the server and on remote devices, keeps up to 90 days of history, and Alertmanager is running but has no notification receiver wired up yet. Grafana reads Prometheus over the shared `monitoring-net` network.

Every monitored machine — the server included — runs `node_exporter` natively as a systemd service, installed with the [same script](../node-exporter/install-node-exporter.sh). There is deliberately no `node_exporter` container in this stack; see [Why node_exporter is not a container here](#why-node_exporter-is-not-a-container-here).

## Multi-device, one dashboard template

The stack is designed for any number of devices, and **the server is just another device**: there is no special `server`/`client` role. Each device contributes one entry to the shared registry `Devices/`, and every dashboard row is decided per device by flags in that entry — so a machine without a battery or GPU does not get empty panels.

The device registry has two halves:

- **The repository copy** (`Devices.example/` in this repository) is the generic, committed template: a `README.md` and an `example/.env.example`. It documents the schema and carries no real data. It is the thing you copy from.
- **The live registry** lives on the server, inside the repository clone, at `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/<device>/.env` — the whole `Devices/` folder is gitignored, never committed. Each `<device>` directory is one monitored machine.

A device entry looks like:

```env
DEVICE_NAME="Lenovo Thinkpad"      # title shown in Grafana, and the host label
DEVICE_ADDR=<ip>:9100              # where Prometheus scrapes node_exporter
DEVICE_BATTERY=1                   # dashboard includes the Battery row only when set
DEVICE_GPU=0                       # dashboard includes the NVIDIA row only when set
```

`DEVICE_NAME` becomes the `host` label on that target and the title of that device's dashboard in Grafana. Because it is embedded in a JSON dashboard, the bootstrap only accepts names matching `[A-Za-z0-9 ._-]` and aborts loudly otherwise.

`DEVICE_BATTERY` and `DEVICE_GPU` control *which rows the dashboard renders*, not how the metrics are collected. Collectors are always the native node_exporter ones plus the optional NVIDIA heartbeat on that host; see [Battery and GPU monitoring](#battery-and-gpu-monitoring).

## Layout

All configuration, templates and data live on the server: writable state under `${PATH_TO_CONTAINERS}`, and what the stack only reads (the Grafana scripts and the `Devices/` registry) under `${PATH_TO_COMPOSE}`, the repository clone — the one absolute path Portainer CE can bind, since `./...` from its git clone resolves to an empty directory:

```
${PATH_TO_CONTAINERS}/Monitoring/
├── Prometheus/
│   ├── prometheus/
│   │   ├── tmpl/      → /tmpl (templates; only regenerated when missing)
│   │   ├── config/    → /etc/prometheus:ro (the config Prometheus actually reads)
│   │   └── data/      → /prometheus (TSDB, owner 65534)
│   └── alertmanager/
│       ├── tmpl/      → /tmpl-alertmanager (template)
│       ├── config/    → /etc/alertmanager:ro (the config Alertmanager actually reads)
│       └── data/      → /data (owner 65534)

${PATH_TO_COMPOSE}/Automatization/
└── Monitoring/
    └── Devices/
        └── <device>/.env            → /devices/<device>/.env (per-device registry)
```

- A one-shot `bootstrap` service (busybox) creates those directories on first start, seeds the default config only when missing (`cp -n`, never overwrites your edits), regenerates `nodes.yml` from the `Devices/` registry and runs `chown -R 65534:65534` on the `data/` directories, so there are **no manual steps** (no `mkdir`, no `chown`, no helper scripts).

> **The clone on the server.** Because the registry is bind-mounted from `${PATH_TO_COMPOSE}`, the server must keep a read-mostly clone of this repository (unlike the usual "never clone by hand" rule); update it with `git -C "${PATH_TO_COMPOSE}" pull`. Never run `git clean -fdx` or `git push -f` inside it — the live device `.env` files are untracked by design and live there.

- Prometheus and Alertmanager run as `nobody` (UID 65534).
- One full bind per service, always onto paths that already exist in the image (`/etc/prometheus`, `/etc/alertmanager`): this avoids the `EROFS` failure you get from nested bind mounts.

## Deployment (Portainer → Stack from Git)

1. Folder: `Automatization/Monitoring/Prometheus`.
2. Ensure the repository clone exists on the server (`${PATH_TO_COMPOSE}`) and create the live registry in it: `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/<device>/.env` for each machine, copying the schema from the repository's [`Devices.example/`](../Devices.example/).
3. Stack environment variables:
   - `PATH_TO_CONTAINERS` — the data root (the same one you use in your other stacks).
   - `PATH_TO_COMPOSE` — the absolute path of the repository clone (the `Devices/` registry is read from it).
4. **Deploy**. Update after every `git push`; adding or removing a device means adding/removing a `.env` file under `Devices/` in the clone and hitting Update.

`PATH_TO_SECRETS` is **not** used by this stack. It only appears in this folder's `.env.example` as a leftover from the shared convention; the stack that needs it is Grafana, for its database secrets.

The `bootstrap` container ends in *Exited (0)*; `prometheus` and `alertmanager` stay running (external network `monitoring-net`, no published ports).

## How `nodes.yml` is generated

`prometheus/config/targets/nodes.yml` is a `file_sd` target list that the bootstrap **regenerates on every stack start** from the `Devices/` registry in the clone. It is therefore never edited by hand: edit the per-device `.env` files and Update the stack.

The generator walks every `Devices/<device>/.env` inside the mounted registry and emits one target using `DEVICE_ADDR` and the `DEVICE_NAME` as the `host` label:

```yaml
- targets: ['<ip>:9100']
  labels:
    job: 'node'
    host: 'Lenovo Thinkpad'
```

After writing the file the bootstrap runs a **structural guard**: it checks that the number of `job:`/`host:` label blocks equals the number of items and that each block is complete, and it exits non-zero (failing the stack) if the file is malformed or if there are no devices at all. The guard is deliberately cheap and dependency-free, so it only validates that structure — it is not a full YAML parse. It exists because a malformed file used to fail *silently from the user's point of view*: Prometheus dropped the entire `node` job and every dashboard went to `No data` while the stack still looked healthy.

A missing or empty `Devices/` registry makes the bootstrap exit with a message pointing at the repository template (`Devices.example/`) — an empty registry would otherwise look healthy while scraping nothing.

## Adding a device

1. Install `node_exporter` natively on the device (including on the server itself) with [`../node-exporter/install-node-exporter.sh`](../node-exporter/README.md).
2. In the server clone, create `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/<name>/.env` from the repository template: `DEVICE_NAME`, `DEVICE_ADDR=<device-address>:9100`, and the battery/GPU flags for that hardware.
3. Update the stack in Portainer.

Removing a device is deleting its `.env` and updating. Renames are just changing `DEVICE_NAME`; the generated dashboards on the other side of the stack are rebuilt on Update.

## Battery and GPU monitoring

**Battery.** `node_exporter` already abstracts batteries through its native `powersupplyclass` collector reading `/sys/class/power_supply/*`, so no per-device command or textfile script is needed — the same `node_power_supply_*` metrics appear on any machine that has a battery. The only thing per-device is `DEVICE_BATTERY`, which decides whether the dashboard's Battery row is rendered. The alerts are `BatteryLow` (`capacity < 20` for 5m) and `BatteryHealthDegraded` (`energy_full / energy_full_design < 0.70` — it fires only when the retained capacity gets worse, not at today's normal wear level).

**GPU.** A discrete NVIDIA GPU has no hwmon, so its temperature, VRAM, power and clocks cannot come from `node_exporter`. They come from the [GPU heartbeat](../node-exporter/README.md), installed automatically on the host. `DEVICE_GPU` only tells the dashboard to render the NVIDIA row. If the row is empty, the heartbeat timer is not running; see [the timer trap](../node-exporter/README.md#why-this-is-not-just-download-node_exporter).

## Why node_exporter is not a container here

This stack used to run the server's `node_exporter` as a container with the host filesystem bind-mounted at `/host`. It reported CPU, memory, filesystem usage and systemd unit state correctly, and it reported **exactly one network interface**, the container's own `eth0`, while the host had several real ones. The mount was not the problem:

- `ls /host/sys/class/net` inside the container listed every host interface.
- The collector still returned one.

That contradiction is the whole story. `/proc/net/dev` is not a file owned by a mount; it is generated per **network namespace**, by whichever process reads it. A container lives in its own network namespace, so reading the host's `/proc` from inside it returns the *container's* interface table. Mounting the host's `/sys` and `/proc` changes nothing, and the two commands above disagree permanently.

The only ways out are `network_mode: host` or running the exporter on the host. Host networking would have worked, but a container that needs to see the host is normally given that visibility as a `-v /:/host` bind, which grants **read access to the whole host filesystem**, and host networking publishes port 9100 on every interface rather than one. Running natively avoids both, and gets the values that actually matter: real interfaces, real sensor chips, real block devices.

The trade is one extra install step and a device entry pointing at each host's real address rather than at a container name.

## Firewalls, and why "my firewall is off" is not evidence

A target can be down for reasons that no local firewall check will reveal. If `firewalld`, `ufw` and `nftables` all report inactive and the target is still down, look for an **application firewall or network monitor** before touching the router. Portmaster is the common one: it runs as a root service, filters through `nfqueue`, blocks incoming connections by default, and leaves every conventional firewall service reading `inactive` while it does it.

The test is behavioural, not a status check: stop the suspect and see whether the target comes up. If it does, the filter is per-process and the fix belongs to the `node_exporter` profile in that tool, not to a global inbound rule. The full procedure, including why disabling "block incoming connections" globally is the wrong fix, is in [the helper's firewall section](../node-exporter/README.md#firewalls-what-the-installer-can-and-cannot-tell-you).

## Retention and storage

Two independent limits are set on the Prometheus service: `retention.time=90d` and `retention.size=20GB`. **Prometheus enforces both and deletes whichever runs out first**, so the size cap is usually the one that decides how much history you actually keep. At the 15s scrape interval, 90 days is about 518k samples per series, and 20GB is roughly 10k–14k series worth of that. `node_exporter` with the `systemd` and `hwmon` collectors is the usual way to blow past that, because every systemd unit contributes several series.

Check the real number before adding targets — Prometheus web UI, **Status → TSDB**, or:

```bash
curl -s http://<prometheus-host>:9090/api/v1/query \
  --data-urlencode 'query=numSeries(prometheus_tsdb_head_series)' -G
```

If that approaches the ceiling, raise `retention.size` in `docker-compose.yml` and Update the stack. A silently shortened history is worse than a known limit, because the oldest data is exactly what you want when investigating something that happened weeks ago. Note that raising the cap does not reclaim anything, it only allows the directory to grow — make sure the host has room for it before raising it.

## Editing the config without redeploying

Edit the files directly under `.../{prometheus,alertmanager}/config/` on the server and reload the process:

```bash
docker kill -s HUP prometheus
docker kill -s HUP alertmanager
```

The bootstrap seeds with `cp -n`, so it never overwrites what you edited. There is no `sync-config.sh` any more; the bootstrap does the seeding on every Update.

## Alerting status

The bootstrap seeds a **real** rule set, the same 18 rules as `prometheus/rules/alerts.yml` in this repository, so they are active after an Update. The two must be kept in sync: the bootstrap seeds `{tmpl,config}/rules/alerts.yml` only when those files are missing or empty, so if you edit the rules on the server directly, the next Update will not overwrite them — which is convenient, but also means the repo copy silently goes stale.

The rules that matter for a machine that freezes hard are `HostDownBrief` (3 min, warning), `HostDown` (5 min, critical) and `HostRebooted`, plus the `GpuFreezeDetected` latch from the [node_exporter helper](../node-exporter/README.md) on NVIDIA clients. The last one is the only one that records how long the machine was actually dead: during a freeze the box is by definition not answering, so nothing can report the outage while it happens.

Alertmanager's default receiver still has **no destination**, so nothing is delivered anywhere. The rules evaluate and show up in Prometheus and Grafana; wiring Telegram is a separate, deliberate step.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Every panel shows `No data` but the stack looks healthy | The `node` job was dropped, so only Prometheus scraping itself survived | Check the bootstrap log for `nodes.yml OK: N target(s)`, then confirm the target list has no file-read errors and that `job="node"` returns targets |
| Bootstrap exits non-zero | Its guard rejected the generated `nodes.yml`, or the registry is empty | `docker logs bootstrap`; the cause is almost always a missing/empty `Devices/` registry or a malformed device entry |
| A device target is `down` | `node_exporter` not installed there, or something blocks `9100/tcp` | Install it on the device, confirm `DEVICE_ADDR` in its device entry, then work through the firewall section above |
| A target is `down` and every firewall service reads `inactive` | An application firewall is filtering per process, not per port | Stop the suspect and see whether the target recovers; see [Firewalls](#firewalls-and-why-my-firewall-is-off-is-not-evidence) |
| Only one network interface appears on the server | `node_exporter` is containerised, so it is reading its own netns | Install it natively with the helper script; see [Why node_exporter is not a container here](#why-node_exporter-is-not-a-container-here) |
| The GPU row is empty but other panels have data | The GPU heartbeat timer is not firing | `systemctl list-timers nvidia-gpu-heartbeat.timer` must show a `NEXT`; see the helper README |
| A target is `up` but its dashboard is empty | The target has no `host` label | Make sure its device entry has `DEVICE_NAME` set, and Update |
| A panel is empty while its legend shows values | The series exists and is flat at zero — usually an idle machine, not a bug | Confirm with `rate(node_disk_read_bytes_total{host="<name>"}[5m])`; if it returns no series at all, check `node_scrape_collector_success` for that collector |
| Edited `nodes.yml` by hand and "nothing changed" | It is regenerated from `Devices/` on every Update | Edit the device `.env` file, not the file |
| `prometheus`/`alertmanager` stuck restarting | Config missing or `data/` permissions | Update the stack again (the bootstrap creates and chowns); then `docker logs prometheus --tail 30` |
| `network monitoring-net not found` | The external network does not exist yet | Create it once: `docker network create monitoring-net` |

### Historical bug: `No data` on every device (fixed)

The compose file had drifted into a broken state: the `prometheus`, `alertmanager` and `node-exporter` services were gone along with their volumes, environment and network, and the `nodes.yml` generator produced a malformed file as soon as the target list held more than one entry (it emitted a trailing separator and mis-escaped `$` as `$$$$` through Compose interpolation). Prometheus logged an error reading the file_sd list and dropped the whole `node` job, which left exactly one target — Prometheus scraping itself — so dashboards showed `No data` while every container still reported `Up`.

The fix restored all four services with their six data volumes, the shared external network and the bootstrap's environment; rewrote the generator to emit one correctly escaped target per entry with a default target and correct `$` escaping; added the structural guard described above; and dropped an unused collector flag that was noisy on hosts without a running systemd DBus. It was verified in three passes: static checks on the compose file, an offline emulation of the bootstrap against one, two and three targets (including a regression case built from the old malformed file), and a post-deploy check against the live stack.

## Security

- This is a public repository: **never** commit real hostnames or addresses here. Device entries live only in `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/` in the server clone. The repository's [`Devices.example/`](../Devices.example/) folder is a template (`example/.env.example` placeholders only), and `prometheus/targets/nodes.yml.example` is a reference copy.
- Prometheus and Alertmanager publish **no ports** (internal `monitoring-net` only); local diagnostic access goes through the API inside the cluster (`docker exec ... localhost:9090`).
- Nothing in this stack bind-mounts the host filesystem. That is the main reason `node_exporter` is a native service and not a container: the container route to host visibility is a `-v /:/host` bind, which hands a service read access to the entire host.
- The only port this stack causes to be opened is `9100/tcp` on the monitored machines, by their own installer. It is a read-only metrics endpoint. Restrict it at the client — bind to the interface Prometheus reaches the host on, and allow it in whatever filters the host, rather than leaving it open on every interface.

More detail and the step-by-step deployment runbook live in the local working document referenced from the Grafana folder.