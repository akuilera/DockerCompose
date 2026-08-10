# SMB share mounts on Linux (`fstab` & systemd)

How to mount a Samba/SMB network share on a Linux client so it behaves like a
local folder — including for sandboxed (Flatpak) GUI applications. This is the
guide followed for the shares in this homelab; it is written generically so it
can be reused for any other share.

> **Which method is used here:** **Option A — `/etc/fstab` with
> `x-systemd.automount`.** Option B (systemd mount units) is documented below as
> an alternative for cases where editing `fstab` is not preferred.

## Prerequisites

- `cifs-utils` installed on the client (`sudo dnf install cifs-utils` /
  `sudo apt install cifs-utils`).
- The server must be reachable over the network and expose the share.
- `sudo` access on the client (to create the mount point and edit
  `/etc/fstab`, or to install the systemd units).

## Option A — `/etc/fstab` with automount (used here)

This mounts the share **on first access**: the machine boots normally even if
the server is offline, and the share appears as soon as anything opens its
mount point.

### 1. Create a root-only credentials file

```bash
sudo mkdir -p /etc/samba
sudoedit /etc/samba/credentials
```

Contents (one field per line, no quotes):

```
username=YOUR_SMB_USER
password=YOUR_SMB_PASSWORD
```

Protect it so only root can read it:

```bash
sudo chmod 600 /etc/samba/credentials
```

### 2. Add the mount to `/etc/fstab`

```bash
echo '//SERVER_IP/SHARE_NAME  /mnt/MOUNT_POINT  cifs  _netdev,noauto,x-systemd.automount,x-systemd.mount-timeout=30,credentials=/etc/samba/credentials,uid=YOUR_UID,gid=YOUR_GID,vers=3.0  0  0' | sudo tee -a /etc/fstab
```

What each option does:

| Option | Meaning |
| --- | --- |
| `//SERVER_IP/SHARE_NAME` | Address and share name, e.g. `//<server-ip>/Data`. |
| `/mnt/MOUNT_POINT` | Local mount point (create it in step 3). Under `/mnt` it mirrors the server layout and requires root. |
| `credentials=/etc/samba/credentials` | Read user/password from this file instead of the command line. |
| `uid=...`, `gid=...` | Your local user/group ids (`echo $(id -u) $(id -g)`) so you own the files. |
| `vers=3.0` | SMB protocol version; `3.0` is a safe default, use `2.1` for older servers. |
| `_netdev` | Only attempt the mount once the network is up. |
| `noauto,x-systemd.automount` | Do not mount at boot; mount on first access. |
| `x-systemd.mount-timeout=30` | Give up after 30 s if the server is offline. |

### 3. Create the mount point and mount

```bash
sudo mkdir -p /mnt/MOUNT_POINT
sudo systemctl daemon-reload
sudo mount /mnt/MOUNT_POINT
ls /mnt/MOUNT_POINT
```

No output from `mount` means success. A common mistake is forgetting to create
the mount point first — the error `Couldn't chdir to ...: No such file or
directory` simply means the directory does not exist yet.

### 4. Verify

- `mount | grep cifs` shows the active mount.
- Open the folder in your file manager; the share contents should be listed.

### 5. Make it available to sandboxed (Flatpak) apps

Flatpak apps are sandboxed and cannot see `/mnt/...` by default. Grant access
for the app that needs it (example: a Git GUI client):

```bash
flatpak override --user com.example.App --filesystem=/mnt/MOUNT_POINT
```

`flatpak info --show-permissions com.example.App` should then list that path
under `filesystems=`.

> Note: your file manager connects to `smb://` shares through a virtual layer
> (KIO, in Dolphin) that Flatpak apps cannot see. A real `fstab`/systemd mount
> is what makes the share visible to them.

## Option B — systemd mount + automount units (alternative)

Instead of the `fstab` line, create two unit files. Unit file names must encode
the mount point: `/mnt/MOUNT_POINT` becomes `mnt-MOUNT_POINT.mount`.

`/etc/systemd/system/mnt-MOUNT_POINT.mount`:

```ini
[Unit]
Description=Mount SMB share
After=network-online.target
Wants=network-online.target

[Mount]
What=//SERVER_IP/SHARE_NAME
Where=/mnt/MOUNT_POINT
Type=cifs
Options=_netdev,credentials=/etc/samba/credentials,uid=YOUR_UID,gid=YOUR_GID,vers=3.0

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/mnt-MOUNT_POINT.automount`:

```ini
[Unit]
Description=Automount SMB share

[Automount]
Where=/mnt/MOUNT_POINT
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo mkdir -p /mnt/MOUNT_POINT
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-MOUNT_POINT.automount
```

## Reusing this for other shares

Only the placeholders change:

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `SERVER_IP` | Address of the SMB server | `<server-ip>` |
| `SHARE_NAME` | Name of the share on the server | `Data` |
| `MOUNT_POINT` | Local directory where it is mounted | `Data` |
| `YOUR_SMB_USER` | User that authenticates against the server | `alice` |
| `YOUR_SMB_PASSWORD` | That user's password (never committed) | — |
| `YOUR_UID` / `YOUR_GID` | Local ids that own the mounted files | `1000` / `1000` |

For each new share: reuse or create its own credentials file, pick a free mount
point, and add another `fstab` line (or a new unit pair).

## Security notes

- Credentials live in `/etc/samba/credentials`, root-only with `chmod 600`.
- Never put the password in `/etc/fstab`, in a unit file, or in any versioned
  file.
- `.env` files and credentials are never committed to this repository.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `mount error(13) Permission denied` | Wrong user/password in the credentials file. |
| `host is down` / `No route to host` | Server unreachable; check `ping SERVER_IP`. |
| `protocol negotiation failed` | Try `vers=2.1` instead of `vers=3.0`. |
| `Couldn't chdir to ...: No such file or directory` | Mount point missing; `sudo mkdir -p` it. |
| Stale credentials after editing the file | Unmount and remount: `sudo umount /mnt/MOUNT_POINT && sudo mount /mnt/MOUNT_POINT`. |
| Duplicated `fstab` entries | Two identical lines for the same mount point; remove one with `sudoedit /etc/fstab`. |
