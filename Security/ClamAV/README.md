# ClamAV

Containerized ClamAV (`clamd` + `freshclam`) that scans files **streamed** to
it by other containers. Main consumer: Nextcloud's `files_antivirus`.

## Why a container when the host already runs ClamAV?

The host ClamAV daemon protects the OS itself (on-access via `clamonacc`). The
container is a **separate `clamd` instance**: it listens on its own TCP port
`3310` inside the Docker network namespace, with **no published ports**, so it
never conflicts with the host daemon (which uses the systemd unix socket).
They are complementary — the host one scans the system, this one scans
container workloads.

## Configuration

- Container: `clamav` (image `clamav/clamav:stable`).
- No ports published. `clamd` TCP `3310` is reachable **only** from other
  containers on a shared network.
- Persistent data: `${PATH_TO_CONTAINERS}/ClamAV:/var/lib/clamav` (signature
  databases survive recreates).
- Healthcheck: `clamdscan --ping`; generous `start_period` for the initial
  signature download (first boot can take a while).
- Env vars come from `global.env` / the stack env (Portainer); see
  `.env.example`.

## Networks

The container joins **all current shared networks** (`apps-net`, `db-net`,
`files-net`, `fmd-net`, `heimdall-net`, `immich-net`, `nextcloud-net`,
`proxy-net`, `vpn-net`), so every existing service already reaches it as
`clamav` on their common network (e.g. Nextcloud on `nextcloud-net`).

When a **new network** is created later, add it to this stack and recreate the
container:

```yaml
    networks:
      - new-net
# ...
networks:
  new-net:
    external: true
    name: new-net
```

No port is exposed, so the extra attachment is harmless on services that never
scan anything.

## Nextcloud

Enable the `files_antivirus` app and switch it from "ClamAV Executable" to
**"ClamAV Daemon"**:

- Host: `clamav` (container name on the shared `nextcloud-net`)
- Port: `3310`

or from the CLI:

```bash
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_mode --value=daemon
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_host --value=clamav
docker exec -u www-data nextcloud php occ config:app:set files_antivirus av_port --value=3310
```

## Verify

```bash
# clamd answers
docker exec clamav clamdscan --ping          # → PONG

# EICAR test file (harmless signature sample), streamed via stdin
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
  | docker exec -i clamav clamdscan -

# logs
docker logs clamav
```

After enabling daemon mode, upload a file in Nextcloud and watch
`docker logs clamav` for scan lines; the antivirus status in Nextcloud
admin → Antivirus should be green.

## RAM

~1 GB while scanning (cold signatures on disk). A single instance serves every
network instead of one per network.

## Note: Wazuh

Wazuh (endpoint security / SIEM) is planned as a later phase; see `TODO.md`
(local, gitignored).
