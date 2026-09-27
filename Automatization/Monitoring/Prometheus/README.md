# Monitoring — Prometheus + Alertmanager + Node Exporter

Infrastructure monitoring stack: Prometheus scrapes Node Exporter on the server and on remote devices, keeps up to 90 days of history, and Alertmanager is running but has no notification receiver wired up yet. Grafana reads Prometheus over the shared `monitoring-net` network.

## Layout

All configuration, templates and data live on the server under `${PATH_TO_CONTAINERS}`. The repository contributes only the compose file and the reference templates; nothing is read from the clone at runtime:

```
${PATH_TO_CONTAINERS}/Monitoring/Prometheus/
├── prometheus/
│   ├── tmpl/      → /tmpl (templates; only regenerated when missing)
│   ├── config/    → /etc/prometheus:ro (the config Prometheus actually reads)
│   └── data/      → /prometheus (TSDB, owner 65534)
└── alertmanager/
    ├── tmpl/      → /tmpl-alertmanager (template)
    ├── config/    → /etc/alertmanager:ro (the config Alertmanager actually reads)
    └── data/      → /data (owner 65534)
```

- A one-shot `bootstrap` service (busybox) creates those directories on first start, seeds the default config only when missing (`cp -n`, never overwrites your edits), regenerates `nodes.yml` from the `NODE_TARGETS` environment variable and runs `chown -R 65534:65534` on the `data/` directories, so there are **no manual steps** (no `mkdir`, no `chown`, no helper scripts).
- Prometheus and Alertmanager run as `nobody` (UID 65534).
- One full bind per service, always onto paths that already exist in the image (`/etc/prometheus`, `/etc/alertmanager`): this avoids the `EROFS` failure you get from nested bind mounts.

## Deployment (Portainer → Stack from Git)

1. Folder: `Automatization/Monitoring/Prometheus`.
2. Stack environment variables:
   - `PATH_TO_CONTAINERS` — the data root (the same one you use in your other stacks).
   - `NODE_TARGETS` — the hosts to scrape, as comma-separated `name=host:port` pairs. The `name=` prefix is what makes the bootstrap attach the label `host: <name>` to that target, and that label is what the dashboards filter on (`$host`). Default: `server=node-exporter:9100`.
3. **Deploy**. Update after every `git push`; adding or removing a device means editing `NODE_TARGETS` and hitting Update.

`PATH_TO_SECRETS` is **not** used by this stack. It only appears in this folder's `.env.example` as a leftover from the shared convention; the stack that needs it is Grafana, for its database secrets.

The `bootstrap` container ends in *Exited (0)*; `prometheus`, `alertmanager` and `node-exporter` stay running (external network `monitoring-net`, no published ports).

## How `nodes.yml` is generated

`prometheus/config/targets/nodes.yml` is a `file_sd` target list that the bootstrap **regenerates on every stack start** from `NODE_TARGETS`. It is therefore never edited by hand: change the variable and Update the stack.

The generator emits one entry per `name=host:port` pair:

```yaml
- targets: ['server:9100']
  labels:
    job: 'node'
    host: 'server'
- targets: ['<client-1-host>:9100']
  labels:
    job: 'node'
    host: 'client-1'
```

After writing the file the bootstrap runs a **structural guard**: it checks that the number of `job:`/`host:` label blocks equals the number of items and that each block is complete, and it exits non-zero (failing the stack) if the file is malformed. The guard is deliberately cheap and dependency-free, so it only validates that structure — it is not a full YAML parse. It exists because a malformed file used to fail *silently from the user's point of view*: Prometheus dropped the entire `node` job and every dashboard went to `No data` while the stack still looked healthy.

A target given **without** the `name=` prefix still scrapes fine but arrives with no `host` label, and the dashboards will show `No data` for it. Always use the prefix.

## Adding a device

1. Install native `node_exporter` on the device (see the deployment guide referenced at the bottom).
2. Add its address **with the `name=` prefix** (`server=node-exporter:9100`, `client-1=<client-1-host>:9100`) to the stack's `NODE_TARGETS` in Portainer, then Update.

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

The bootstrap seeds a **real** rule set, the same 17 rules as `prometheus/rules/alerts.yml` in this repository, so they are active after an Update. The two must be kept in sync: the bootstrap seeds `{tmpl,config}/rules/alerts.yml` only when those files are missing or empty, so if you edit the rules on the server directly, the next Update will not overwrite them — which is convenient, but also means the repo copy silently goes stale.

The rules that matter for a machine that freezes hard are `HostDownBrief` (3 min, warning), `HostDown` (5 min, critical) and `HostRebooted`, plus the `GpuFreezeDetected` latch from the [node_exporter helper](../node-exporter/README.md) on NVIDIA clients. The last one is the only one that records how long the machine was actually dead: during a freeze the box is by definition not answering, so nothing can report the outage while it happens.

Alertmanager's default receiver still has **no destination**, so nothing is delivered anywhere. The rules evaluate and show up in Prometheus and Grafana; wiring Telegram is a separate, deliberate step.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Every panel shows `No data` but the stack looks healthy | The `node` job was dropped, so only Prometheus scraping itself survived | Check the bootstrap log for `nodes.yml OK: N target(s)`, then confirm the target list has no file-read errors and that `job="node"` returns targets |
| Bootstrap exits non-zero | Its guard rejected the generated `nodes.yml` | `docker logs bootstrap`; the cause is almost always a malformed `NODE_TARGETS` value |
| A device target is `down` | `node_exporter` not installed there, or the firewall blocks `9100/tcp` | Install `node_exporter` on the device, open the port, confirm the address in `NODE_TARGETS` |
| A target is `up` but its dashboard is empty | The target has no `host` label | Add the `name=` prefix in `NODE_TARGETS` and Update |
| Edited `nodes.yml` by hand and "nothing changed" | It is regenerated from `NODE_TARGETS` on every Update | Edit the variable, not the file |
| `prometheus`/`alertmanager` stuck restarting | Config missing or `data/` permissions | Update the stack again (the bootstrap creates and chowns); then `docker logs prometheus --tail 30` |
| `network monitoring-net not found` | The external network does not exist yet | Create it once: `docker network create monitoring-net` |

### Historical bug: `No data` on every device (fixed)

The compose file had drifted into a broken state: the `prometheus`, `alertmanager` and `node-exporter` services were gone along with their volumes, environment and network, and the `nodes.yml` generator produced a malformed file as soon as `NODE_TARGETS` held more than one entry (it emitted a trailing separator and mis-escaped `$` as `$$$$` through Compose interpolation). Prometheus logged an error reading the file_sd list and dropped the whole `node` job, which left exactly one target — Prometheus scraping itself — so dashboards showed `No data` while every container still reported `Up`.

The fix restored all four services with their six data volumes, the shared external network and the bootstrap's environment; rewrote the generator to emit one correctly escaped target per entry with a default target and correct `$` escaping; added the structural guard described above; and dropped an unused collector flag that was noisy on hosts without a running systemd DBus. It was verified in three passes: static checks on the compose file, an offline emulation of the bootstrap against one, two and three targets (including a regression case built from the old malformed file), and a post-deploy check against the live stack.

## Security

- This is a public repository: **never** commit real hostnames or addresses here. Targets live only in `NODE_TARGETS` (Portainer / the gitignored local `.env`). `prometheus/targets/nodes.yml.example` is a reference copy only.
- Prometheus and Alertmanager publish **no ports** (internal `monitoring-net` only); local diagnostic access goes through the API inside the cluster (`docker exec ... localhost:9090`).

More detail and the step-by-step deployment runbook live in the local working document referenced from the Grafana folder.
