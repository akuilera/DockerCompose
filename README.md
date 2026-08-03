# Docker Compose — Homelab Services Repo

This repository holds the full Docker Compose configuration of my Homelab (Debian), with persistent volumes and no dependency on the router.

**The repo is the single source of truth**: what is not here with a push to Forgejo does not exist. The `docker-compose.yml` files are versioned; data and credentials are not.

## ✨ Purpose

- Define each service in its own folder (`docker-compose.yml` + `.env.example`).
- Persistent data via volumes that use variables (flexible and safe).
- Deploy every service from the repo as a **Portainer Repository stack** (Portainer is the main management tool). The repo lives on Forgejo; the `docker-compose.yml` files are the single source of truth.

## 🔧 Usage and configuration

1. At the repo root, copy the sample variables file and edit it: `cp global.env.example global.env`
2. Define the variables in `global.env` with the real values of your system. For example, replace `DISK_UUID_PATH` with the real UUID of your external disk: `DISK_UUID_PATH=/srv/dev-disk-by-uuid-XXXXXXXXXXXXXX`
3. Each service folder has its `.env.example`; copy it to `.env` and fill in that service's credentials. The `.env` file is **NEVER** uploaded to the repo.
4. Volumes use variables such as `PATH_TO_CONTAINERS` or `DISK_UUID_PATH` to stay flexible.
5. Deploy from the service folder: `docker compose up -d`

### Structure

```
Docker Compose/                  <- git repo "docker-compose" (monorepo)
├── global.env.example           <- shared variables template
├── .gitignore                   <- excludes global.env, .env, data
├── README.md
├── Git/                         <- Forgejo service
│   ├── docker-compose.yml
│   ├── .env.example             <- template (versioned)
│   └── .env                     <- real credentials (NOT versioned)
└── <AnotherService>/
    ├── docker-compose.yml
    └── .env.example
```

- **Code** (compose): in this repo.
- **Data** (repos, DBs, uploads): in the paths defined by the variables (e.g. `/home/akuilera/Documentos/Containers/<service>/`). Data is NOT versioned.

### Workflow

Portainer is the primary management tool. Each service is a `docker-compose.yml` in this repo, hosted on Forgejo and deployed by Portainer as a **Repository stack**. Portainer runs `docker compose` under the hood, so the repo always remains the single source of truth.

1. **Edit** a compose file inside the repo (from the laptop with Gittyup, or on the server).
2. **Version it** (never copy files by hand — git is the sync mechanism):
   ```
   git add -A
   git commit -m "description of the change"
   git push origin main
   ```
3. **Deploy**: in Portainer, open the service's stack → **Update** (pull latest and redeploy), or enable the stack **webhook** to redeploy automatically on every push.
4. **Portainer** is used for everything: creating/deploying stacks from the repo, updating them, and viewing logs.
5. The laptop and the server working copies stay in sync **via git** (`pull` / `push`).

> **Initial bootstrap**: the very first deployment of Forgejo (the git host itself) is done once from the server CLI with `docker compose up -d` inside `Git/Forgejo/`, because Portainer needs a hosted repo URL to pull from. After that, Portainer manages Forgejo like any other service.

### Networks

- **Host**: ZeroTier (maybe DuckDNS in the future)
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
  - **db-net**: MariaDB + NGINX Proxy Manager + NextCloud (used by Forgejo)
- **None**: Nothing

#### Create networks (once, via CLI)

Networks are created once and the compose files use them with `external: true`:

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

Sensitive files (`global.env`, `.env`, databases and configuration folders) are excluded to protect your information.

## 📖 About

This setup was inspired by and adapted from the repository [James's Garage](https://github.com/JamesTurland/JimsGarage) and the [Compucenter33 tutorials](https://www.youtube.com/watch?v=l1pKEIPZNoM&t=1696s), complemented with resources found along the way.
