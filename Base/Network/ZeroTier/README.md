The network ID is provided as the Docker secret `zt_network` (`$PATH_TO_SECRETS/ZeroTier/zt_network`, created with `./Security/init-secrets.sh ZeroTier zt_network`). The container joins it via the entrypoint: `exec /entrypoint.sh "$(cat /run/secrets/zt_network)"`.

You have to first make the YAML up like follows:
```
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    # network_mode: host
    expose:
      - "9993/tcp"
```

Then connect the server to ZeroTier with (manual join is only needed to debug an unjoined node — the compose joins automatically from the secret):

- `zerotier-cli status` <- Should return 200
- `zerotier-cli join <NETWORK_ID>`
- `zerotier-cli listnetworks` <- Your network should be listed

Then take the container down and up like this:
```
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    network_mode: host
    # expose:
    #   - "9993/tcp"
```

🤷‍♂️

## Role in the Homelab

ZeroTier provides the remote-access route to the server. It is part of the chicken-and-egg bootstrap: without a URL you cannot reach the web services, and that URL requires ZeroTier + **NGINX Proxy Manager**. ZeroTier has no DB dependency of its own — start it right after MariaDB (see the repo root README → Boot order).