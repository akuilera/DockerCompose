# Security

Security-related services and the shared secrets tooling for the homelab.

## Services

| Folder              | Service                            | Notes                                                                 |
|---------------------|------------------------------------|-----------------------------------------------------------------------|
| `Vaultwarden/`      | Vaultwarden                        | Canonical password manager (Bitwarden-compatible). Secrets-based, MariaDB backend. See its [README](Vaultwarden/README.md). |
| `Password Manager/` | Vaultwarden (legacy)               | Older compose that read `DOMAIN` from a local `.env`; superseded by `Vaultwarden/`. |
| `GoAccess/`         | GoAccess                           | Real-time web log analyzer for NGINX Proxy Manager (NPM data volume).  |
| `FindMyDevice/`     | FMD server                         | Self-hosted FindMyDevice server.                                      |
| `ClamAV/`           | ClamAV daemon (`clamd`)            | Scans files streamed by containers (Nextcloud `files_antivirus`). No published ports; joins all shared networks. See its [README](ClamAV/README.md). |
| `init-secrets.sh`   | Secrets bootstrap script           | Creates the per-service secret files used by the services above.      |

## Secrets model

Sensitive values are never placed in `environment:` blocks. Instead:

1. Each secret is a file under `$PATH_TO_SECRETS/<Service>/`.
2. Compose mounts it at `/run/secrets/<name>`.
3. The service reads it through a `*_FILE` variable (e.g. `ADMIN_TOKEN_FILE`).

Values therefore do not appear in `docker inspect` output or in
`/proc/<pid>/environ`.

### Incident: top-level secrets do not grant access

Compose secrets are not a "defined at the root, visible to every service"
mechanism. A `secrets:` block at the top of the file only **defines** the
secret; each service must also **request** it:

```yaml
secrets:                 # defines the secret (top level)
  db_mysql_password:
    file: "${PATH_TO_SECRETS}/SomeService/db_mysql_password"

services:
  app:
    secrets:             # grants it to THIS service (per-service)
      - db_mysql_password
```

If the per-service `secrets:` entry is missing, `docker compose` **deploys
without error** but the file is never mounted at `/run/secrets/`. The service
falls back to its default/empty value, which on a service that has been
running for months looks like a factory reset (this is how NPM showed the
first-run "create admin" screen while its data was intact — see
`Network/NGINX-Proxy-Manager/README.md`).

Before deploying any secrets-based compose, check all three:

- every secret consumed by a service is listed under that service's
  `secrets:` block;
- the top-level `secrets:` file paths exist on the host under
  `$PATH_TO_SECRETS/...`;
- the service actually reads the mounted file (a `*_FILE` env var, or a
  bootstrap script like NPM's `60-secrets.sh`).

## init-secrets.sh

Creates the secret files for a service. Usage:

```bash
./init-secrets.sh [options] <Service> <secret1> [secret2 ...]
./init-secrets.sh --update-database <Service>
```

Secret types:

- `<name>` — plain value, pasted silently.
- `<name>@mysql` — builds a `mysql://user:pass@host:port/db` URL; defaults are
  derived from the service name (`<service>_user`, `<service>_db`, host
  `mariadb`, port `3306`). User and password are percent-encoded, so any
  characters are safe.
- `@db` — full DB credential set for a service. Prompts for DB name (default
  `<service>_db`), DB user (default `<service>_user`) and DB password (twice),
  then writes four files: `db_mysql_name`, `db_mysql_user`,
  `db_mysql_password` (the raw value a compose `*_FILE` reads) and
  `db_mysql_url` (generated URL, for services that consume a connection URL).

Options:

- `--force` — recreate existing files without asking.
- `--update-database <Service>` — apply the `db_mysql_*` files stored by `@db`
  to MariaDB via `Database/sync-db-users.sh` (grants: `ALL PRIVILEGES`). Reads
  the files, asks nothing, never puts the password on the command line.
- `--dry-run` — with `--update-database`, only print the SQL that would run.

Behavior:

- Values are never printed; files are written without a trailing newline with
  mode `600`; directories are `700`.
- Existing files ask "Recreate?" unless `--force` is given.
- `PATH_TO_SECRETS` is resolved from (1) the environment, (2)
  `../global.env` (repo root, git-ignored), (3) `~/.secrets`.

Examples:

```bash
./init-secrets.sh Vaultwarden admin_token db_url@mysql domain
./init-secrets.sh NginxProxyManager @db
./init-secrets.sh --update-database --dry-run NginxProxyManager
```

## Rotating a database password

`@db` only writes files; it never touches MariaDB by itself. To apply or
rotate a user, run `--update-database`, which executes the plain
`ALTER USER ... IDENTIFIED BY` through `Database/sync-db-users.sh`. MariaDB
has no dual-password (`RETAIN CURRENT PASSWORD` is MySQL 8 only), so the
change is immediate. Flow:

1. Write the **new** value: `./init-secrets.sh <Service> @db` (recreate the
   `db_mysql_*` files, keeping the DB name and user as-is).
2. Apply it to MariaDB: `./init-secrets.sh --update-database <Service>`
   (or `Database/sync-db-users.sh <Service> db_mysql_password <db> <user> "ALL PRIVILEGES"`).
3. Recreate the container so it reads the new secret
   (`docker compose up -d --force-recreate`, or Update in Portainer).
4. Verify the application works with the new value.

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
