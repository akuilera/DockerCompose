# Database

MariaDB, Redis and the tooling for the DB users/passwords.

## Services

| Folder          | Service                            | Notes                                                                 |
|-----------------|------------------------------------|-----------------------------------------------------------------------|
| `MariaDB/`      | MariaDB                            | Central database. Reads `MYSQL_ROOT_PASSWORD_FILE` from a Docker secret. |
| `Redis/`        | Redis                              | Shared in-memory store for Nextcloud (locks/cache) and Borg-UI (scheduler). |
| `sync-db.sh` | DB user rotation script          | Creates/updates databases and users. Additive and idempotent.         |

See `Redis/README.md` for the shared Redis (consumers, persistent volume, deploy order).

## sync-db.sh

Creates a database and user if they do not exist and sets the password. MariaDB (like MySQL 8's predecessor, but unlike MySQL 8's dual-password) has **no** `RETAIN CURRENT PASSWORD`: the moment `ALTER USER ... IDENTIFIED BY` runs, the old password stops working. The script is additive and idempotent: it never drops a database or a user, and re-running it with the same password is a no-op.

Usage:

```bash
./sync-db.sh [options] <Service> <secret_name> <db> <user> [grants]
```

- `<Service>` — name under `$PATH_TO_SECRETS` (the service's secret directory).
- `<secret_name>` — file holding the raw password; read directly by the script (unless `--password-file` is given), so the password never appears on the command line.
- `<db>`, `<user>`, `[grants]` (default `ALL PRIVILEGES`).

Options:

- `--dry-run` — print the SQL that would be sent, send nothing.
- `--db/--user/--host/--grants` — override the positional values.
- `--password-file <path>` — read the password from this file instead of `$PATH_TO_SECRETS/<Service>/<secret_name>`.
- `-v` — verbose; print the SQL being executed.

Environment:

- `PATH_TO_SECRETS` — base directory for secret files (resolved like `init-secrets.sh`: env, `../global.env`, `~/.secrets`).
- `SECRET_PASSWORD` — if set, used as the password instead of reading a file (used by `init-secrets.sh` for `@mysql` secrets, where the file holds a URL).
- `DOCKER_CMD` — docker command, e.g. `sudo docker` (used unquoted, so it may contain spaces).
- `MARIADB_CONTAINER` — container name for `docker exec` (default `mariadb`).

### How it connects to MariaDB

1. Root is accessed through the container's unix socket: `docker exec -i <container> mariadb -uroot`. This requires no root password (`root@localhost` uses `unix_socket`; see below).
2. If that fails, it looks for `$PATH_TO_SECRETS/MariaDB/mysql_root_password` and passes it through stdin into a `bash -c 'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -uroot'` wrapper. The password never touches the environment of the outer shell, so `sudo` cannot strip it.
3. Before writing anything it verifies that the new password actually logs in over TCP (same stdin mechanism). It refuses to run if the login fails.

## Root access

`root@localhost` authenticates via `unix_socket`, so inside the container `docker exec ... mariadb -uroot` works with no password. This is the primary admin channel for the tooling above.

`root@'%'` (TCP, port 3306) authenticates via `mysql_native_password` with the password stored in the `MariaDB/mysql_root_password` secret.

### Root password rotation

The root secret is rotated with SQL (the image only reads `MYSQL_ROOT_PASSWORD_FILE` on first bootstrap):

1. Create the new secret: `./init-secrets.sh MariaDB mysql_root_password` (paste the new value; keep it in your password manager).
2. Apply it over the socket:

   ```bash
   docker exec mariadb mariadb -uroot \
     -e "ALTER USER 'root'@'%' IDENTIFIED BY '<new>'"
   ```

   (Read the password from the secret file; do not type it into the command line. There is no dual-password in MariaDB: from this moment the old value is dead.)
3. Recreate the container so the compose mounts the new secret file: Portainer Update, or `docker compose up -d --force-recreate`.
4. Verify over TCP:

   ```bash
   printf '%s\n' '<new>' | docker exec -i mariadb bash -c \
     'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -uroot -h127.0.0.1 -e "SELECT 1"'
   ```

   (`-p` interactively does not work well through `docker exec`; the password is forwarded via stdin so it never lands in the environment or `ps`.)
5. Rollback, if ever needed, reuses the same flow with the previous value.

### Bootstrap variables (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`)

The official MariaDB image only honors these (and `MYSQL_ROOT_PASSWORD`) on the **first** initialization of the data directory (`/var/lib/mysql`). On an existing datadir the entrypoint ignores them, so removing them from the compose is safe: nothing is dropped and no user is created. Databases and users are now managed explicitly through `sync-db.sh`, and every service reads its own credentials from its own `.env`/secrets.
