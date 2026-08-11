# Vaultwarden

Bitwarden-compatible password manager (unofficial). Serves the web vault and API behind NGINX Proxy Manager and stores its data in MariaDB.

## Architecture

- All secrets are provided as **Docker secrets** and read through `*_FILE` environment variables. They never enter the container environment, so they are not visible via `docker inspect` or `/proc/<pid>/environ`.
- The reverse proxy (`proxy-net`) exposes the service on `https://<domain>`; the MariaDB connection goes over `db-net`.

## Secrets

The compose expects three secret files under `$PATH_TO_SECRETS/Vaultwarden/`:

| Secret file   | Value                                          | Used for            |
|---------------|------------------------------------------------|---------------------|
| `admin_token` | Admin panel password (plain or Argon2 PHC)     | `ADMIN_TOKEN_FILE`  |
| `db_url`      | Full MySQL URL `mysql://user:pass@host:port/db`| `DATABASE_URL_FILE` |
| `domain`      | Public URL, e.g. `https://vaultwarden.example.com` | `DOMAIN_FILE`   |

## Creating the secrets

Run the shared script from the `Security/` directory:

```bash
./init-secrets.sh Vaultwarden admin_token db_url@mysql domain
```

- `admin_token`: paste the value (read silently).
- `db_url@mysql`: prompts with defaults derived from the service name (`vaultwarden_user`, `vaultwarden_db`, host `mariadb`, port `3306`); only the DB password must be typed. User and password are percent-encoded in the URL, so any characters are allowed. The MariaDB `CREATE USER` must use the **raw** password.
- `domain`: paste the full URL, e.g. `https://vaultwarden.example.com`.

Answer `n` to "Recreate?" to keep existing values, `y` to replace them, or use `--force` to recreate everything without asking.

## One-time MariaDB setup

On the MariaDB server, create the database and user matching the values given to the script:

```sql
CREATE DATABASE vaultwarden_db;
CREATE USER 'vaultwarden_user'@'%' IDENTIFIED BY '<raw password>';
GRANT ALL PRIVILEGES ON vaultwarden_db.* TO 'vaultwarden_user'@'%';
FLUSH PRIVILEGES;
```

## Deploy / redeploy

```bash
docker compose up -d
```

After changing a secret file, force a recreate — secret file changes do not change the compose hash:

```bash
docker compose up -d --force-recreate
```

## Verification

```bash
docker inspect --format '{{.State.Health.Status}}' vaultwarden   # healthy
docker exec vaultwarden curl -s http://localhost/alive           # timestamp JSON
docker exec -it <mariadb> mariadb -u vaultwarden_user -p vaultwarden_db -e "SHOW TABLES;"
```

## Notes

- `SIGNUPS_ALLOWED: "false"`: new users are created from the admin panel (`/admin` → Users → Invite user) even with registration disabled.
- The `[NOTICE] ... plain text ADMIN_TOKEN` startup warning disappears once the admin token is stored as an Argon2 PHC string (see below).
- Keep the admin token in your password manager. If it is a PHC string, the password used to generate it is what logs you into `/admin`.

## Securing the admin token (optional)

```bash
docker exec -it vaultwarden /vaultwarden hash
# paste the generated $argon2id$... PHC string as the new admin_token:
./init-secrets.sh Vaultwarden admin_token   # answer y to recreate
docker compose up -d --force-recreate
```
