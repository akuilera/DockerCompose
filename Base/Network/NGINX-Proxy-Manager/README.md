# NGINX Proxy Manager — Homelab Reverse Proxy

Quick reference for the reverse proxy that maps hostnames to the Homelab services (Forgejo, NextCloud, Immich, ...) and terminates TLS/Let's Encrypt.

## Connection info

- **Container**: `nginx_proxy_manager`
- **Admin UI**: `http://<server>:81` (first-run default: `admin@example.com` / `changeme`)
- **Public ports**: `80` (HTTP), `443` (HTTPS), `81` (admin)
- **Networks**: `proxy-net`, `db-net`, `nextcloud-net`, `immich-net`, `apps-net`

## Dependency: MariaDB

NPM uses **MariaDB** as its backend database (`DB_MYSQL_HOST: mariadb` on `db-net`), so MariaDB must be running before NPM starts.

It is part of the chicken-and-egg bootstrap: Forgejo is only reachable by URL through this proxy, and this proxy needs MariaDB. On a cold start: MariaDB → ZeroTier + NPM → Forgejo and the rest (see the repo root README → Boot order).

## Secrets

The DB credentials are read from files, not from the environment:

| Compose env var        | Secret file                                        |
|------------------------|----------------------------------------------------|
| `DB_MYSQL_USER__FILE`  | `$PATH_TO_SECRETS/NginxProxyManager/db_mysql_user` |
| `DB_MYSQL_PASSWORD__FILE` | `$PATH_TO_SECRETS/NginxProxyManager/db_mysql_password` |
| `DB_MYSQL_NAME__FILE`  | `$PATH_TO_SECRETS/NginxProxyManager/db_mysql_name` |

NPM supports `__FILE` for any environment variable: the image's `60-secrets.sh` script reads each `*__FILE` path, strips the suffix and exports the file's content as the plain variable, so `DB_MYSQL_*` never appear in plaintext in the container environment.

Create the secret files (a single `@db` call writes all four `db_mysql_*` files; `--update-database` also applies the user to MariaDB when you are ready):

```bash
./Security/init-secrets.sh NginxProxyManager @db
./Security/init-secrets.sh --update-database NginxProxyManager   # optional, applies to MariaDB
```

After recreating the container, verify the DB user logs in with the secret value and the admin UI loads on `:81`.

## Incident: "create admin" on first screen while data was intact

The compose declared `db_mysql_*` at the top level but never granted them to the service (no `secrets:` entry under `nginx_proxy_manager`). Compose deployed without error, the files were never mounted at `/run/secrets/`, and NPM fell back to its default SQLite database — the UI showed the first-run "create admin" screen. The proxy hosts kept working because their `.conf` files were already persisted under `/data/nginx/proxy_host/`. The fix was the per-service grant (commit `ece0647`):

```yaml
    secrets:
      - db_mysql_user
      - db_mysql_password
      - db_mysql_name
```

The general lesson (top-level secrets do not grant access) lives in `Security/README.md`.

## Redeploying NPM safely

**Do not redeploy NPM from a URL served by NPM itself.** The proxy config (hosts, TLS, networks) lives on this container, and the redeploy takes it down mid-request — it would kill the very connection you are using. Reach Portainer (or the node) through a surface NPM does not serve: `http://<server>:9000`, or the LAN/ZeroTier IP, and update the stack from there.

The same rule applies to any service you manage through Portainer while Portainer is reached via the NPM proxy. Forgejo's own redeploy is safe to do from its URL because its control plane (Portainer) is independent of Forgejo; NPM is only its front end.

## Forgejo behind NPM: custom location `/`

Forgejo must be served with a **custom location `/`** in its Proxy Host. By default NPM adds a proxy location with a redirect to `/` (a 301 to the base path) which breaks Forgejo when the app already expects to serve the whole tree under that path. Configuring `location /` (forwarding everything, with websockets enabled) keeps the app's own routing intact and matches the `FORGEJO__server__ROOT_URL` set in the compose.

## Forward target: service name vs IP

The "Forward Hostname / IP" of a Proxy Host is resolved by nginx **at reload time, from inside the NPM container**, using Docker's embedded DNS (127.0.0.11), which only knows containers on the **same user-defined network(s)** as NPM.

- **Service name** (e.g. `collabora`): resolves only if the target shares one of NPM's networks (`proxy-net`, `db-net`, `nextcloud-net`, `immich-net`, `apps-net`). Prefer it whenever possible — it survives container recreates, so redeploying the target never breaks the proxy.
- **IP** (e.g. from `docker inspect`): needs no DNS and works from any network, but bridge IPs are **dynamic**; every recreate can change the address and silently break the proxy (502). Only for targets NPM cannot reach by name (other networks, host services, static IPs).

How to decide from the repo: compare the target's `networks:` in its compose with NPM's list above. Intersection → use the service name. Otherwise join the target to a network NPM shares, or point the proxy at a published port on the host. Confirm from the server: `docker exec nginx_proxy_manager getent hosts <service>`.

Example: the Collabora Proxy Host pointed at its old container IP; after switching to `collabora` it resolves to its `nextcloud-net` address and stays valid across recreates.

> nginx caches upstream IPs until the next reload. If a name-based target is recreated and a proxy 502s, save/reload the Proxy Host in NPM.
