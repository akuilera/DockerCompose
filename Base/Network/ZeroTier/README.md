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

Then connect the server to ZeroTier with

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

ZeroTier provides the network route to the server (the `lan` route / URL access from the laptop). It is part of the chicken-and-egg bootstrap: without a URL you cannot reach Forgejo, and that URL requires ZeroTier + **NGINX Proxy Manager**. ZeroTier has no DB dependency of its own — start it right after MariaDB (see the repo root README → Boot order).