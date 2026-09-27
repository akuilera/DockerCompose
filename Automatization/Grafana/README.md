# Grafana

Single centralised Grafana instance (one instance, several folders/projects) that reads Prometheus from `Automatization/Monitoring/Prometheus` over the shared `monitoring-net` network.

## Provisioning (self-seeding, nothing read from the clone)

Like the monitoring stack, this one reads **nothing from the clone at runtime**. A one-shot `bootstrap` service (busybox, `depends_on: service_completed_successfully`) writes the provisioning into `${PATH_TO_CONTAINERS}/Grafana/provisioning` **only if it is missing or empty**:

- **Prometheus datasource** — `datasources/prometheus.yml`: uid `prometheus`, url `http://prometheus:9090` (resolved through `monitoring-net`).
- **Dashboards** — an `Infrastructure/` folder via `dashboards/dashboards.yml` (provider `file`, `updateIntervalSeconds: 30`). The dashboards are generic per role (`server`, `client-1`) and are switched with the *Host* variable.

> **The `host` label comes from Monitoring, not from Grafana.** The *Host* variable filters on `host="$host"`, and that label arrives on the scraped metrics because the Monitoring bootstrap turns each `name=host:port` entry in `NODE_TARGETS` into a target carrying `host: <name>`. Adding or removing a device in Grafana therefore means **only** editing `NODE_TARGETS` in the Monitoring stack and hitting Update; Grafana reconfigures nothing. If a device is **UP in Prometheus but its dashboard shows no data**, the target arrived without a `host` label (the `name=` prefix was missing).

The content (heredocs inside `bootstrap`) is the **single source of truth** in the repository; there is no `grafana/provisioning/` folder any more. To customise a dashboard after the first deployment, edit the file already seeded on the server (`${PATH_TO_CONTAINERS}/Grafana/provisioning/dashboards/*.json`) — the bootstrap never overwrites existing files.

> **Why absolute paths**: in Portainer CE, binds **relative to the git clone (`./...`) resolve to an empty directory**, because the repository is not materialised on the host. That is why the provisioning lives under `${PATH_TO_CONTAINERS}` and is seeded by the bootstrap, exactly like the monitoring config.

## Dashboards

`Infrastructure/` holds one overview per role. Every panel filters on `job="node"` and `host="$host"`, so the *Host* variable alternates between the roles declared in `NODE_TARGETS` (`server` for the host running the stack, `client-1` for the remote device). The role names are deliberately generic rather than real identities; renaming the options in the *Host* variable is a local change to your own instance.

Panels cover CPU, load, memory, swap, disk, network, temperature and uptime/restarts.

## Data and secrets

- Persistence: `${PATH_TO_CONTAINERS}/Grafana/data` (never committed).
- Database: the project's MariaDB on `db-net`, connection details supplied through Docker secrets using `*_FILE` (`${PATH_TO_SECRETS}/Grafana/grafana_db_*`). Kept out of the repository.
- `user: "472:472"` (the grafana user), already compatible.

## Networks

- `db-net` (external) — MariaDB.
- `monitoring-net` (external) — Prometheus. Both must exist before deploying.

## Ports and access

- Host: `3001:3000` (port 3001 on the server). First login: `admin / admin` — change it afterwards.

## Rolling update

1. `git push` the changes in `Automatization/Grafana/`.
2. Portainer → Grafana stack → **Update** (keep the existing variables and secrets).
3. `bootstrap` runs first (seeds only what is missing, exits 0) and then `grafana` is recreated; `data/` and the secrets persist.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dashboards do not appear | Provisioning not mounted | `docker inspect grafana` must show a bind on `/etc/grafana/provisioning`; if missing, Update the stack; if present but empty, `docker restart grafana` |
| Datasource error | Grafana cannot reach `prometheus` | Check that Grafana is on `monitoring-net` (`docker inspect grafana`) and that the network exists |
| Panels show `No data` for one device | The target has no `host` label, or the target is down | Check `/api/v1/targets` in Prometheus; if it is UP, add the `name=` prefix in the Monitoring stack's `NODE_TARGETS` |
| `network monitoring-net not found` | The external network does not exist | Create it once: `docker network create monitoring-net` |
