# Docker Compose — Homelab Services Repo

This repository holds the full Docker Compose configuration of a Homelab (Debian), with persistent volumes and no dependency on the router.

**The repo is the single source of truth**: what is not here, pushed to the git host, does not exist. The `docker-compose.yml` files are versioned; data and credentials are not.

## ✨ Purpose

- Define each service in its own folder (`docker-compose.yml` + `.env.example`).
- Persistent data via volumes that use variables (flexible and safe).
- Deploy every service from the repo as a **Portainer Repository stack** (Portainer is the main management tool). The `docker-compose.yml` files are the single source of truth.

## 🔧 Usage and configuration

1. At the repo root, copy the sample variables file and edit it: `cp global.env.example global.env`
2. Define the variables in `global.env` with the real values of your system: `PATH_TO_CONTAINERS`, `PATH_TO_SECRETS` and `PATH_TO_DOCUMENTS`.
3. Each service folder has its `.env.example`; copy it to `.env` and fill in that service's non-personal variables (paths, UIDs, ports). Real credentials live in Docker secret files under `$PATH_TO_SECRETS/<Service>/` — they are **NEVER** uploaded to the repo.
4. Volumes use variables such as `PATH_TO_CONTAINERS` to stay flexible.
5. Deploy from the service folder: `docker compose up -d`

### Structure

```
<repo>/                            <- git repo (monorepo)
├── AGENTS.md                      <- agent rules for AI tools (public template)
├── global.env.example             <- shared variables template
├── .gitignore                     <- excludes global.env, .env, data
├── README.md
├── Automatization/                <- n8n
├── BackUp/                        <- Borg
├── Base/
│   ├── Database/                  <- MariaDB + sync-db.sh (DB user rotation)
│   ├── Network/                   <- Cloudflared, NGINX Proxy Manager, WireGuard, ZeroTier, ...
│   └── Service Delivery/          <- Portainer
├── Cloud/                         <- NextCloud, Collabora, Samba, FileBrowser, ...
├── Git/                           <- Forgejo (and Gitea, kept for reference)
├── Multimedia/                    <- Jellyfin, Immich, Transmission, ...
├── Security/                      <- Vaultwarden, ClamAV, FindMyDevice, init-secrets.sh
└── Web/                           <- WordPress
```

Each service folder holds its `docker-compose.yml` and a `.env.example` template. Real credentials are never versioned.

- **Code** (compose): in this repo.
- **Data** (repos, DBs, uploads): in the paths defined by the variables (`PATH_TO_CONTAINERS` / `PATH_TO_DOCUMENTS` in `global.env`). Data is NOT versioned.
- **Secrets** (credentials): in `$PATH_TO_SECRETS/<Service>/`, outside the repo — see [Security/README.md](Security/README.md).

### Workflow

1. **Edit** a compose file inside the repo (from any git client on the laptop, or on the server).
2. **Version it** (never copy files by hand — git is the sync mechanism):
   ```
   git add -A
   git commit -m "description of the change"
   git push origin main
   ```
3. **Deploy**: in Portainer, open the service's stack → **Update** (pull latest and redeploy), or enable the stack **webhook** to redeploy automatically on every push.
4. **Portainer** is used for everything: creating/deploying stacks from the repo, updating them, and viewing logs.
5. The laptop and the server working copies stay in sync **via git** (`pull` / `push`).

> **Initial bootstrap**: Portainer (the management UI itself) is deployed once from the server CLI with `docker compose up -d`, because it cannot pull its own repo as a stack. Every other service is deployed as a Repository stack from the git host.

### Boot order / Dependencies

On a cold start (reboot, power loss, DR) bring the database up first, because NGINX Proxy Manager (and several services) cannot start without it:

1. **MariaDB** — first; everything below depends on it.
2. **Networking layer** — ZeroTier (remote-access transport) + NGINX Proxy Manager (reverse proxy).
3. **The rest** — deployable and reachable from here on.

`restart: always` / `restart: unless-stopped` bring every container back automatically after a reboot, but on a cold start MariaDB must come up first, or NPM (and anything else backed by it) will fail to connect.

### Networks

- **Host**: ZeroTier — also the **remote-access transport**: this repo is designed to run **without opening any inbound port** on the router (see `Base/Network/WireGuard/README.md` → "Remote access"), so WireGuard clients reach the server over the ZeroTier mesh instead of a port-forward.
- **Bridge**:
  - **vpn-net**: WireGuard + Pi-hole — the VPN segment (subnet `10.8.1.0/24`)
  - **proxy-net**: Cloudflared + GoAccess + NGINX Proxy Manager — the public-ingress segment
  - **db-net**: MariaDB + NGINX Proxy Manager + NextCloud + Vaultwarden + Forgejo + WordPress + Borg — the database backend
  - **nextcloud-net**: NextCloud + Collabora + NGINX Proxy Manager
  - **immich-net**: Immich (+ machine-learning, Redis, Postgres) + NGINX Proxy Manager
  - **apps-net**: OpenSpeedTest + Portainer + NGINX Proxy Manager
  - **files-net**: FileBrowser + Samba + Syncthing
  - **fmd-net**: FindMyDevice
  - **media-download-net**: Jackett + Transmission + Emby
  - **heimdall-net**: Heimdall
