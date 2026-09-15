# Monitoring — Prometheus + Alertmanager + Node Exporter

Stack de monitoreo de la infraestructura: Prometheus scrapea métricas de Node Exporter (servidor y dispositivos remotos), guarda ~90 días de historial (máx 10 GB) y Alertmanager queda listo para notificaciones (receiver vacío por ahora). Grafana consume Prometheus por la red compartida `monitoring-net`.

## Layout (GitOps — la config vive en el repo)

- **Config estática → este repo**, montada **relativa** al clon de Portainer (`./prometheus`, `./alertmanager`). Por eso el stack se despliega SIEMPRE como **Portainer → Stack from Git**; Upload/Text no vale (las rutas relativas dependen del clon).
- **Personal/estado → servidor**, bajo `${PATH_TO_CONTAINERS}`:

| Ruta en el servidor | Montaje en el contenedor | Contenido |
|---|---|---|
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/targets` | `/etc/prometheus/targets:ro` | Único archivo personal: `nodes.yml` (hosts reales) |
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/data` | `/prometheus` | TSDB de Prometheus |
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/alertmanager-data` | `/data` | Datos de Alertmanager |

Update flow: `git push` → Portainer → **Update stack** (la config nueva llega sola; el TSDB y `nodes.yml` no se tocan).

## Bootstrap (en el servidor, una vez)

```bash
# 1. Red external compartida con Grafana
docker network create --driver bridge monitoring-net

# 2. Directorios con el UID de los contenedores (65534 = nobody)
sudo mkdir -p "${PATH_TO_CONTAINERS}/Monitoring/Prometheus"/{data,alertmanager-data,targets}
sudo chown -R 65534:65534 "${PATH_TO_CONTAINERS}/Monitoring/Prometheus"

# 3. Targets reales (personal, gitignored): copy del example y rellenar el placeholder <hostname>
cp <clone>/Automatization/Monitoring/Prometheus/prometheus/targets/nodes.yml.example \
   "${PATH_TO_CONTAINERS}/Monitoring/Prometheus/targets/nodes.yml"
nano "${PATH_TO_CONTAINERS}/Monitoring/Prometheus/targets/nodes.yml"
```

4. **Portainer → Stacks → + Add stack** → *Git Repository* → carpeta `Automatization/Monitoring/Prometheus` → variable `PATH_TO_CONTAINERS` (usa el valor real del `.env` del servidor) → Deploy.

## Recarga de targets sin reinicio (hot reload)

```bash
docker kill -s HUP prometheus
```

Más detalle y troubleshooting en el doc de trabajo local (`Automatization/Grafana/TODO.md`).

## Node Exporter en dispositivos remotos

Las máquinas monitoreadas corren `node_exporter` **nativo** (no en contenedor): binario + unit systemd + firewall. Ejemplo de instalación para dispositivos Fedora en `Recursos/<dispositivo>/Desktop/Monitoring/install-node-exporter.sh`. Cada dispositivo nuevo = 1 bloque en `nodes.yml` + instalar el exporter allí.

## Seguridad

- Repo público: **nunca** hostnames/IPs reales aquí; `nodes.yml` real solo en el servidor (patrón gitignore `**/Prometheus/prometheus/targets/nodes.yml`).
- Prometheus y Alertmanager **sin puertos publicados** (solo red interna `monitoring-net`); el acceso local de diagnóstico se hace por API dentro del clúster (`docker exec ... localhost:9090`).