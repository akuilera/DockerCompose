# Devices — monitored hosts registry (template)

Generic, committed template for the device registry used by the monitoring stack. **This folder carries no real data and is never deployed.** The real registry lives on the server, inside the repository clone, at `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/<device>/.env`. The whole `Devices/` folder is gitignored (`**/Monitoring/Devices/`), so no device names leak into this public repository; this `Devices.example/` folder is the only thing committed. Both stacks read the same registry at runtime:

- Prometheus bootstrap turns each entry into a scraped target (`labels.host = DEVICE_NAME`).
- Grafana bootstrap turns each entry into a per-device dashboard (battery/GPU rows depend on the flags).

Copy `example/.env.example` once per device, fill in the values, and place it in the server clone under `Devices/<device>/.env`. Adding, removing or renaming a device is just adding/removing/editing one `.env` file, then `git pull` on the clone and Update on the stacks — nothing else.

The committed copy is named `.env.example`, **not** `.env`: the repository-wide `.env` gitignore rule would silently drop it otherwise.

## Fields

| Field | Meaning |
|---|---|
| `DEVICE_NAME` | Title shown in Grafana and used as the `host` label on the target. The bootstrap only accepts `[A-Za-z0-9 ._-]`. |
| `DEVICE_ADDR` | `IP:9100` (or name:port) where Prometheus scrapes that device's `node_exporter`. |
| `DEVICE_BATTERY` | Set to `1` to render the Battery row in that device's dashboard. Battery metrics need no setup: `node_exporter`'s native `powersupplyclass` collector provides them. |
| `DEVICE_GPU` | Set to `1` to render the NVIDIA row (only machines with a discrete NVIDIA GPU). The metrics come from the GPU heartbeat installed by the node-exporter installer. |

Install `node_exporter` natively on each device (the server included) with `Monitoring/node-exporter/install-node-exporter.sh`, then create its `.env` in the server clone.

## Security

This is a public repository: **never** put a real name/address in this folder or anywhere in it. Real values belong only in the server-side copy under `${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/`.