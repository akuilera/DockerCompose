# WireGuard (wg-easy)

WireGuard VPN server with a web UI (`wg-easy`) for managing clients.

> **Version pin**: the image is pinned to `:15`. v15 is a complete rewrite of
> wg-easy: the v14 environment variables (`PASSWORD_HASH`, `WG_HOST`,
> `WG_DEFAULT_*`) no longer exist and the configuration now lives in the
> Admin Panel of the Web UI. Do **not** drop the tag — `latest` would silently
> switch to another major version.

## Connection info

- **Container**: `wg-easy`
- **Web UI**: `http://<server>:51821` (requires `INSECURE=true`, it is HTTP)
- **Public ports**: `51820/udp` (WireGuard), `51821/tcp` (UI)
- **Network**: `vpn-net` (static IP `10.8.1.2`)
- **Clients**: `10.8.0.x` (defined in the config, see the setup wizard)
- **DNS pushed to clients**: `10.8.1.3` (Pi-hole — separate stack, see
  `../Pi-hole/README.md`)

> `vpn-net` must cover the static IPs `10.8.1.2`/`10.8.1.3` (the root README's
> create command uses `--subnet=10.8.1.0/24`). Verify the live subnet with
> `docker network inspect vpn-net` before deploying.

## First deploy (or migrate)

On the very first start the Web UI shows a setup wizard. No credentials are
set through the compose file; the wizard stores the admin password (hashed)
in the config volume, so no `.env`/secret is needed for wg-easy.

1. Start the stack.
2. Open `http://<server>:51821` and complete the wizard:
   - **User setup**: admin username + password.
   - **Existing setup**: if you are migrating from wg-easy v14, answer "Yes"
     and upload the `wg0.json` from the old container (download it via the old
     UI's Backup button, or copy it from
     `$PATH_TO_CONTAINERS/WireGuard/.wg-easy/wg0.json` before stopping the old
     stack). Otherwise answer "No" and enter the server **Host** and **Port**
     (the WireGuard listen port, e.g. `51820`).
3. In the **Admin Panel → Interface settings**, set **DNS** to `10.8.1.3`
   (Pi-hole) and **Allowed IPs** to the split-tunnel ranges below, so new
   clients pick them up by default.

> The container is attached to `vpn-net` (static `10.8.1.2`) so that VPN
> clients (`10.8.0.0/24`) can reach Pi-hole (`10.8.1.3`) through the container
> itself.

## Split tunnel

Default `wg-easy` routes **all** client traffic through the VPN. For split
tunneling (only home networks use the tunnel, the rest goes direct):

1. In the Web UI, **edit each client** and set **Allowed IPs** to:
   `10.8.0.0/16, 172.16.0.0/12` (+ your LAN subnet, e.g. `<LAN_SUBNET>`, if
   you want to reach Samba/NAS devices while roaming).
   - `10.8.0.0/16` — the VPN itself and Pi-hole (DNS).
   - `172.16.0.0/12` — **all** Docker bridge networks (current and future),
     so every service stays reachable without re-issuing configs.
2. Re-download the client config (QR / file) and reconnect.

The tunnel only carries the routed ranges; browsing stays on the client's
normal connection. DNS still goes to Pi-hole over the tunnel, so ad-blocking
applies to every client.

## Migrating from v14

v14 and v15 are incompatible (different configuration model). To migrate:

1. In the old v14 UI use **Backup** to download `wg0.json` (or copy
   `$PATH_TO_CONTAINERS/WireGuard/.wg-easy/wg0.json`).
2. Stop the old stack.
3. Deploy this stack and complete the wizard (see above), answering "Yes" and
   uploading the `wg0.json`.
4. Re-issue the client configs from the new UI (Allowed IPs change for split
   tunneling).
5. Delete the leftover v14 files from the config volume if the wizard did not
   take them over.

## Optional: expose the UI through NPM

To reach the UI as `wg.<suffix>.example.com` through the Cloudflare tunnel,
add a proxy host in NGINX Proxy Manager pointing to `wg-easy:51821` (HTTP
upstream; NPM terminates TLS). The Cloudflare tunnel already forwards the
wildcard host to NPM.

> **Requires network change**: NPM can only reach containers on `proxy-net`,
> and wg-easy is only on `vpn-net` (administrative UIs stay off the public
> segment by default). To expose the UI, also join `proxy-net` in the compose
> file. The same applies to Pi-hole (`../Pi-hole/README.md`).
