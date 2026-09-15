# Monitoring — Prometheus + Alertmanager + Node Exporter

Stack de monitoreo de la infraestructura: Prometheus scrapea métricas de Node Exporter (servidor y dispositivos remotos), guarda ~90 días de historial (máx 10 GB) y Alertmanager queda listo para notificaciones (receiver vacío por ahora). Grafana consume Prometheus por la red compartida `monitoring-net`.

## Layout (GitOps — la config vive en el repo)

- **Config estática → este repo**, montada **relativa** al clon de Portainer (`./prometheus`, `./alertmanager`). Por eso el stack se despliega SIEMPRE como **Portainer → Stack from Git**; Upload/Text no vale (las rutas relativas dependen del clon).
- **Personal/estado → servidor**, bajo `${PATH_TO_CONTAINERS}`:

| Ruta en el servidor | Montaje en el contenedor | Contenido |
|---|---|---|
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/nodes.yml` | semilla → `prometheus/targets/nodes.yml` (dentro del bind de config) | Único archivo personal: hosts reales (file_sd) |
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/data` | `/prometheus` | TSDB de Prometheus |
| `${PATH_TO_CONTAINERS}/Monitoring/Prometheus/alertmanager-data` | `/data` | Datos de Alertmanager |

**Los binds solo usan destinos que ya existen en la imagen del contenedor.** En este host Docker no puede crear destinos nuevos en el rootfs (`mkdirat`/`mknod` → `read-only file system`), ni como directorio ni como archivo. Por eso `nodes.yml` no se monta con su propio bind: se **siembra** dentro del SOURCE del bind de config que ya funciona (`./prometheus → /etc/prometheus`). El archivo durable vive fuera del clon y del repo.

Update flow: `git push` → Portainer → **Update stack** → `bash prometheus/sync-config.sh` → `sudo docker kill -s HUP prometheus` (el re-clon del Update borra los archivos no versionados, por eso el seed va después).

## Bootstrap (en el servidor, una vez)

```bash
# 1. Red external compartida con Grafana
docker network create --driver bridge monitoring-net

# 2. Directorios con el UID de los contenedores (65534 = nobody)
sudo mkdir -p "${PATH_TO_CONTAINERS}/Monitoring/Prometheus"/{data,alertmanager-data,targets}
sudo chown -R 65534:65534 "${PATH_TO_CONTAINERS}/Monitoring/Prometheus"

# 3. Archivo durable de targets (personal, fuera del repo): copia del example y rellena la IP
cp <clon>/Automatization/Monitoring/Prometheus/prometheus/targets/nodes.yml.example \
   "${PATH_TO_CONTAINERS}/Monitoring/Prometheus/nodes.yml"
nano "${PATH_TO_CONTAINERS}/Monitoring/Prometheus/nodes.yml"

# 4. Siembra el archivo en el clon (destino del bind de config) y comprueba
bash <clon>/Automatization/Monitoring/Prometheus/prometheus/sync-config.sh
```

5. **Portainer → Stacks → + Add stack** → *Git Repository* → carpeta `Automatization/Monitoring/Prometheus` → variable `PATH_TO_CONTAINERS` (usa el valor real del `.env` del servidor) → Deploy. Después cada Update, re-ejecuta el paso 4 (re-clon vuelve a limpiar el seed).

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