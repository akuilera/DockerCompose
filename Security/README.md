# Security

Security-related services and the shared secrets tooling for the homelab.

## Services

| Folder              | Service                            | Notes                                                                 |
|---------------------|------------------------------------|-----------------------------------------------------------------------|
| `Vaultwarden/`      | Vaultwarden                        | Canonical password manager (Bitwarden-compatible). Secrets-based, MariaDB backend. See its [README](Vaultwarden/README.md). |
| `Password Manager/` | Vaultwarden (legacy)               | Older compose that read `DOMAIN` from a local `.env`; superseded by `Vaultwarden/`. |
| `GoAccess/`         | GoAccess                           | Real-time web log analyzer for NGINX Proxy Manager (NPM data volume).  |
| `FindMyDevice/`     | FMD server                         | Self-hosted FindMyDevice server.                                      |
| `init-secrets.sh`   | Secrets bootstrap script           | Creates the per-service secret files used by the services above.      |

## Secrets model

Sensitive values are never placed in `environment:` blocks. Instead:

1. Each secret is a file under `$PATH_TO_SECRETS/<Service>/`.
2. Compose mounts it at `/run/secrets/<name>`.
3. The service reads it through a `*_FILE` variable (e.g. `ADMIN_TOKEN_FILE`).

Values therefore do not appear in `docker inspect` output or in
`/proc/<pid>/environ`.

## init-secrets.sh

Creates the secret files for a service. Usage:

```bash
./init-secrets.sh [--force] <Service> <secret1> [secret2 ...]
```

Secret types:

- `<name>` — plain value, pasted silently.
- `<name>@mysql` — builds a `mysql://user:pass@host:port/db` URL; defaults are
  derived from the service name (`<service>_user`, `<service>_db`, host
  `mariadb`, port `3306`). User and password are percent-encoded, so any
  characters are safe.
- `<name>@db` — raw database password, stored as-is (the value your compose
  `*_FILE` variable reads). Prompts for database, user, grants and password
  (twice). Defaults: `<service>_db`, `<service>_user`, `ALL PRIVILEGES`.

Behavior:

- Values are never printed; files are written without a trailing newline with
  mode `600`; directories are `700`.
- Existing files ask "Recreate?" unless `--force` is given.
- `PATH_TO_SECRETS` is resolved from (1) the environment, (2)
  `../global.env` (repo root, git-ignored), (3) `~/.secrets`.

Examples:

```bash
./init-secrets.sh Vaultwarden admin_token db_url@mysql domain
./init-secrets.sh NginxProxyManager db_mysql_password@db
```

## Rotating a database password

After writing an `@mysql` or `@db` secret, `init-secrets.sh` asks whether to
create/update the database and user in MariaDB (default No). Answering `y` runs
`Database/sync-db-users.sh`, which applies the new password with a plain
`ALTER USER ... IDENTIFIED BY`. MariaDB has no dual-password (`RETAIN CURRENT
PASSWORD` is MySQL 8 only): the change is immediate, so the flow is:

1. Write the **new** value to the secret file first
   (`./init-secrets.sh <Service> <secret_name>@db`, answering `y` to apply it).
2. Recreate the container so it reads the new secret
   (`docker compose up -d --force-recreate`, or Update in Portainer).
3. Verify the application works with the new value.

Keep the rotation window short: between the `ALTER` and the recreation the
running container still holds the old value in memory and keeps working, but
anything that reconnects with the old value after the `ALTER` will fail. The
script never drops databases or users; it is additive and idempotent.

The root password rotation follows the same pattern (plain `ALTER USER
'root'@'%' IDENTIFIED BY ...` over the socket, then recreate). See
`Database/README.md`.

## Shared variables (global.env)

- `PATH_TO_SECRETS` — where secret files live (used by `init-secrets.sh` and
  by compose `secrets.file` entries).
- `PATH_TO_CONTAINERS` — base for persistent data volumes.
- `PATH_TO_DOCUMENTS` — base for user documents (FileBrowser / Samba).

## Caveats

- Secrets are only as safe as the host: anything that can read the filesystem
  or run with the container's privileges can read them.
- The MariaDB user/password used by Vaultwarden is shared with the SQL
  statements run by `Database/sync-db-users.sh`
  (`CREATE USER ... IDENTIFIED BY '<raw password>'`); keep the raw password
  only in your password manager.
- Do not add `env_file:` or `environment:` entries that point at secret files:
  `*_FILE` is what keeps secrets out of the environment.
