# Cloudflared Tunnel

Forwards public hostnames to internal services without opening inbound ports in the router: the container dials **out** to Cloudflare's edge and traffic enters through that established connection.

## How it works

```
Internet ──► Cloudflare edge ──(outbound tunnel)──► cloudflared container ──► NPM ──► services
```

- The tunnel is authenticated with a **token** (per-tunnel, from the Cloudflare Zero Trust dashboard).
- The container connects to the `proxy-net` network (same as the reverse proxy), so the tunnel terminates at NPM and every hostname is proxied as a regular host.

## Token as a secret

Since cloudflared **2025.4.0** the token can be read from a file natively via `TUNNEL_TOKEN_FILE`, so it never appears as an env var value:

```yaml
environment:
  TUNNEL_TOKEN_FILE: /run/secrets/tunnel_token
```

Create the secret file with the helper script:

```bash
./Security/init-secrets.sh Cloudflare tunnel_token
```

## Gotcha: non-root container (UID 65532)

The image runs as the unprivileged user **65532**, so the token file must be readable by that user. The secret is mounted as a bind-mounted file (Docker Compose `file:` secrets are not tmpfs), so its on-disk permissions are kept:

```bash
chmod 644 ${PATH_TO_SECRETS}/Cloudflare/tunnel_token
```

A `600`/root-owned token file will make the container fail to start with a permission error (crash-loop). Keep the containing folder protected (`700`) — the file itself just needs to be world-readable (`644`).

## Wildcard hostnames

A single tunnel serves every public service: the Cloudflare dashboard exposes wildcard hostnames (`*.{local|zero}.<suffix>.<domain>`) that terminate at NPM, so each service is reached on both the LAN (`*.local.…`) and ZeroTier (`*.zero.…`) paths without adding a tunnel entry per host. NPM holds the per-host proxy rules.

## Changing the server IP

The tunnel itself connects outbound, so it survives a local IP change. But the new address must still be reflected in **both** the Cloudflare dashboard (DNS records that point at the server) and NPM (proxy host destinations / access lists) for the services to keep resolving and reachable.
