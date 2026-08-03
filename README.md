# Docker Compose — Repo de servicios del Homelab

Este repositorio contiene la configuración completa de Docker Compose de mi
Homelab (Debian), con volúmenes persistentes y sin depender del router.

**El repo es la única fuente de verdad**: lo que no está aquí con push a
Forgejo, no existe. Los `docker-compose.yml` se versionan; los datos y las
credenciales no.

## ✨ Propósito

- Definir cada servicio en su propia carpeta (`docker-compose.yml` + `.env.example`).
- Datos persistentes vía volúmenes que usan variables (flexibles y seguros).
- Desplegar todo el stack desde el repo con `docker compose`, y versionarlo en
  Forgejo (remoto). Portainer queda solo como **visor/monitor**.

## 🔧 Uso y configuración

1. En la raíz del repo, copia el archivo de variables de ejemplo y edítalo:
   `cp global.env.example global.env`
2. Define las variables en `global.env` con los datos reales de tu sistema. Por
   ejemplo, sustituye `DISK_UUID_PATH` con el UUID real de tu disco externo:
   `DISK_UUID_PATH=/srv/dev-disk-by-uuid-XXXXXXXXXXXXXX`
3. Cada carpeta de servicio tiene su `.env.example`; cópialo a `.env` y rellena
   las credenciales de ese servicio. El `.env` **NUNCA** se sube al repo.
4. Los volúmenes usan variables como `PATH_TO_CONTAINERS` o `DISK_UUID_PATH`
   para ser flexibles.
5. Despliega desde la carpeta del servicio: `docker compose up -d`

### Estructura

```
Docker Compose/                  <- repo git "docker-compose" (monorepo)
├── global.env.example           <- plantilla de variables compartidas
├── .gitignore                   <- excluye global.env, .env, datos
├── README.md
├── Git/                         <- servicio Forgejo
│   ├── docker-compose.yml
│   ├── .env.example             <- plantilla (versionada)
│   └── .env                     <- credenciales reales (NO se versiona)
└── <OtroServicio>/
    ├── docker-compose.yml
    └── .env.example
```

- **Código** (compose): en este repo.
- **Datos** (repos, BD, uploads): en las rutas que definen las variables
  (p. ej. `/home/akuilera/Documentos/Containers/<servicio>/`). Los datos NO se
  versionan.

### Flujo de trabajo

1. **Editar** un compose dentro del repo (en el servidor o desde la laptop con Gittyup).
2. **Aplicar**: `docker compose up -d` dentro de la carpeta del servicio.
3. **Probar**. Si funciona, **versionar**:
   ```
   git add -A
   git commit -m "descripción del cambio"
   git push origin main
   ```
4. **Portainer**: solo para ver/monitorear contenedores, no para crear o editar
   servicios (así las copias no divergen).
5. El disco externo y la laptop son **clones** del repo: siempre `git pull` /
   `git push`, nunca copiar archivos a mano.

### Networks

- **Host**: ZeroTier (quizá DuckDNS en el futuro)
- **Bridge**:
  - **vpn-net**: Wireguard + Pi-Hole
  - **proxy-net**: Cloudflared + GoAccess + NGINX Proxy Manager
  - **immich-net**: Immich + Immich Postgres + Immich Redis + NGINX Proxy Manager
  - **heimdall-net**: Heimdall
  - **files-net**: Filebrowser + Samba + Syncthing
  - **media-download-net**: Jackett + Transmission + Emby
  - **media-net**: Jellyfin
  - **apps-net**: OpenSpeedTest + Portainer + NGINX Proxy Manager
  - **nextcloud-net**: NextCloud + Collabora + NGINX Proxy Manager
  - **db-net**: MariaDB + NGINX Proxy Manager + NextCloud (la usa Forgejo)
- **None**: Nada

#### Crear redes (una sola vez, por CLI)

Las redes se crean una sola vez y los compose las usan con `external: true`:

```bash
docker network create --driver bridge proxy-net
docker network create --driver bridge --subnet=10.8.0.0/24 vpn-net
docker network create --driver bridge immich-net
docker network create --driver bridge media-download-net
docker network create --driver bridge apps-net
docker network create --driver bridge db-net
docker network create --driver bridge file-sharing-net
docker network create --driver bridge isolated_1
docker network create --driver bridge isolated_2
```

### 🚫 .gitignore

Los archivos sensibles (`global.env`, `.env`, bases de datos y carpetas de
configuración) están excluidos para proteger tu información.

## 📖 Acerca de

Esta configuración fue inspirada y adaptada del repositorio
[James's Garage](https://github.com/JamesTurland/JimsGarage) y los
[tutoriales de Compucenter33](https://www.youtube.com/watch?v=l1pKEIPZNoM&t=1696s),
complementada con recursos encontrados en el camino.