- **Default bridge**: Jellyfin (no custom network; it publishes its own ports instead).

##### Why this layout

- **`vpn-net` is the VPN segment, not "every service reachable over VPN"**. It exists so wg-easy can terminate the tunnel (`10.8.1.2`) next to Pi-hole (`10.8.1.3`), letting tunnel clients use it as DNS. VPN clients reach *every other* service through wg-easy by L3 routing/NAT — those services do not need to be on `vpn-net`. Services that want Pi-hole as resolver opt in: join `vpn-net` and set `dns: [10.8.1.3, 127.0.0.11]` (the Docker resolver as fallback keeps service-name lookups like `mariadb` working).
- **`proxy-net` is the public-ingress segment** (Cloudflare tunnel → NPM → services). A service is on `proxy-net` only when NPM must reach it (or it must reach NPM). Administrative UIs (wg-easy, Pi-hole) deliberately stay off it so they are not exposed through the tunnel; manage them over the VPN or LAN.
- **ClamAV joins only its consumers' networks** (currently `nextcloud-net`): a scan endpoint is reachable from the segments that actually scan, not from all of them. See `Security/ClamAV/README.md`.
- **No inbound ports**: the repo assumes the router exposes nothing. Public web services leave outbound through the Cloudflare tunnel; admin/remote access goes over ZeroTier. The WireGuard endpoint is the server's ZeroTier IP, so the WG tunnel rides inside the ZeroTier mesh. Phones run ZeroTier alone (a phone allows only one system VPN at a time — OS limit) and get Pi-hole as DNS through it; only laptop/desktop run both WireGuard and ZeroTier. Removing the ZeroTier dependency would require a host with a public IP (e.g. a paid VPS). Details: `Base/Network/WireGuard/README.md`.

#### Create networks (once)

Every compose file uses `external: true`, so **the networks must already exist before deploying** — `docker compose up` will not create them. Create them once, either via the CLI or in **Portainer → Networks → Add network**:

- `vpn-net` (needs the subnet `10.8.1.0/24`):

  ```bash
  docker network create --driver bridge --subnet=10.8.1.0/24 vpn-net
  ```

- The rest, a simple loop:

  ```bash
  for net in proxy-net db-net nextcloud-net immich-net apps-net files-net \
             fmd-net media-download-net heimdall-net; do
    docker network create --driver bridge "$net"
  done
  ```

> ZeroTier runs with `network_mode: host`, so it needs no Docker network.

### Server auto-sync (cron)

The server keeps a working copy of the repo, synced with `main`:

- A **cron job** runs every few minutes: `git -C "<server path>" pull --ff-only`, with the log in a file (e.g. `~/.cache/mirror-dockercompose.log`).
- A second **root cron** runs the weekly ClamAV scan of the container data folders: `0 3 * * 6 root docker exec clamav clamdscan --infected /scan/n8n >> /var/log/clamav-scan.log 2>&1` (see `Security/ClamAV/README.md` → "Scheduled scans").
- The host `clamonacc` also scans the container data trees on-access as files are opened, so the weekly job only needs to cover files that are never touched again.
- The working copy contains **only** versioned content. If a pull fails (e.g. an untracked file would be overwritten), the error lands in the log and the folder stays as-is until it is fixed.

### Disaster recovery (DR)

If the git host dies, the repo is still recoverable because the compose files are versioned and can be redeployed from any copy of the repository:

1. In Portainer, redeploy the affected stack from a reachable copy of the repo.
2. Set the same environment variables as before (`PATH_TO_CONTAINERS`, `PATH_TO_SECRETS`, etc.; DB credentials are read from the secret files under `$PATH_TO_SECRETS/<Service>/`).
3. Restore the data volumes (repos, DBs, uploads) from your backups — data is never in the repo.

> The `.env` / `global.env` files needed to deploy live on the machines and are never versioned. Back them up together with the data.

### 🚫 .gitignore

Sensitive files (`global.env`, `.env`, databases and configuration folders) are excluded to protect your information.

### 🔒 Configuration: no personal data in env vars

**No personal data lives in environment variables.** Env vars are used only when strictly necessary (paths, UIDs, ports) and always through `${VAR}` placeholders that you fill locally. Anything personal (domains, URLs, usernames, credentials) is provided as a **Docker secret** and read with the app's file-variable syntax (`VAR__FILE=/run/secrets/<name>` for Forgejo-style apps, `VAR_FILE` for Vaultwarden). `.env.example` files contain placeholders only (`<domain>`, `example.com`, `/path/to/...`); real values never enter the repo.

## ⚖️ License

This repository is licensed under the [MIT License](LICENSE). © 2026 Akuilera. You may use, copy, modify and redistribute it with attribution; the software is provided "as is", without warranty of any kind.

## 📖 About

This setup was inspired by and adapted from the repository [James's Garage](https://github.com/JamesTurland/JimsGarage) and the [Compucenter33 tutorials](https://www.youtube.com/watch?v=l1pKEIPZNoM&t=1696s), complemented with resources found along the way.
