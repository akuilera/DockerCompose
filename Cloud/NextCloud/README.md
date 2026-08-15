# NextCloud — File sync & cloud suite

Quick reference for the NextCloud instance (private cloud: files, calendars, contacts, deck, tasks, richdocuments, ...). Deployed from this repo as a Portainer repository stack; the compose file here is the single source of truth.

## Connection info

- **Container**: `nextcloud`
- **Image**: `nextcloud:latest`
- **Public port**: `8080` → `80` (behind NGINX Proxy Manager over HTTPS)
- **Networks**: `nextcloud-net`, `db-net` (MariaDB), shared Redis (`redis` — `Database/Redis/`, same network)
- **Web**: `https://<domain>/` (reverse-proxied)

## Mounts (persistent data)

| Host (via variable)                        | Container            | Purpose |
|--------------------------------------------|----------------------|---------|
| `${PATH_TO_CONTAINERS}/Nextcloud/apps`         | `/var/www/html/apps`       | Shipped apps (image code copy) |
| `${PATH_TO_CONTAINERS}/Nextcloud/config`       | `/var/www/html/config`     | `config.php` + app configs |
| `${PATH_TO_CONTAINERS}/Nextcloud/custom_apps`  | `/var/www/html/custom_apps`| App Store apps (calendar, contacts, deck, tasks, richdocuments, ...) |
| `${PATH_TO_CLOUD_DATA}/nextcloud_data`          | `/var/www/html/data`       | User files, databases of the instance |
| `${PATH_TO_CONTAINERS}/Nextcloud/nextcloud_html` | `/var/www/html`       | Core code (rsynced from the image at startup) |

