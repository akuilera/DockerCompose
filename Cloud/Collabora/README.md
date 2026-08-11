# Collabora Online — Office document server

Standalone Collabora Online (the document server behind NextCloud's Office). NextCloud points at it with "Use your own server" (see `Cloud/NextCloud/README.md` → Collabora). The built-in `richdocumentscode` may stay enabled; while the external server is selected, it is the one used.

## Connection info

- **Container**: `collabora`
- **Image**: `collabora/code`
- **Port**: `9980` (HTTP inside `nextcloud-net`; TLS terminated by NPM)
- **Networks**: `nextcloud-net` (external, shared with NextCloud)
- **Admin console**: `https://collabora.<suffix>.<domain>/browser/dist/admin/admin.html` (user `admin`, password = `COLLABORA_PASSWORD`)

Reachable via every proxied hostname `collabora.<suffix>.<domain>`, one per network path (LAN, ZeroTier, WireGuard, ...). All route through the wildcard Cloudflare tunnel `*.<suffix>.<domain>` → NPM; only an NPM proxy host per hostname is needed.

## Configuration

Collabora does **not** support `*_FILE` secrets (issue CollaboraOnline/online#3915), so its config is plain env vars on the stack (Portainer) or in a local `.env`. No config file is mounted.

| Env var             | Meaning |
|---------------------|---------|
| `COLLABORA_DOMAIN`  | **NextCloud** hostnames allowed to reach Collabora (the WOPI allowlist), regex-escaped and `|`-separated. **Not** the Collabora hostnames. Example: `nextcloud\.example\.com\|nextcloud\.vpn\.example\.com`. |
| `COLLABORA_PASSWORD`| Password of the admin console (user `admin`). |
| `username`          | Fixed to `admin`. |
| `DONT_GEN_SSL_CERT=YES` | Disable the image's internal cert generation (TLS terminated by NPM). |
| `extra_params`      | `--o:ssl.enable=false --o:ssl.termination=true --o:logging.level=information` |

> If a Collabora hostname is used as the Office URL in NextCloud, it must be **https** (the editor runs inside an https NextCloud page; http would be blocked as mixed content).

### NPM proxy host (per hostname)

- Forward scheme: `http`, hostname: `collabora`, port: `9980` (same `nextcloud-net`).
- SSL: request a Let's Encrypt certificate.
- Advanced tab: **WebSockets support: ON** (the editor needs them).

## Healthcheck

Recent `collabora/code` images (26.04.2+, 2026) are **distroless**: no shell, no `curl`/`wget`, on purpose (smaller attack surface — see the Collabora blog "A hardened, distroless container base"). The image ships its own built-in HEALTHCHECK, so the compose defines **none**:

```yaml
# baked into the image:
HEALTHCHECK ["CMD", "/usr/bin/coolwsd", "--probe", "--use-env-vars"]
```

`coolwsd --probe` reads the container's own config (honouring `extra_params` / `ssl.enable`), connects to the loopback `/livez` endpoint and exits 0 only on HTTP 200. Because there is **no `/bin/sh`**, any compose `healthcheck:` that shells out (`bash -c ...`, `echo > /dev/tcp`, ...) will fail with `exec: "/bin/sh": no such file or directory` and override the working one. Leave the image's probe in place.

## Verify

```bash
# From the host (port 9980 is published):
curl -s http://127.0.0.1:9980/hosting/discovery | head -c 200
curl -s http://127.0.0.1:9980/readyz?verbose     # per-check readiness, 200 = ok

# From the public hostname (through NPM / Cloudflare):
curl -k https://collabora.<suffix>.<domain>/hosting/discovery

# WOPI callback: the Collabora container has no tools, so test from NextCloud's
# container (which has curl) instead:
docker exec -u www-data nextcloud curl -s http://collabora:9980/hosting/discovery | head -c 200
```

Definitive test: open a document in NextCloud, edit and save it, then watch `docker logs collabora` for WOPI errors.

On the NextCloud side, the **Allow list for WOPI requests** (Office admin settings, app `richdocuments`) must contain the **source address NextCloud actually sees on WOPI callbacks**, not the IPs of the machine running Collabora. In this deployment Collabora reaches NextCloud through its public URL (via NPM and the published port), so the requests arrive from the **Docker host bridge gateway**, not from `collabora`'s container IP on `nextcloud-net`.

If a document fails with "Unauthorized WOPI host", find the denied source in NextCloud's log and put it (or its CIDR) in the list:

```bash
docker logs nextcloud | grep -i "WOPI request denied"

sudo docker exec -u www-data nextcloud php occ config:app:get richdocuments wopi_allowlist
sudo docker exec -u www-data nextcloud php occ config:app:set richdocuments wopi_allowlist --value='<cidr-from-the-log>'
```

Comma-separated IPs/CIDRs, no spaces. `occ config:app:set` writes to the DB and is picked up by the next request — no redeploy needed.

## Incident: mount at `/etc/coolwsd/` crash-loops

Bind-mounting a directory over `/etc/coolwsd/` hides the image's default `coolwsd.xml`; the entrypoint does not regenerate it and the container restarts forever with `Failed to initialize COOLWSD: File not found: /etc/coolwsd/coolwsd.xml` (exit 78). Configure via env vars only; if a custom `coolwsd.xml` is ever needed, mount a **single file** (`coolwsd.xml:/etc/coolwsd/coolwsd.xml`) seeded from the image (`docker cp`).
