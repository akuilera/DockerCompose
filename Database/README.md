# Database

MariaDB (and the tooling for its users/passwords).

## Services

| Folder          | Service                            | Notes                                                                 |
|-----------------|------------------------------------|-----------------------------------------------------------------------|
| `MariaDB/`      | MariaDB                            | Central database. Will move to `MYSQL_ROOT_PASSWORD_FILE`.            |
| `sync-db-users.sh` | DB user rotation script         | Creates/updates databases and users with dual-password (no lockout).  |
| `tests/`        | Test suite                         | Runs `sync-db-users.sh` and `init-secrets.sh` against a mock `docker`.|

## sync-db-users.sh

Creates a database and user if they do not exist and sets the password, always
with `RETAIN CURRENT PASSWORD` so both the old and the new password work until
the rotation is finalized. It is additive and idempotent: it never drops a
database or a user, and re-running it with the same password is a no-op.

Usage:

```bash
./sync-db-users.sh [options] <Service> <secret_name> <db> <user> [grants]
```

- `<Service>` — name under `$PATH_TO_SECRETS` (the service's secret directory).
- `<secret_name>` — file holding the raw password; read directly by the script
  (unless `--password-file` is given), so the password never appears on the
  command line.
- `<db>`, `<user>`, `[grants]` (default `ALL PRIVILEGES`).

Options:

- `--discard-old` — finalize a rotation: `ALTER USER ... DISCARD OLD PASSWORD`.
  Revokes the previous password once every container has been recreated and the
  application verified. Omits `GRANT`/`FLUSH` unless `--grants` is also given.
- `--dry-run` — print the SQL that would be sent, send nothing.
- `--db/--user/--host/--grants` — override the positional values.
- `--password-file <path>` — read the password from this file instead of
  `$PATH_TO_SECRETS/<Service>/<secret_name>`.
- `-v` — verbose; print the SQL being executed.

Environment:

- `PATH_TO_SECRETS` — base directory for secret files (resolved like
  `init-secrets.sh`: env, `../global.env`, `~/.secrets`).
- `SECRET_PASSWORD` — if set, used as the password instead of reading a file
  (used by `init-secrets.sh` for `@mysql` secrets, where the file holds a URL).
- `DOCKER_CMD` — docker command, e.g. `sudo docker` (used unquoted, so it may
  contain spaces).
- `MARIADB_CONTAINER` — container name for `docker exec` (default `mariadb`).

### How it connects to MariaDB

1. Root is accessed through the container's unix socket:
   `docker exec -i <container> mariadb -uroot`. This requires no root password.
2. If that fails, it looks for `$PATH_TO_SECRETS/MariaDB/mysql_root_password`
   and uses it via `MYSQL_PWD` inside `docker exec`. The password is forwarded
   with `-e MYSQL_PWD`, never on the command line.
3. Before writing anything it verifies that the new password actually logs in:
   `docker exec -e MYSQL_PWD mariadb -u<user> ...`. It refuses to run if the
   login fails (the dual-password scheme guarantees both old and new work).

### Verification and tests

`tests/mock-docker.sh` is a fake `docker` used by the test suites; it records
the invocations it received (`MOCK_LOGFILE`), captures SQL sent on stdin
(`MOCK_STDIN_FILE`) and lets tests fake failures (`MOCK_FAIL_SELECT1`,
`MOCK_USER_COUNT`).

```bash
./tests/test-sync-db-users.sh
./tests/test-init-secrets.sh
```

Both suites exit non-zero on any failure. Run them after touching the scripts;
Docker is not required (only `bash` and standard coreutils).

## Root password rotation (dual password)

1. Create the new root secret: `./init-secrets.sh MariaDB mysql_root_password`.
2. Apply it with both passwords valid:

   ```bash
   docker exec mariadb mariadb -uroot \
     -e "ALTER USER 'root'@'%' IDENTIFIED BY '<new>' RETAIN CURRENT PASSWORD"
   ```

   (The password above comes from the secret file; keep it only in your
   password manager.)
3. Move `MariaDB/` to `MYSQL_ROOT_PASSWORD_FILE` and recreate the container so
   it reads the new secret.
4. Once every service has been recreated and verified, revoke the old password:

   ```bash
   docker exec mariadb mariadb -uroot \
     -e "ALTER USER 'root'@'%' DISCARD OLD PASSWORD"
   ```
