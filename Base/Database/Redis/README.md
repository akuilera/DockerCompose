# Redis

Standalone shared Redis (in-memory data store), deployed as its own stack.

## Services

| Folder    | Service | Notes |
|-----------|---------|-------|
| `Redis/`  | Redis   | Shared instance. Replaces the one that used to live inside the MariaDB stack. |

## What uses it

- **Nextcloud** (`Cloud/NextCloud/`) — file locking, transactional locking and the distributed cache. Reached as `redis` on `db-net`.
- **Borg-UI** (`BackUp/Borg/`) — job scheduler/queue. Reached as `redis` on `db-net`.

Both consumers are unchanged by the migration: they keep resolving the service as `redis` on `db-net` (the `container_name` was kept).

## Configuration

- **Container**: `redis` (`redis:7-alpine`).
- **Network**: `db-net` only (its consumers live there; least privilege). No published ports.
- **Persistent data**: `${PATH_TO_CONTAINERS}/Redis/data:/data` — Borg-UI stores its scheduled jobs here, so a persistent volume keeps them across recreates. The old in-stack instance had **no** volume and lost its data on every recreate.
- **Healthcheck**: `redis-cli ping`.
- No secrets, no env vars beyond `${PATH_TO_CONTAINERS}` (from `global.env`).

## Deploy

Deploy it as a **Portainer Repository stack** from this repo (`Base/Database/Redis/docker-compose.yml`), with `PATH_TO_CONTAINERS` set from `global.env`. It only needs the `db-net` network, which already exists.

> The container name `redis` collides with the instance that used to live in the MariaDB stack, so the two cannot run at once. Order: **update the MariaDB stack first** (drops the old `redis`), then deploy this stack. There is a brief DNS gap for `redis` on `db-net` — acceptable, it is a cache. After the migration, **re-create the scheduled jobs in Borg-UI** (the old instance had no volume, so its schedule is gone).

## Verify

```bash
docker exec redis redis-cli ping   # PONG
```
