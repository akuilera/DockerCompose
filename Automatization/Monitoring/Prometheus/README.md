# Monitoring — Prometheus + Alertmanager + Node Exporter

Stack de monitoreo de la infraestructura: Prometheus scrapea métricas de Node Exporter (servidor y dispositivos remotos), guarda ~90 días de historial (máx 10 GB) y Alertmanager queda listo para notificaciones (receiver vacío por ahora). Grafana consume Prometheus por la red compartida `monitoring-net`.

## Layout — TODO bajo `${PATH_TO_CONTAINERS}`

Toda la config, plantillas y datos viven en el servidor bajo `${PATH_TO_CONTAINERS}`; el repo no monta nada en runtime (solo aporta el compose y las plantillas de referencia):

${PATH_TO_CONTAINERS}/Monitoring/Prometheus/

```text
Monitoring/Prometheus/
├── prometheus/
│   ├── tmpl/      → /tmpl (plantillas; solo se regeneran si faltan)
│   ├── config/    → /etc/prometheus:ro (config real que lee Prometheus)
│   └── data/      → /prometheus (TSDB, propietario 65534)
└── alertmanager/
    ├── tmpl/      → /tmpl-alertmanager (plantilla)
    ├── config/    → /etc/alertmanager:ro (config real)
    └── data/      → /data (propietario 65534)
```

- Un servicio `bootstrap` (busybox) crea los directorios en el primer arranque, siembra la config por defecto solo si falta (`cp -n`, nunca pisa ediciones), regenera `nodes.yml` desde la env `NODE_TARGETS` y hace `chown -R 65534:65534` de los `data/` → **no hay pasos manuales** (ni mkdir, ni chown, ni scripts).
- Los contenedores de Prometheus/Alertmanager corren como `nobody` (UID 65534).
- Un solo bind completo por servicio, siempre sobre destinos que ya existen en la imagen (`/etc/prometheus`, `/etc/alertmanager`): evita el EROFS de montajes anidados.

## Despliegue (Portainer → Stack from Git)

1. Carpeta: `Automatization/Monitoring/Prometheus`.
2. Variables de entorno del stack:
   - `PATH_TO_CONTAINERS` — raíz de datos (la que uses en otros stacks, p. ej. `${PATH_TO_CONTAINERS}` de tu `global.env`).
   - `PATH_TO_SECRETS` — si procede.
   - `NODE_TARGETS` — hosts a scrapear, pares `nombre=host:port` separados por comas. El `nombre=` hace que el bootstrap ponga el label `host: <nombre>` a ese target → es lo que los dashboards usan para filtrar (`$host`). Default: `server=node-exporter:9100`.
3. **Deploy**. Update tras cada `git push`; añadir/quitar dispositivos = editar `NODE_TARGETS` → Update.

El `bootstrap` termina en *Exited (0)*; quedan corriendo `prometheus`, `alertmanager` y `node-exporter` (red externa `monitoring-net`, sin puertos publicados).

## Añadir un dispositivo

1. Instala `node_exporter` nativo en él (ver `Recursos/<dispositivo>/Desktop/Monitoring/install-node-exporter.sh`).
2. Añade su dirección **con prefijo `nombre=`** (`server=node-exporter:9100`, `client-1=host-zerotier:9100`) a `NODE_TARGETS` del stack en Portainer → Update. Sin el `nombre=`, el target scrapea UP pero sin label `host` → los dashboards muestran **No data**.

## Editar la config (sin redeploy)

Se edita directamente en `.../{prometheus,alertmanager}/config/` del servidor y se recarga el proceso:

```bash
docker kill -s HUP prometheus
docker kill -s HUP alertmanager
```

`sync-config.sh` ya no existe: el bootstrap hace el seed automáticamente en cada Update.

Más detalle y troubleshooting en el doc de trabajo local (`Automatization/Grafana/TODO.md`).

## Seguridad

- Repo público: **nunca** hostnames/IPs reales aquí; los targets viven solo en `NODE_TARGETS` (Portainer/`.env` local gitignored). `prometheus/targets/nodes.yml.example` es solo referencia.
- Prometheus y Alertmanager **sin puertos publicados** (solo red interna `monitoring-net`); el acceso local de diagnóstico se hace por API dentro del clúster (`docker exec ... localhost:9090`).