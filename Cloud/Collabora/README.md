# Collabora Online — Office document server

Standalone Collabora Online (the document server behind NextCloud's Office).
NextCloud points at it with "Use your own server" (see
`Cloud/NextCloud/README.md` → Collabora). The built-in `richdocumentscode` may
stay enabled; while the external server is selected, it is the one used.

## Connection info

- **Container**: `collabora`
- **Image**: `collabora/code`
- **Port**: `9980` (HTTP inside `nextcloud-net`; TLS terminated by NPM)
- **Networks**: `nextcloud-net` (external, shared with NextCloud)
- **Admin console**: `https://collabora.<suffix>.<domain>/browser/dist/admin/admin.html` (user `admin`, password = `COLLABORA_PASSWORD`)

Reachable via every proxied hostname `collabora.<suffix>.<domain>`, one per
network path (LAN, ZeroTier, WireGuard, ...). All route through the wildcard
Cloudflare tunnel `*.<suffix>.<domain>` → NPM; only an NPM proxy host per
hostname is needed.

## Configuration

Collabora does **not** support `*_FILE` secrets (issue
CollaboraOnline/online#3915), so its config is plain env vars on the stack
(Portainer) or in a local `.env`. No config file is mounted.

| Env var             | Meaning |
|---------------------|---------|
| `COLLABORA_DOMAIN`  | **NextCloud** hostnames allowed to reach Collabora (the WOPI allowlist), regex-escaped and `|`-separated. **Not** the Collabora hostnames. Example: `nextcloud\.example\.com\|nextcloud\.vpn\.example\.com`. |
| `COLLABORA_PASSWORD`| Password of the admin console (user `admin`). |
| `username`          | Fixed to `admin`. |
| `DONT_GEN_SSL_CERT=YES` | Disable the image's internal cert generation (TLS terminated by NPM). |
| `extra_params`      | `--o:ssl.enable=false --o:ssl.termination=true --o:logging.level=information` |

> If a Collabora hostname is used as the Office URL in NextCloud, it must be
> **https** (the editor runs inside an https NextCloud page; http would be
> blocked as mixed content).

### NPM proxy host (per hostname)

- Forward scheme: `http`, hostname: `collabora`, port: `9980` (same
  `nextcloud-net`).
- SSL: request a Let's Encrypt certificate.
- Advanced tab: **WebSockets support: ON** (the editor needs them).

## Healthcheck

The image ships **no `curl`**, so the healthcheck opens a TCP port instead. The
form only opens the socket without sending data (`exec 3<>`); the previous
`echo >` variant wrote a byte, which coolwsd closes with a reset (SIGPIPE) so
the probe failed even while the server was fine:

```yaml
    healthcheck:
      test: [ "CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/9980'" ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s
```

## Verify

```bash
# Discovery endpoint (must return a big XML with WOPI urlsrc)
curl -k https://collabora.<suffix>.<domain>/hosting/discovery

# WOPI callback: from INSIDE the container, NextCloud must be reachable
# (open the socket, send nothing)
docker exec collabora bash -c 'exec 3<>/dev/tcp/nextcloud/80' && echo reachable
```

Definitive test: open a document in NextCloud, edit and save it, then watch
`docker logs collabora` for WOPI errors.

On the NextCloud side, set the **Allow list for WOPI requests** (Office admin
settings) to the IPs of the machine running Collabora (its LAN, ZeroTier and
WireGuard IPs, as applicable).

## Incident: mount at `/etc/coolwsd/` crash-loops

Bind-mounting a directory over `/etc/coolwsd/` hides the image's default
`coolwsd.xml`; the entrypoint does not regenerate it and the container
restarts forever with `Failed to initialize COOLWSD: File not found:
/etc/coolwsd/coolwsd.xml` (exit 78). Configure via env vars only; if a custom
`coolwsd.xml` is ever needed, mount a **single file**
(`coolwsd.xml:/etc/coolwsd/coolwsd.xml`) seeded from the image (`docker cp`).
