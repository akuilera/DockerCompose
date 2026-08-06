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
Docker Compose/                  <- git repo (monorepo)
├── global.env.example           <- shared variables template
├── .gitignore                   <- excludes global.env, .env, data
├── README.md
├── Git/
│   ├── Forgejo/                 <- Forgejo service (canonical)
│   │   ├── docker-compose.yml
│   │   ├── .env.example         <- template (versioned)
│   │   └── .env                 <- real credentials (NOT versioned)
│   └── Gitea/                   <- legacy (kept for reference)
│       ├── docker-compose.yml
│       └── .env.example
└── <AnotherService>/
    ├── docker-compose.yml
    └── .env.example
```

- **Code** (compose): in this repo.
- **Data** (repos, DBs, uploads): in the paths defined by the variables (`PATH_TO_CONTAINERS` / `DISK_UUID_PATH` in `global.env`). Data is NOT versioned.

### Workflow

Portainer is the primary management tool. Each service is a `docker-compose.yml` in this repo, hosted on Forgejo and deployed by Portainer as a **Repository stack**. Portainer runs `docker compose` under the hood, so the repo always remains the single source of truth.

1. **Edit** a compose file inside the repo (from the laptop with Gittyup, or on the server).
2. **Version it** (never copy files by hand — git is the sync mechanism):
   ```
   git add -A
   git commit -m "description of the change"
   git push origin main
   ```
   > **Dual push**: `origin` has two push URLs (Forgejo + the GitHub mirror), so a single `git push origin main` updates both. The mirror never lags behind and is the bootstrap/DR source for Forgejo's own deployment.
   >
   > From the laptop, **Gittyup** is the client: one **Push** does the same dual push (origin targets both hosts).
3. **Deploy**: in Portainer, open the service's stack → **Update** (pull latest and redeploy), or enable the stack **webhook** to redeploy automatically on every push.
4. **Portainer** is used for everything: creating/deploying stacks from the repo, updating them, and viewing logs.
5. The laptop and the server working copies stay in sync **via git** (`pull` / `push`).

> **Initial bootstrap**: Portainer (the management UI itself) is deployed once from the server CLI with `docker compose up -d`, because it cannot pull its own repo as a stack. Forgejo (the git host) is the only service deployed by Portainer from the **GitHub mirror** (`Git/Forgejo/docker-compose.yml`) instead of from Forgejo itself, to avoid the chicken-and-egg problem: Forgejo's own compose cannot be fetched from Forgejo while Forgejo is down, but the mirror is always reachable. Every other service is deployed as a Repository stack from Forgejo.
>
> The chicken-and-egg does not end there: reaching Forgejo by URL also requires **NGINX Proxy Manager** (reverse proxy) + **ZeroTier** (network route to the server), and NPM needs **MariaDB** to run (its backend DB) — the same MariaDB that hosts Forgejo's own database. See [Boot order / Dependencies](#boot-order--dependencies).

### Boot order / Dependencies

Reaching Forgejo by URL is itself a chicken-and-egg problem: a reachable URL requires **NGINX Proxy Manager** (reverse proxy) + **ZeroTier** (network route to the server), and NPM cannot start without **MariaDB** (its backend database, `DB_MYSQL_HOST: mariadb`). MariaDB also hosts Forgejo's own database. So on a cold start (reboot, power loss, DR) the chain is:

1. **MariaDB** (+ `redis`) — first; everything below depends on it.
2. **ZeroTier** + **NGINX Proxy Manager** — the network route and the URL layer.
3. **Forgejo** and the rest of the services — deployable and reachable from here on.

`restart: always` / `restart: unless-stopped` bring every container back automatically after a reboot, but on a cold start MariaDB must come up first, or NPM (and Forgejo) will fail to connect to its database.

### Remotes

The canonical host is **Forgejo**. GitHub is a **read-only DR mirror**: its only role is to let Portainer redeploy Forgejo if Forgejo is down. Nobody pushes directly to GitHub except the dual push below.

```
origin   Forgejo (canonical) — fetch + push
         push also targets the GitHub mirror (dual push)
lan      Forgejo via the LAN/ZeroTier route — fallback when the public route is down
mirror   GitHub — DR / bootstrap only
```

- Daily work uses only `origin`: a single `git push` updates both Forgejo and the mirror.
- `lan` is a fallback route when the public one is unreachable; `mirror` is reserved for DR.

### Server auto-sync (cron service)

The server keeps a working copy of the repo at
`/mnt/Documentos/Hogar/Proyectos/Programación/Segundo Cerebro/Código/Docker Compose/`,
always identical to `main`:

- A **cron job** runs every 10 minutes:
  `git -C "<server path>" pull --ff-only`, with the log at
  `~/.cache/mirror-dockercompose.log`.
- The server authenticates to Forgejo over SSH (alias `forgejo-mirror`,
  port 222) with the key `~/.ssh/llave_ssh_servidor-forgejo` (registered in
  the Forgejo account).
- The working copy contains **only** versioned content. Old leftovers that
  are not in the repo are removed (`git clean -fd`): nothing lives outside
  git on the server. If a pull fails (e.g. an untracked file would be
  overwritten), the error lands in the log and the folder stays as-is until
  it is fixed.

### Disaster recovery (DR)

If Forgejo dies, the repo is still recoverable because every change was also pushed to the GitHub mirror:

1. In Portainer, deploy/redeploy the Forgejo stack from the mirror at `Git/Forgejo/docker-compose.yml`.
2. Set the same environment variables as before (`USER_UID`, `USER_GID`, `PATH_TO_CONTAINERS`, `PATH_TO_SECRETS`; the DB credentials are read from the secret files under `PATH_TO_SECRETS/Forgejo/`).
3. Restore the Forgejo data volume (repos, DB) from your server backups — data is never in the repo.
4. Verify the recovered history: canonical history lives on `main`; the pre-migration history is archived on the `pre-migration` branch of the mirror.

> The `.env` files needed to deploy live on the laptop/server and are never versioned. Back them up together with the data.

### Networks

- **Host**: ZeroTier (maybe DuckDNS in the future)
- **Bridge**:
  - **vpn-net**: Wireguard + Pi-Hole
  - **proxy-net**: Cloudflared + GoAccess + NGINX Proxy Manager
  - **immich-net**: Immich + Immich Postgres + Immich Redis + NGINX Proxy Manager
  - **heimdall-net**: Heimdall
  - **files-net**: Filebrowser + Samba + Syncthing
  - **fmd-net**: FindMyDevice
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

## ⚖️ License

This repository is licensed under the [MIT License](LICENSE). © 2026 Akuilera. You may use, copy, modify and redistribute it with attribution; the software is provided "as is", without warranty of any kind.

## 📖 About

This setup was inspired by and adapted from the repository [James's Garage](https://github.com/JamesTurland/JimsGarage) and the [Compucenter33 tutorials](https://www.youtube.com/watch?v=l1pKEIPZNoM&t=1696s), complemented with resources found along the way.
