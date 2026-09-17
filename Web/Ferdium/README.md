# Ferdium Server (self-hosted)

A self-hosted [Ferdium](https://ferdium.org) server, deployed with Docker and exposed to the internet through a reverse proxy (NGINX Proxy Manager) with HTTPS. It replaces the official `api.ferdium.org` cloud with your own instance, so your Ferdium account and configuration (services, workspaces, recipes) stay under your control.

## What it stores

The server keeps the **account** and the **configuration** that the Ferdium client syncs — which services you have, their order, your workspaces and recipes. The conversations themselves live inside each web service (WhatsApp, Telegram, ...), not in Ferdium, so this server protects your "app desktop", not your chat history.

## Security model

- **No published ports.** The container joins two Docker networks only (`db-net`, `proxy-net`); nothing is exposed on the host. TLS is terminated by NGINX Proxy Manager, which forwards to `ferdium-server:3333`.
- **Secrets, not environment.** `APP_URL` and the database credentials are stored as Docker secrets (files under `$PATH_TO_SECRETS/Ferdium/`) and injected at startup by a small entrypoint wrapper, because ferdium-server (AdonisJS) has no built-in `*_FILE` support. They never appear in the compose file, `docker inspect` or `.env`.
- **Registration disabled by default.** See [Creating an account](#creating-an-account).
- **JWT keys auto-generated and persisted** on first run into the data volume (`DATA_DIR`), so clients keep working across container restarts.

## Prerequisites

- Docker + Docker Compose.
- An NGINX Proxy Manager stack joined to an external Docker network named `proxy-net` (this repo's homelab uses it; any reverse proxy on the same Docker network works).
- A MariaDB server joined to an external Docker network named `db-net`, reachable at host `mariadb`, port `3306`.
- The secrets helper from this repository: `Security/init-secrets.sh`.

## Installation

### 1. Create the data folders

```bash
mkdir -p "$PATH_TO_CONTAINERS/Ferdium/data" "$PATH_TO_CONTAINERS/Ferdium/recipes"
```

### 2. Create the secrets

`app_url` must be the **full public URL with scheme** — the same URL the client and NPM will use (e.g. `https://ferdium.example.com`). The `@db` type creates the database name, user and password files and stores them under `$PATH_TO_SECRETS/Ferdium/`:

```bash
cd Security
./init-secrets.sh Ferdium app_url @db
```

The script never prints the values; files are written with mode `600`.

### 3. Create the database and its user

Apply the stored credentials to MariaDB (creates the database/user and grants `ALL PRIVILEGES`):

```bash
./init-secrets.sh --update-database Ferdium
```

### 4. Configure the environment

Copy `.env.example` to `.env` and set the two variables (they are shared globally in this repo's `global.env`; list them here only if you deploy the stack standalone, e.g. in Portainer):

```bash
PATH_TO_CONTAINERS=/path/to/containers
PATH_TO_SECRETS=/path/to/secrets
```

### 5. Start the service

```bash
docker compose up -d
```

Check that it is healthy:

```bash
docker compose ps
docker compose logs -f ferdium-server   # recipe sync, migrations, then "server started"
curl http://localhost:3333/health        # inside the container: docker compose exec ferdium-server curl -sSf http://localhost:3333/health
```

## Reverse proxy (NGINX Proxy Manager)

Create a new **Proxy Host**:

- **Domain Names**: `ferdium.example.com` (your public subdomain).
- **Scheme**: `http`
- **Forward Hostname / IP**: `ferdium-server`
- **Forward Port**: `3333`
- **Block Common Exploits**: ON
- **Websockets Support**: ON (the client uses live connections).
- **Force SSL / HTTP/2**: ON.
- Under **SSL**, request a Let's Encrypt certificate for the subdomain and force HTTPS.

The service has no published host port, so NPM reaches it over the Docker network; it must be on the same `proxy-net` as `ferdium-server`.

## Creating an account

`IS_REGISTRATION_ENABLED` controls whether anyone can create an account on your server. On a public URL it must stay `false` — otherwise any stranger who finds the address can sign up and use your disk and CPU.

To create your account(s):

1. In `docker-compose.yml`, set `IS_REGISTRATION_ENABLED=true`.
2. Recreate the container: `docker compose up -d`.
3. Open `https://ferdium.example.com` and register. The 30 seconds this takes is the only window — repeat per device/account only if you ever need more.
4. Set `IS_REGISTRATION_ENABLED=false` again and recreate: `docker compose up -d`.

## Client setup

In the Ferdium app login screen choose **Custom server** and enter the full URL: `https://ferdium.example.com`. Sign in with the account created above.

## Backup

The data lives in `$PATH_TO_CONTAINERS/Ferdium/data` (SQLite-era db, plus the generated JWT/APP keys) and the compiled recipes in `.../Ferdium/recipes`. Back them up like any other homelab volume:

```bash
restic backup "$PATH_TO_CONTAINERS/Ferdium"
```

## Updating

```bash
docker compose pull ferdium-server
docker compose up -d
```

## Environment reference

Non-secret values are set in the compose file; `APP_URL`, `DB_DATABASE`, `DB_USER` and `DB_PASSWORD` come from secrets via the entrypoint wrapper.

| Variable | Value | Purpose |
| --- | --- | --- |
| `NODE_ENV` | `production` | Runs the app optimized for production (no debug mode). |
| `DB_CONNECTION` | `mysql` | Uses the MariaDB instance on `db-net`. |
| `DB_HOST` / `DB_PORT` | `mariadb` / `3306` | The database service. |
| `DB_SSL` | `false` | No TLS to the DB (LAN-only; keep it `true` for a cloud Postgres). |
| `DATA_DIR` | `/data` | Container path where the server keeps keys and runtime data. |
| `IS_CREATION_ENABLED` | `true` | Allows logged-in users to create custom recipes. |
| `IS_DASHBOARD_ENABLED` | `true` | Enables the user dashboard. |
| `IS_REGISTRATION_ENABLED` | `false` | Disables new signups; enable only while creating an account. |
| `CONNECT_WITH_FRANZ` | `false` | Keeps the Franz catalog/import disabled. |
| `JWT_USE_PEM` | `true` | Generates and persists the JWT key pair on first boot. |

## Gotchas

- **No SMTP configured** means no password recovery; normal login still works.
- The image **runs as root** and has no `*_FILE` env support — that is why the secrets are injected via the entrypoint wrapper (same approach as `Security/GoAccess`).
- Changing `IS_REGISTRATION_ENABLED` requires recreating the container (`docker compose up -d`).
- If you want your own JWT keys instead of the auto-generated ones, provide them before clients log in; keys are read from `DATA_DIR` on every start.

Reference: [ferdium/ferdium-server](https://github.com/ferdium/ferdium-server).