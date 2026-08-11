# n8n

n8n deployed behind NGINX Proxy Manager (HTTPS is terminated by NPM).

## Public hostname from a Docker secret

`N8N_HOST` and `WEBHOOK_URL` are read from the `n8n_host` secret (`${PATH_TO_SECRETS}/n8n/n8n_host`) through an entrypoint wrapper, because n8n has no `*_FILE` env-var support. The wrapper exports them before starting n8n:

```yaml
entrypoint:
  - /bin/sh
  - -c
  - |
    export N8N_HOST="$(cat /run/secrets/n8n_host)"
    export WEBHOOK_URL="https://$(cat /run/secrets/n8n_host)/"
    exec tini -- /docker-entrypoint.sh
```

> The `|` block scalar is mandatory: `>` would fold the script into a single line and `export` would swallow the rest as variable names, crashing the container on start. `tini` is resolved from `PATH` (Alpine and Debian put it in different directories).

Create the secret:

```bash
./Security/init-secrets.sh n8n n8n_host
```

## Gotcha: non-root container (UID 1000)

The image runs as the `node` user, so the secret file must be readable by it. The secret is mounted as a bind-mounted file (Compose `file:` secrets are not tmpfs), so its on-disk permissions are kept:

```bash
chmod 644 ${PATH_TO_SECRETS}/n8n/n8n_host
```

A `600`/root-only file makes `$(cat /run/secrets/n8n_host)` fail and n8n start without a hostname. Keep the containing folder protected (`700`) — the file itself just needs to be world-readable.
