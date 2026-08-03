# MariaDB — Homelab Database Service

Quick reference for managing the MariaDB instance of the Homelab (used by Forgejo, NextCloud, etc.). Run the queries below from a client such as DBeaver, or from inside the container:

```bash
docker exec -it mariadb mariadb -u root -p
```

## Connection info

- **Container**: `mariadb`
- **Network**: `db-net` (bridge)
- **Internal port**: `3306`
- **Host**: `mariadb` (service name, reachable from other containers on `db-net`)

## Best practices

- **Applications must NOT use `root`**. Create one user per application, with grants only on that application's database.
- Always use `utf8mb4` and the `utf8mb4_bin` collation (case/accent sensitive) for new databases. Forgejo requires it: `utf8mb4_unicode_ci` is insensitive and can cause internal errors or unexpected results.
- Use strong passwords and keep them only in the `.env` files (never in the repo).

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

MariaDB is the base of the whole Homelab: both **NGINX Proxy Manager** (its backend DB) and **Forgejo** depend on it. On a cold start (reboot, power loss, DR) it must be the first service up:

```bash
docker compose up -d   # Database/MariaDB/  (this one, first)
docker compose up -d   # Network/ZeroTier/ + Network/NGINX-Proxy-Manager/
docker compose up -d   # Git/Forgejo/ and the rest
```

Part of the chicken-and-egg bootstrap: NPM is what makes Forgejo reachable by URL, and NPM does not start without this database.
