# Grafana

Grafana centralizado (una sola instancia, varias carpetas/proyectos) que consume Prometheus de `Automatization/Monitoring/Prometheus` por la red compartida `monitoring-net`.

## Provisioning (viene del repo)

- **Datasource Prometheus**: `grafana/provisioning/datasources/prometheus.yml` — uid `prometheus`, url `http://prometheus:9090` (resuelto por `monitoring-net`). Se monta **relativo** al clon de Portainer (`./grafana/provisioning → /etc/grafana/provisioning:ro`), o sea: **deploy por Stack from Git** y `git push` + Update stack para propagar cambios.
- **Dashboards**: carpeta `Infrastructure/` vía `dashboards/dashboards.yml` (proveedor `file`, `updateIntervalSeconds: 30`). Los dashboards son **genéricos por rol** (`server`, `client-1`), no identidades reales — se alterna con la variable *Host*.

## Datos y secreto

- Persistencia: `${PATH_TO_CONTAINERS}/Grafana/data` (no va al repo).
- Base de datos: MariaDB del proyecto (`db-net`), datos de conexión vía Docker secrets con `*_FILE` (`${PATH_TO_SECRETS}/Grafana/grafana_db_*`). Fuera del commit.
- `user: "472:472"` (grafana) ya compatible.

## Redes

- `db-net` (external) — MariaDB.
- `monitoring-net` (external) — Prometheus. Ambas deben existir antes de desplegar.

## Puertos y acceso

- Host: `3001:3000` (puerto 3001 en el servidor). Primer login: `admin / admin` (cambiar después).

## Rolling

1. `git push` de cambios en `Automatization/Grafana/`.
2. Portainer → Stack de Grafana → **Update** (mantener variables y secrets existentes). El contenedor se recrea; `data/` y los secrets persisten.