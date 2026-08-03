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