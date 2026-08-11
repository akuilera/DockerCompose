# WireGuard (wg-easy)

WireGuard VPN server with a web UI (`wg-easy`) for managing clients.

> **Version pin**: the image is pinned to `:15`. v15 is a complete rewrite of wg-easy: the v14 environment variables (`PASSWORD_HASH`, `WG_HOST`, `WG_DEFAULT_*`) no longer exist and the configuration now lives in the Admin Panel of the Web UI. Do **not** drop the tag — `latest` would silently switch to another major version.

## Connection info

- **Container**: `wg-easy`
- **Web UI**: `http://<server>:51821` (requires `INSECURE=true`, it is HTTP)
- **Public ports**: `51820/udp` (WireGuard), `51821/tcp` (UI)
- **Endpoint (Host)**: `<ZEROTIER_IP>` (ZeroTier transport, see "Remote access") or `<server LAN IP>` (home only); port `51820`
- **Network**: `vpn-net` (static IP `10.8.1.2`)
- **Clients**: `10.8.0.x` (defined in the config, see the setup wizard)
- **DNS pushed to clients**: `10.8.1.3` (Pi-hole — separate stack, see `../Pi-hole/README.md`)

> `vpn-net` must cover the static IPs `10.8.1.2`/`10.8.1.3` (the root README's create command uses `--subnet=10.8.1.0/24`). Verify the live subnet with `docker network inspect vpn-net` before deploying.

## First deploy (or migrate)

On the very first start the Web UI shows a setup wizard. No credentials are set through the compose file; the wizard stores the admin password (hashed) in the config volume, so no `.env`/secret is needed for wg-easy.

1. Start the stack.
2. Open `http://<server>:51821` and complete the wizard:
   - **User setup**: admin username + password.
   - **Existing setup**: if you are migrating from wg-easy v14, answer "Yes" and upload the `wg0.json` from the old container (download it via the old UI's Backup button, or copy it from `$PATH_TO_CONTAINERS/WireGuard/.wg-easy/wg0.json` before stopping the old stack). Otherwise answer "No" and enter the server **Host** and **Port** (the WireGuard listen port, e.g. `51820`). For **Host** use the endpoint the clients must reach: `<ZEROTIER_IP>` (ZeroTier transport) or `<server LAN IP>` (home only) — see "Remote access" below.
3. In the **Admin Panel → Interface settings**, set **DNS** to `10.8.1.3` (Pi-hole) and **Allowed IPs** to the split-tunnel ranges below, so new clients pick them up by default.

> The container is attached to `vpn-net` (static `10.8.1.2`) so that VPN clients (`10.8.0.0/24`) can reach Pi-hole (`10.8.1.3`) through the container itself.

## Split tunnel

Default `wg-easy` routes **all** client traffic through the VPN. For split tunneling (only home networks use the tunnel, the rest goes direct):

1. In the Web UI, **edit each client** and set **Allowed IPs** to: `10.8.0.0/16, 172.16.0.0/12` (+ your LAN subnet, e.g. `<LAN_SUBNET>`, if you want to reach Samba/NAS devices while roaming).
   - `10.8.0.0/16` — the VPN itself and Pi-hole (DNS).
   - `172.16.0.0/12` — **all** Docker bridge networks (current and future), so every service stays reachable without re-issuing configs.
2. Re-download the client config (QR / file) and reconnect.

The tunnel only carries the routed ranges; browsing stays on the client's normal connection. DNS still goes to Pi-hole over the tunnel, so ad-blocking applies to every client.

## Remote access without opening ports

This repo runs the homelab **without opening any inbound port on the router**: public web traffic leaves outbound through the Cloudflare tunnel, and remote access goes over ZeroTier. WireGuard is a point-to-point protocol that needs a reachable endpoint — it does no NAT traversal by itself. Without a port-forward, at least one peer must be publicly reachable, or a third host with a public IP must relay. ZeroTier provides that reachability for free (hole-punching + relay), so the WG tunnel uses it as transport.

### Free solution: WireGuard over ZeroTier (laptop/desktop)

Set the wizard **Host** to the server's ZeroTier IP (`<ZEROTIER_IP>`): the WG tunnel rides inside the ZeroTier mesh (tunnel-in-tunnel, UDP-in-UDP).

- **Laptop/desktop**: works — ZeroTier and WireGuard each create their own virtual interface and coexist.
- **Phone (iOS/Android): does NOT work.** Both apps register as a system VPN and the OS allows only one at a time (Android `VpnService`, iOS Network Extension) — enabling one disables the other. This is an OS limitation, not a misconfiguration. See "Phone" below.
- Every client must be joined to the ZeroTier network before the WG tunnel comes up.
- If ZeroTier's infrastructure (planet/relay) is down, remote access stops, but the wg-easy configuration, keys and clients are **not lost**; LAN access keeps working and remote access returns when ZeroTier is back.
- If throughput drops, lower the WG interface MTU to ~1280–1380 (UDP-in-UDP overhead).

### Phone: ZeroTier alone + Pi-hole DNS

Since a phone runs only one VPN at a time, run **ZeroTier alone** there and let it push Pi-hole as DNS, keeping ad-blocking while roaming:

1. Pi-hole publishes `53/tcp` + `53/udp` on the host (`0.0.0.0`), so it also answers on the server's ZeroTier IP.
2. In ZeroTier Central → network → **DNS Settings**: add `<ZEROTIER_IP>`. Add a **Managed Route** for the LAN subnet (via the server's ZeroTier IP) to reach LAN devices; the server needs IP forwarding (`net.ipv4.ip_forward=1`).
3. In the ZeroTier app on the phone, approve the network and enable **Allow DNS** (some iOS versions require setting the DNS manually in the app).
4. Reach home services through the ZeroTier routes instead of a WG tunnel.

### Paid improvement: fully self-hosted with a cheap VPS

To remove the ZeroTier dependency you need **one host with a public IPv4 that you own** — a VPS (~$3–5/month, e.g. Hetzner, Contabo, Linode):

1. Run wg-easy on the VPS (public IP, no NAT); open `51820/udp` in its firewall and set the wizard **Host** to the VPS IP or a hostname.
2. The home server keeps an **outbound** WG tunnel to the VPS (`PersistentKeepalive = 25`) — outbound connections work without any router port-forward.
3. Clients connect to the VPS endpoint; the VPS routes into the home network through that tunnel. ZeroTier leaves the path. Alternative: Headscale (self-hosted Tailscale control plane) on the VPS with the official Tailscale clients (WireGuard under the hood).
4. Pi-hole stays reachable through the tunnel: set client DNS to `10.8.1.3` and advertise a route to `10.8.1.0/24` through the home server.

Changing the endpoint later is UI-only: Admin Panel → Interface settings → Host, then re-issue the client configs (no data loss, no redeploy).

## Migrating from v14

v14 and v15 are incompatible (different configuration model). To migrate:

1. In the old v14 UI use **Backup** to download `wg0.json` (or copy `$PATH_TO_CONTAINERS/WireGuard/.wg-easy/wg0.json`).
2. Stop the old stack.
3. Deploy this stack and complete the wizard (see above), answering "Yes" and uploading the `wg0.json`.
4. Re-issue the client configs from the new UI (Allowed IPs change for split tunneling).
5. Delete the leftover v14 files from the config volume if the wizard did not take them over.

## Optional: expose the UI through NPM

To reach the UI as `wg.<suffix>.example.com` through the Cloudflare tunnel, add a proxy host in NGINX Proxy Manager pointing to `wg-easy:51821` (HTTP upstream; NPM terminates TLS). The Cloudflare tunnel already forwards the wildcard host to NPM.

> **Requires network change**: NPM can only reach containers on `proxy-net`, and wg-easy is only on `vpn-net` (administrative UIs stay off the public segment by default). To expose the UI, also join `proxy-net` in the compose file. The same applies to Pi-hole (`../Pi-hole/README.md`).
