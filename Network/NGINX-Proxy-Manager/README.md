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
