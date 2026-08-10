# Pi-hole — Global DNS

Network-wide ad-blocking. Serves DNS to the WireGuard clients, the host and,
optionally, to containers that join `vpn-net`.

## Connection info

- **Container**: `pihole`
- **Admin UI**: `http://<server>:5353/admin`
- **DNS**: `53/tcp` + `53/udp` on the host (`10.8.1.3` on `vpn-net`)
- **Network**: `vpn-net` (static IP `10.8.1.3`); optionally `proxy-net` for NPM

## Secrets

The admin UI password is read from the Docker secret via `WEBPASSWORD_FILE`
(Pi-hole supports `*_FILE` since v6). Create the secret file:

```bash
./Security/init-secrets.sh Pi-hole webpassword
```

`WEBPASSWORD_FILE` is ignored if a plain `WEBPASSWORD` env var is set, so keep
`WEBPASSWORD` out of the stack environment. If the persisted `setupVars.conf`
still holds an older password after the move, set the new one from the
container with `pihole setpassword`.

## Who uses it

- **WireGuard clients** — `10.8.1.3` is set as the interface DNS in the
  wg-easy Admin Panel (see `../WireGuard/README.md`).
- **Host** — point `systemd-resolved` at `10.8.1.3`:
  `sudo resolvectl dns <interface> 10.8.1.3` (persist via
  `/etc/systemd/resolved.conf`).
- **LAN devices** — set the DNS manually per device to the host's LAN IP
  (no router access, so it cannot be pushed via DHCP).
- **Containers** — only the ones that need ad-blocked DNS: attach them to
  `vpn-net` and use the Docker resolver (`127.0.0.11`) as fallback so
  service-name resolution (e.g. `mariadb`) keeps working:

  ```yaml
  services:
    some-service:
      networks:
        - vpn-net
      dns:
        - 10.8.1.3
        - 127.0.0.11
  ```

## Notes

- `FTLCONF_dns_listeningMode=ALL` lets Pi-hole answer on every interface,
  which is required on a bridge network.
- Port `53` on the host is freed when Pi-hole is removed from the WireGuard
  stack. Deploy order: remove the old `pihole` service from the WireGuard
  stack first, then deploy this stack (same volumes, data intact).

## Optional: expose the UI through NPM

Join `proxy-net` (uncomment the network entry) and add a proxy host in NPM
pointing to `pihole:80` (HTTP upstream). By default Pi-hole is only on
`vpn-net`, since the admin UI should stay off the public segment (see the root
README, "Why this layout").
