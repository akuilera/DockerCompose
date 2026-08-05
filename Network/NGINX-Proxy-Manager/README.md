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

NPM supports `__FILE` for any environment variable: the image's
`60-secrets.sh` script reads each `*__FILE` path, strips the suffix and exports
the file's content as the plain variable, so `DB_MYSQL_*` never appear in
plaintext in the container environment.

Create the secret files (user/name are plain values; password is the raw DB
password, and answering `y` at the prompt also applies it to MariaDB):

```bash
./init-secrets.sh NginxProxyManager db_mysql_user db_mysql_password@db db_mysql_name
```

After recreating the container, verify the DB user logs in with the secret
value and the admin UI loads on `:81`.
