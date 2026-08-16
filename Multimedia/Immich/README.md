# Immich

Self-hosted photo and video backup with AI-powered search (face detection, scene tags) via a local machine-learning model. Deployed as its own stack, completely isolated on `immich-net`.

## Services

| Folder | Service | Notes |
|--------|---------|-------|
| `Immich/` | Immich | Web UI, API and background jobs (`immich_server`) |

Companion containers of the stack (all on `immich-net`):

| Container | Image | Purpose |
|-----------|-------|---------|
| `immich_server` | `immich-server` | Web UI/API (`:2283`) |
| `immich_machine_learning` | `immich-machine-learning` | AI search / face detection |
| `immich_redis` | `valkey:9` (digest) | Cache + job queues. Bundled from the official template; deliberately **not** the shared Redis in `Base/Database/Redis/` (keeps Immich isolated) |
| `immich_postgres` | `postgres:14` vectorchord fork (digest) | Immich requires **PostgreSQL** — MariaDB is not supported |

## Connection info

- **Web UI**: `http://<server>:2283` (LAN).
- **Network**: `immich-net` (private, external). NGINX Proxy Manager joins it, so a proxy host can target `immich_server:2283` for the LAN/ZeroTier hosts if wanted. Immich is private by design — no Cloudflare tunnel.
- **Auth**: admin account created on first run (not a secret file).

## Secrets

Database password as a Docker secret (see `Security/README.md`):

```bash
./Security/init-secrets.sh Immich db_password
```

- `db_password` → `$PATH_TO_SECRETS/Immich/db_password`, consumed by both the server (`DB_PASSWORD_FILE`) and postgres (`POSTGRES_PASSWORD_FILE`).
- A **fresh** database is created on first start. The old `${PATH_TO_CONTAINERS}/Immich/postgresql/` folder from the previous attempt is unused — do not delete it until the new install is verified.

## Data layout

| Host | Container | Purpose |
|------|-----------|---------|
| `${PATH_TO_CLOUD_DATA}/immich_data` | `/data` | User uploads / photo library |
| `${PATH_TO_CONTAINERS}/Immich/postgres` | `/var/lib/postgresql/data` | PostgreSQL data (fresh) |
| `${PATH_TO_CONTAINERS}/Immich/model-cache` | `/cache` | ML models (reused from the old setup) |
| `${IMAGES_PATH}` | `/mnt_img` (ro) | Optional external media library |
| `${VIDEOS_PATH}` | `/mnt_vid` (ro) | Optional external media library |

> The database lives on a **local** disk (`${PATH_TO_CONTAINERS}/Immich/postgres`); network shares are not supported for it.

## Permissions

Since Immich v2 the containers run as **non-root (uid 1000)**. The library and ML cache folders must be writable by that uid:

```bash
sudo chown -R 1000:1000 "${PATH_TO_CLOUD_DATA}/immich_data"
sudo chown -R 1000:1000 "${PATH_TO_CONTAINERS}/Immich/model-cache"
```

The postgres folder is created and owned by the container on first start — do not pre-create it.

## Deploy

1. `cp .env.example .env` and fill the placeholders (`PATH_TO_*`, `IMAGES_PATH`, `VIDEOS_PATH`).
2. Create the secret (above).
3. Ensure `immich-net` exists (created once — see root `README.md`).
4. Deploy as a **Portainer Repository stack** from `Multimedia/Immich/docker-compose.yml`, setting the same variables in the stack environment (no `stack.env` file; variables are read straight from the stack env).
5. First start: open the web UI and create the admin account.
6. Optional: Admin → External Libraries → add `/mnt_img` and `/mnt_vid`.

## Update

Immich is versioned via `IMMICH_VERSION` (default: `release`). Both `immich_server` and `immich_machine_learning` use the same tag and must stay in sync.

1. Bump `IMMICH_VERSION` (or pin the target tag) in the stack environment.
2. In Portainer, open the stack → **Update**.

The `immich_postgres` and `immich_redis` images are pinned by digest; they only change when an Immich upgrade requires it (see the release notes).
