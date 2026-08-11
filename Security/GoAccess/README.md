# GoAccess

GoAccess dashboard for NGINX Proxy Manager logs, deployed behind NPM (HTTPS is terminated by NPM). It reads the NPM access logs from the bind mount at `/opt/log`.

## Basic-auth credentials from Docker secrets

`BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD` are read from the `goaccess_user` / `goaccess_password` secrets (`${PATH_TO_SECRETS}/GoAccess/`) through an entrypoint wrapper, because GoAccess has no `*_FILE` env-var support. The wrapper exports them before starting the image:

```yaml
entrypoint:
  - /bin/sh
  - -c
  - |
    export BASIC_AUTH_USERNAME="$(cat /run/secrets/goaccess_user)"
    export BASIC_AUTH_PASSWORD="$(cat /run/secrets/goaccess_password)"
    exec tini -- /goan/start.sh
```

> The `|` block scalar is mandatory: `>` would fold the script into a single line and `export` would swallow the rest as variable names, crashing the container on start. `tini` is resolved from `PATH` (Alpine and Debian put it in different directories).

Create the secrets:

```bash
./Security/init-secrets.sh GoAccess goaccess_user goaccess_password
```

## Gotchas

- **Runs as root**: the image has no `USER` directive, so the `600`-mode secret files written by `init-secrets.sh` are readable and **no `chmod 644` is needed** — unlike n8n, which runs as the `node` user (UID 1000) and needs its secret file world-readable.
- `BASIC_AUTH` must be `True` to enable the login dialog (it defaults to `False`). Changing it requires a container restart for the `.htpasswd` to be regenerated.
- NPM force-SSL redirects `http://` to `https://` (301) — always use the `https://` URL.
