# ClamAV

Containerized ClamAV (`clamd` + `freshclam`) that scans files **streamed** to it by other containers. Main consumer: Nextcloud's `files_antivirus`.

## Why a container when the host already runs ClamAV?

This repo assumes three complementary layers, none of which duplicates another:

1. **Host `clamd` + `clamonacc`** — protects the OS itself and scans the container data trees (the bind-mounted folders) on-access, in real time, as files are opened.
2. **Container `clamd`** — a separate instance that scans files **streamed** to it over the network (Nextcloud's `files_antivirus`). It listens on TCP `3310` inside the Docker network namespace, with **no published ports**, so it never conflicts with the host daemon (which uses the systemd unix socket).
3. **Scheduled scans** — cover files that are stored and never touched again; on-access only sees files that are actually opened. See "Scheduled scans" below.

## Configuration

- Container: `clamav` (image `clamav/clamav:stable`).
- No ports published. `clamd` TCP `3310` is reachable **only** from other containers on a shared network.
- Persistent data: `${PATH_TO_CONTAINERS}/ClamAV:/var/lib/clamav` (signature databases survive recreates).
- Healthcheck: `clamdscan --ping 3` (ping `clamd` up to 3 times; exits 0 on `PONG`, uses the unix socket, no IPv6 involved). `--ping` **requires** an attempt count in ClamAV ≥ 0.103 — bare `clamdscan --ping` errors out. `start_period: 600s` covers the initial signature download on a fresh volume (first boot can take minutes; `clamd` only starts after the DBs are ready).
- Env vars come from `global.env` / the stack env (Portainer); see `.env.example`.

> The image itself ships a HEALTHCHECK (`clamdcheck.sh`, a `nc localhost 3310` ping). We override it because on Docker ≥ 26 `localhost` resolves to `::1` and busybox `nc` cannot handle IPv6, so the built-in one fails even when `clamd` is healthy. `clamdscan --ping` talks to the local unix socket and is immune.

> `clamd` listens on TCP `3310` on all interfaces (the image's `clamd.conf` leaves `TCPAddr` commented = default), so other containers reach it as `clamav:3310`.

## Networks

The container joins **only the networks of its real consumers** — currently `nextcloud-net` (Nextcloud's `files_antivirus` reaches it as `clamav:3310`). Least privilege: `clamd` is an unauthenticated TCP service, so every extra network is an unnecessary surface for any container on it.

When a **new consumer** appears later, add its network to this stack and recreate the container:

```yaml
    networks:
      - new-net
# ...
networks:
  new-net:
    external: true
    name: new-net
```

The scheduled scans use no network at all: they run through `docker exec` against the local mounts.

## Scheduled scans

Streaming (Nextcloud) and on-access (host) scanning only cover files that are **touched**. Files that land in a container's data folder and are never opened again (e.g. a file a webhook drops into `n8n/files`) need a periodic full scan.

The intended way to add one is:

1. Mount the service's data folder **read-only** into this container:

   ```yaml
   volumes:
     - "${PATH_TO_CONTAINERS}/n8n/files:/scan/n8n:ro"
   ```

   (one mount per folder; recreate the container afterwards)

2. Add a **root** cron job that streams the scan to the container's `clamd`:

   ```
   0 3 * * 6 root docker exec clamav clamdscan --infected /scan/n8n >> /var/log/clamav-scan.log 2>&1
   ```

   - `clamdscan` recurses into directories; `--infected` prints only hits.
   - Exit codes: `0` clean, `1` infected found, `2` error (all land in the log).
   - Manual run: `docker exec clamav clamdscan --infected /scan/n8n`.
   - Add more folders with one more mount + path argument (or another cron line).

This repo ships the `n8n` example. It is a **root** cron because `docker exec` from the host requires it; the scan itself runs as the container's `clamd`.

## Nextcloud

Enable the `files_antivirus` app and switch it from "ClamAV Executable" to **"ClamAV Daemon"**:

- Host: `clamav` (container name on the shared `nextcloud-net`)
- Port: `3310`

or from the CLI:

```bash
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_mode --value=daemon
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_host --value=clamav
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_port --value=3310
```

Background scanning of already-stored files (v6 uses boolean `av_background_scan` and `av_scan_interval` in seconds, both in the fast cache):

```bash
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_background_scan --value=1
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_scan_interval --value=900
docker exec -u www-data nextcloud php occ files_antivirus:background-scan --verbose
```

> The background scanner is only triggered by Nextcloud's **cron**. The `nextcloud-cron` sidecar in `Cloud/NextCloud/docker-compose.yml` runs `/cron.sh` (php cron.php) every 5 minutes; it mounts the same volumes/secrets and joins the same networks as the `nextcloud` service. See `Cloud/NextCloud/README.md` for the compose.

## Verify

```bash
# clamd answers (exit 0 = PONG)
docker exec clamav clamdscan --ping 3

# EICAR test file (harmless signature sample), streamed via stdin
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
  | docker exec -i clamav clamdscan -

# logs
docker logs clamav
```

After enabling daemon mode, upload a file in Nextcloud and watch `docker logs clamav` for scan lines; the antivirus status in Nextcloud admin → Antivirus should be green.

> **EICAR via the Nextcloud UI** is the end-to-end test. Verified behavior on `files_antivirus` v6 (Nextcloud 34): an infected **upload is blocked at write time** — the UI reports "virus detected, upload aborted" and the file is never stored. The on-write wrapper only runs after a stack recreate that re-loads the app (a plain `occ` config change does not re-arm the hooks), so after any change that touches the app, recreate the container before testing. If a stored file is found infected by a **background scan**, the action set in `av_infected_action` applies (delete/quarantine/log). The background scanner only runs if Nextcloud's **cron** is enabled — this repo ships a `nextcloud-cron` sidecar (`/cron.sh`, every 5 min); without it, only on-write scanning happens. If an upload vanishes with **no** scan line, the app is not reaching `clamd`: check `occ config:list files_antivirus` (`av_mode`, `av_host`, `av_port`, `av_background_scan`, `av_scan_interval`) and the Nextcloud log.

## RAM

~1 GB while scanning (cold signatures on disk). A single instance serves every consumer over its own network.

A freshclam update triggers a `clamd` database reload, which can briefly spike memory (a known heavy moment). On a tight server, if `clamd` ever gets OOM-killed on an update, override `clamd.conf` with `ConcurrentDatabaseReload no` (pause scanning instead of double-buffering the DB during reload).

## Note: Wazuh

Wazuh (endpoint security / SIEM) is planned as a later phase; see `TODO.md` (local, gitignored).