The core `/var/www/html` lives in a **bind mount shared with the `nextcloud-cron` sidecar**. The image no longer bakes the app code into `/var/www/html`; the entrypoint rsyncs it from `/usr/src/nextcloud` at every start (with the sub-mounts above shadowing the subdirectories). The sidecar skips that entrypoint (it only runs `crond`), so without the shared mount it would have no `cron.php` — see [Troubleshooting](#troubleshooting).

## Secrets

The DB credentials are read from files, not from the environment. Compose mounts them via `secrets:` under the service:

| Compose env var        | Secret file                                   |
|------------------------|-----------------------------------------------|
| `MYSQL_DATABASE_FILE`  | `${PATH_TO_SECRETS}/NextCloud/db_mysql_name`   |
| `MYSQL_USER_FILE`      | `${PATH_TO_SECRETS}/NextCloud/db_mysql_user`   |
| `MYSQL_PASSWORD_FILE`  | `${PATH_TO_SECRETS}/NextCloud/db_mysql_password` |

Create the secret files (a single `@db` call writes all four `db_mysql_*` files; `--update-database` applies the user to MariaDB when you are ready):

```bash
./Security/init-secrets.sh NextCloud @db
./Security/init-secrets.sh --update-database NextCloud   # optional, applies to MariaDB
```

> **Keep the same DB name and user.** The script only does `ALTER USER ... IDENTIFIED BY`; it does not create users. Use the same `dbname` / `dbuser` that are already in `config.php`.

### Rotation is not enough: `config.php` must change too

`MYSQL_*_FILE` is consumed **only on the first install**. A running instance reads `config/config.php`. So after `--update-database NextCloud` (which rotates the MariaDB password **immediately**), the old password stops working for everything — including the web UI and `occ`.

The rotation window is seconds. Order matters:

1. `./Security/init-secrets.sh NextCloud @db`
2. `./Security/init-secrets.sh --update-database NextCloud`
3. **Right after**, update `dbpassword` (and `dbname` / `dbuser` if they changed) in `config.php`.
4. Redeploy the stack in Portainer (make sure `PATH_TO_SECRETS` is set on the stack).
5. Verify: `docker exec nextcloud cat /run/secrets/db_mysql_password`, login, data intact.

`config.php` lives at **`${PATH_TO_CONTAINERS}/Nextcloud/config/config.php`** (inside the container: `/var/www/html/config/config.php`). Prefer editing it with `sudo nano <that path>`; `occ config:system:set dbpassword` may fail when the DB already rejects the old password during `occ` startup. When editing by hand, keep `dbname` / `dbuser` unchanged and never commit this file.

After rotating, check MariaDB for a leftover `@'localhost'` account still using the old password:

```bash
docker exec mariadb mariadb -uroot -e "SELECT User, Host, plugin FROM mysql.user WHERE User='<dbuser>';"
```

If `@'localhost'` exists, drop it (or rotate it too).

## Updating NextCloud

NextCloud runs on `nextcloud:latest`; updates are manual (no auto-updater, see repo rules).

1. Edit the compose here, commit and push.
2. In Portainer, open the **NextCloud** stack → **Update** (pull + recreate).
3. On recreate the entrypoint rsyncs the new code into `/var/www/html` and **auto-runs `occ upgrade` when the jump is within one major version** — usually nothing to do.
4. If you instead see "Se necesita actualización" (the browser updater is disabled in `config.php`), run it from the CLI:
   ```bash
   sudo docker exec -u www-data nextcloud php occ upgrade --no-interaction
   sudo docker exec -u www-data nextcloud php occ maintenance:mode --off   # only if it stays in maintenance mode
   sudo docker exec -u www-data nextcloud php occ status                  # verify needsDbUpgrade: false
   ```
5. **Only one major version per update.** If the container refuses to start with *"upgrading from X to Y is not supported ... only possible to upgrade one major version at a time"*, pin the compose image to the intermediate major (e.g. `nextcloud:33`), Portainer Update, run `occ upgrade`, then revert to `nextcloud:latest` and repeat.
6. After a major upgrade, some migrations run as **background jobs**; the cron sidecar finishes them within ~5 min, then re-check the setup warnings.

> **First start after creating the `nextcloud_html` bind.** If `/var/www/html` is empty, the entrypoint treats it as a *new install*: it rsyncs the code but does **not** run `occ upgrade`, so NextCloud shows the "Se necesita actualización" page until you run `occ upgrade` manually (step 4). This only happens the first time; once `version.php` exists, updates are automatic (within one major).

The recreate re-runs the entrypoint rsync, which refreshes `/var/www/html` from the image code; every bind (data, apps, config, custom_apps, nextcloud_html) survives.

## Accounts & registration

**Nobody can self-register by default.** Account creation is admin-only (Administration → Users → "New user"); there is no public registration form. Combined with the no-inbound-ports setup, unknown users cannot reach or join this instance.

If a future instance ever needs public sign-up, the **Registration** app (App Store) enables it: the admin turns it on, users sign up with email verification, land in a default group, and **accounts stay pending until the admin approves them**. Nothing to configure on this instance today.

## Two-factor authentication

Done from the GUI (no `occ` needed), in this safe order so you never lock yourself out:

1. Apps → Security → install **Two-Factor TOTP Provider** (Backup Codes usually ships enabled by default).
2. Personal settings → Security → set up TOTP (scan the QR, save the secret).
3. Personal settings → Security → **generate backup codes** and store them (e.g. in the password manager).
4. Only then: Administration → Security → enable **"Enforce two-factor authentication"**.

If you ever get locked out of the web UI, recover from the server (no browser needed):

```bash
sudo docker exec -u www-data nextcloud php occ twofactorauth:disable <user> <provider>   # e.g. ... <user> totp
```

Other providers in the store: WebAuthn (hardware key), Two-Factor email, Two-Factor via Nextcloud notification.

## Collabora (Office)

- Client app: `richdocuments` (in `custom_apps`).
- Document server: either `richdocumentscode` (built-in CODE, also in `custom_apps`) or the standalone **Collabora** service (`Cloud/Collabora/` in this repo).
- Collabora does **not** support `*_FILE` secrets; it is configured entirely via plain env vars on the stack:
  - `COLLABORA_DOMAIN` = the **NextCloud** hostnames allowed to reach Collabora (the WOPI allowlist), regex-escaped and `|`-separated — **not** the Collabora hostname. Example: `nextcloud\.example\.com|nextcloud\.vpn\.example\.com`.
  - `COLLABORA_PASSWORD` = password of the Collabora admin console (user `admin`).
- No config file is mounted. The compose already forces TLS termination (`extra_params=--o:ssl.enable=false --o:ssl.termination=true`) and disables internal cert generation (`DONT_GEN_SSL_CERT=YES`).

### Reverse proxy (NPM)

The browser loads the editor inside an **https** NextCloud page, so the Collabora URL must also be **https** (otherwise the browser blocks it as mixed content). A wildcard Cloudflare tunnel `*.<suffix>.<domain>` already reaches NPM, which routes by service — so no tunnel route per service is needed, only an NPM proxy host per reachable hostname (`collabora.<suffix>.<domain>`, one per network path):

- Forward scheme: `http`, hostname: `collabora`, port: `9980` (same `nextcloud-net`).
- SSL: request a Let's Encrypt certificate.
- Advanced tab: **WebSockets support: ON** (the editor needs them).

Each NPM proxy host gives an independent Collabora entry point, so the editor and admin console are reachable via every network path you proxy (LAN, ZeroTier, WireGuard, ...). No per-hostname configuration is needed inside Collabora itself.

### Pointing NextCloud at it

- Admin settings → Office → "Use your own server": `https://collabora.<suffix>.<domain>` (the app derives `/hosting/discovery` from it). Pick the hostname whose network path is most reliable for your devices; the others still work independently.
- The built-in `richdocumentscode` can stay enabled; while "your own server" is selected, the external Collabora is the one used.
- Security: also set the **Allow list for WOPI requests** in the same settings page to the **source IP that Nextcloud sees on WOPI callbacks** — not the IPs of the machine running Collabora. Because Collabora calls Nextcloud through its public URL (via NPM + the published port), the requests arrive from the **Docker host bridge gateway**, not from Collabora's container IP on `nextcloud-net`. If a document fails with "Unauthorized WOPI host", find the denied source and set it (or its CIDR):
  ```bash
  docker logs nextcloud | grep -i "WOPI request denied"
  sudo docker exec -u www-data nextcloud php occ config:app:get richdocuments wopi_allowlist
  sudo docker exec -u www-data nextcloud php occ config:app:set richdocuments wopi_allowlist --value='<cidr-from-the-log>'
  ```
  Without it Nextcloud warns and lets any WOPI endpoint request files.

### Verify

```bash
# From the LAN / your browser's network
curl -k https://collabora.<suffix>.<domain>/hosting/discovery

# WOPI callback: NextCloud must reach Collabora, and vice versa. The Collabora
# image is distroless (no shell/curl), so test from the NextCloud container:
docker exec -u www-data nextcloud curl -s http://collabora:9980/hosting/discovery | head -c 200
```

The definitive test is opening a document in NextCloud, editing and saving it, then watching `docker logs collabora` for WOPI errors.

Admin console: `https://collabora.<suffix>.<domain>/browser/dist/admin/admin.html` (user `admin`, password = `COLLABORA_PASSWORD`).

> **Incident: mount at `/etc/coolwsd/` crash-loops.** Bind-mounting a directory over `/etc/coolwsd/` hides the image's default `coolwsd.xml`; the entrypoint does not regenerate it and the container restarts forever with `Failed to initialize COOLWSD: File not found: /etc/coolwsd/coolwsd.xml` (exit 78). Configure via env vars only; if a custom `coolwsd.xml` is ever needed, mount a **single file** (`coolwsd.xml:/etc/coolwsd/coolwsd.xml`) seeded from the image (`docker cp`).

## Incident: lost apps after an update

**Symptom.** After an image update + stack recreate, the App Store apps (calendar, contacts, deck, tasks, richdocuments, ...) vanished from the UI, and some requests failed with `RouteNotFoundException` ("Página no encontrada"). The apps menu could render empty.

**Why.** The app code lived in `/var/www/html/custom_apps`, inside the container's **anonymous volume**. When Docker recreates the container, it replaces the anonymous volume with a fresh copy from the image — the custom apps were gone from disk, and the DB entries (`enabled=yes` without `installed_version`) pointed at nothing.

**Recovery.**

1. The app code still existed in **older orphaned anonymous volumes** (from previous container runs). Located and listed them with:
  ```bash
    docker volume ls
    docker run --rm -v <volume-id>:/src:ro alpine sh -c 'ls /src/custom_apps/'
  ```
2. Copied the apps into a **new persistent bind** directory and fixed the owner (uid 33 = `www-data`):
  ```bash
    docker run --rm -v <volume-id>:/src:ro \
    -v "${PATH_TO_CONTAINERS}/Nextcloud/custom_apps":/dst alpine sh -c \
    'cp -a /src/custom_apps/. /dst/ && chown -R 33:33 /dst'
  ```
3. Added the bind to the compose (`custom_apps` line in Mounts) and did a Portainer **Update**. The recreate picked the apps up and registered them.
4. Verified registration:
  ```bash
    docker exec -u www-data nextcloud php occ app:list --shipped=false
  ```

**Lesson.** `custom_apps` (like anything not managed by the image) must be a **bind mount**, never an anonymous volume. The core `/var/www/html` is also a bind mount (`nextcloud_html`) because the cron sidecar must see it too. The fix is already applied in the compose file above.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Background jobs never run / "Last cron execution: unknown" | The cron sidecar had no `cron.php` (image no longer bakes the code into `/var/www/html`; the sidecar skips the entrypoint that rsyncs it). Fixed by sharing `${PATH_TO_CONTAINERS}/Nextcloud/nextcloud_html` as `/var/www/html` in both `nextcloud` and `nextcloud-cron`. Verify with `docker exec nextcloud-cron ls /var/www/html/cron.php` and `docker logs nextcloud-cron` after 5 min. |
| "Página no encontrada" in an app store app | App code not mounted (`custom_apps` bind empty) or not registered; run `occ app:list --shipped=false`, then `occ upgrade --no-interaction`. |
| DB connection errors after a password rotation | `config.php` still has the old password; update `dbpassword` (see [Secrets](#secrets)). |
| Apps menu empty / stale UI | Force a refresh (anonymous volume) via a Portainer Update; a stale browser cache can also reproduce it — test in a private window first. |
| `occ` not found | Use the full form: `docker exec -u www-data nextcloud php occ <command>`. |
| White screen / 500 after upgrade | `docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive`, check `docker logs nextcloud`. |
