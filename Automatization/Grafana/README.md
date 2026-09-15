# Grafana

Grafana centralizado (una sola instancia, varias carpetas/proyectos) que consume Prometheus de `Automatization/Monitoring/Prometheus` por la red compartida `monitoring-net`.

## Provisioning (auto-sembrado, no depende del clon)

El stack **no lee nada del clon en runtime** (igual que Monitoring). Un servicio `bootstrap` (busybox, one-shot, `depends_on: service_completed_successfully`) escribre el provisioning en `${PATH_TO_CONTAINERS}/Grafana/provisioning` **solo si falta o está vacío**:

- **Datasource Prometheus** — `datasources/prometheus.yml`: uid `prometheus`, url `http://prometheus:9090` (resuelto por `monitoring-net`).
- **Dashboards** — carpeta `Infrastructure/` vía `dashboards/dashboards.yml` (proveedor `file`, `updateIntervalSeconds: 30`). Dashboards genéricos por rol (`server`, `client-1`), se alternan con la variable *Host*.

> **El label `host` lo pone Monitoring, no Grafana.** La variable *Host* filtra `host="$host"`, y ese label llega en las métricas scrapeadas desde el bootstrap de Monitoring (`NODE_TARGETS` en formato `nombre=host:port` → cada target con su label `host`). Añadir/quitar dispositivo en Grafana = **solo** tocar `NODE_TARGETS` en el stack Monitoring y Update (Grafana no reconfigura nada). Si un dispositivo está **UP en Prometheus pero el dashboard no muestra data** (no el server), es que su target llegó sin label `host` (faltó el prefijo `nombre=`).

El contenido (heredocs del `bootstrap`) es la **única fuente de verdad** en el repo; ya no hay carpeta `grafana/provisioning/`. Para personalizar un dashboard tras el primer despliegue, edita el archivo ya sembrado en el server (`${PATH_TO_CONTAINERS}/Grafana/provisioning/dashboards/*.json`) — el bootstrap nunca sobrescribe archivos existentes.

> **Por qué absoluto**: en Portainer CE, los binds **relativos al clon git (`./...`) resuelven a un dir vacío** (el repo no se materializa en el host). Por eso el provisioning vive bajo `${PATH_TO_CONTAINERS}` y lo siembra el bootstrap, igual que la config de Monitoring.

## Datos y secreto

- Persistencia: `${PATH_TO_CONTAINERS}/Grafana/data` (no va al repo).
- Base de datos: MariaDB del proyecto (`db-net`), datos de conexión vía Docker secrets con `*_FILE` (`${PATH_TO_SECRETS}/Grafana/grafana_db_*`). Fuera del commit.
- `user: "472:472"` (grafana), ya compatible.

## Redes

- `db-net` (external) — MariaDB.
- `monitoring-net` (external) — Prometheus. Ambas deben existir antes de desplegar.

## Puertos y acceso

- Host: `3001:3000` (puerto 3001 en el servidor). Primer login: `admin / admin` (cambiar después).

## Rolling

1. `git push` de cambios en `Automatization/Grafana/`.
2. Portainer → Stack de Grafana → **Update** (mantener variables y secrets existentes).
3. El `bootstrap` corre primero (siembra solo lo que falta, exit 0) y después `grafana` se recrea; `data/` y los secrets persisten.