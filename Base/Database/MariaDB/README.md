# MariaDB — Homelab Database Service

Quick reference for managing the MariaDB instance of the Homelab (used by Forgejo, NextCloud, etc.). Run the queries below from a client such as DBeaver, or from inside the container:

```bash
docker exec -it mariadb mariadb -uroot
```

## Connection info

- **Container**: `mariadb`
- **Network**: `db-net` (bridge)
- **Internal port**: `3306`
- **Host**: `mariadb` (service name, reachable from other containers on `db-net`)
- **Root (local)**: `root@localhost`, `unix_socket` plugin — no password inside the container.
- **Root (TCP)**: `root@'%'`, `mysql_native_password` — password stored in the `MariaDB/mysql_root_password` secret.

## Secrets

The compose mounts `$PATH_TO_SECRETS/MariaDB/mysql_root_password` at `/run/secrets/mysql_root_password` and reads it via `MYSQL_ROOT_PASSWORD_FILE`. The image only applies that value on the **first** bootstrap of the data directory; rotations are done with SQL (see "Change a user's password"). The other compose variables of the stock image (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`) are no longer used: on an existing data directory they are ignored by the entrypoint, so removing them changes nothing. Databases and users are managed explicitly with `Database/sync-db.sh`.

## Best practices

- **Applications must NOT use `root`**. Create one user per application, with grants only on that application's database.
- Always use `utf8mb4` and the `utf8mb4_bin` collation (case/accent sensitive) for new databases. Forgejo requires it: `utf8mb4_unicode_ci` is insensitive and can cause internal errors or unexpected results.
- Use strong passwords and keep them only in the secret files (never in the repo).

## Create a database and its user

```sql
CREATE DATABASE app CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'app_user'@'%' IDENTIFIED BY 'a_strong_password';
GRANT ALL PRIVILEGES ON app.* TO 'app_user'@'%';
FLUSH PRIVILEGES;
```

Replace `app`, `app_user` and `a_strong_password` with the real values. The `'%'` host allows connections from any host (containers on the bridge network).

## List databases and users

```sql
SHOW DATABASES;
SELECT User, Host FROM mysql.user;
```

## Change a user's password

```sql
ALTER USER 'app_user'@'%' IDENTIFIED BY 'a_new_password';
FLUSH PRIVILEGES;
```

> MariaDB has **no** dual-password (`RETAIN CURRENT PASSWORD` is MySQL 8 only): the old password stops working the moment this statement runs. Do this for a service only after its secret file already holds the new value, then recreate the container and verify the application.

Verify a password over TCP (interactive `-p` does not work through `docker exec`; the password is forwarded via stdin so it never lands in the environment or `ps`):

```bash
printf '%s\n' 'a_new_password' | docker exec -i mariadb bash -c \
  'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -uroot -h127.0.0.1 -e "SELECT 1"'
```

`SELECT 1` prints two `1` columns when run without `-N`; that is normal.

## List users, hosts and authentication

```sql
SELECT User, Host, plugin FROM mysql.user;
SHOW CREATE USER 'root'@'localhost';
SHOW CREATE USER 'root'@'%';
```

## Drop a database

```sql
DROP DATABASE IF EXISTS app;
```

## Drop a user

```sql
DROP USER IF EXISTS 'app_user'@'%';
DROP USER IF EXISTS 'app_user'@'localhost';
FLUSH PRIVILEGES;
```

> If the user is shared by several databases, drop only the database, not the user.

## Recreate the database for Forgejo

Forgejo uses a database named `forgejo`:

```sql
CREATE DATABASE forgejo CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
GRANT ALL PRIVILEGES ON forgejo.* TO '<user>'@'%';
FLUSH PRIVILEGES;
```

If the database was previously created with the wrong collation, fix it with:

```sql
ALTER DATABASE forgejo CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
```

## Boot order

MariaDB is the base of the whole Homelab: both **NGINX Proxy Manager** (its backend DB) and **Forgejo** depend on it. **Redis** (`Database/Redis/`, its own stack) is the other piece of the database layer: Nextcloud and Borg-UI use it. On a cold start (reboot, power loss, DR) these two must be up before the rest:

```bash
docker compose up -d   # Database/MariaDB/ + Database/Redis/  (these two, first)
docker compose up -d   # Network/ZeroTier/ + Network/NGINX-Proxy-Manager/
docker compose up -d   # Git/Forgejo/ and the rest
```

Part of the chicken-and-egg bootstrap: NPM is what makes Forgejo reachable by URL, and NPM does not start without this database.
