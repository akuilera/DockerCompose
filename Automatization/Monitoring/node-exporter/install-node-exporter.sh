#!/usr/bin/env bash
# =============================================================================
# node_exporter installer (+ optional NVIDIA GPU heartbeat)
#
# Generic by design: every setting is an environment variable with a sane
# default, so the same script fits every Linux client of the monitoring stack.
# Nothing here is machine specific. Put overrides in a .env next to this script
# (see .env.example) or export them before running; .env stays gitignored.
#
# Two things this script exists to get right, both verified on real hardware:
#
#   1. btrfs is NOT in the filesystem fstype exclusions. Most hardening
#      examples exclude it, which silently blinds you on any btrfs root --
#      including the disk-full alert, silently. Same for excluding all of /run:
#      removable disks mount under /run/media/<user>/<label>, so excluding /run
#      hides them. /run itself is tmpfs and is already filtered by fstype.
#
#   2. The GPU heartbeat exists to catch a HARD LOCK, which a plain scrape
#      cannot see: when the machine stops, the scrape fails and the series just
#      goes stale. A local timer stops writing a file instead, and a wedged
#      nvidia-smi becomes query_success 0 rather than a hang.
#
# Tested on Fedora Linux. Run as root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration (override via environment, or a local .env) --------------
# shellcheck disable=SC1091
[ -f "${SCRIPT_DIR}/.env" ] && { echo "[+] sourcing ${SCRIPT_DIR}/.env"; set -a; . "${SCRIPT_DIR}/.env"; set +a; }

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.12.1}"
NODE_EXPORTER_USER="${NODE_EXPORTER_USER:-node_exporter}"
NODE_EXPORTER_GROUP="${NODE_EXPORTER_GROUP:-${NODE_EXPORTER_USER}}"
NODE_EXPORTER_LISTEN="${NODE_EXPORTER_LISTEN:-:9100}"
NODE_EXPORTER_OPTS_EXTRA="${NODE_EXPORTER_OPTS_EXTRA:-}"
NODE_EXPORTER_VERIFY_SHA256="${NODE_EXPORTER_VERIFY_SHA256:-1}"
NODE_EXPORTER_ENABLE_SYSTEMD_COLLECTOR="${NODE_EXPORTER_ENABLE_SYSTEMD_COLLECTOR:-1}"

INSTALL_DIR="${NODE_EXPORTER_INSTALL_DIR:-/usr/local/bin}"
UNIT_DIR="${NODE_EXPORTER_UNIT_DIR:-/etc/systemd/system}"
STATE_DIR="${NODE_EXPORTER_STATE_DIR:-/var/lib/node_exporter}"
TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-${STATE_DIR}/textfile_collector}"

GPU_HEARTBEAT_ENABLE="${GPU_HEARTBEAT_ENABLE:-1}"
GPU_HEARTBEAT_INTERVAL="${GPU_HEARTBEAT_INTERVAL:-15s}"
GPU_HEARTBEAT_TIMEOUT="${GPU_HEARTBEAT_TIMEOUT:-5}"
# How long a recorded hard freeze keeps nagging, in seconds (30 days).
GPU_HEARTBEAT_MAX_GAP_TTL="${GPU_HEARTBEAT_MAX_GAP_TTL:-2592000}"

FIREWALL_MANAGE="${NODE_EXPORTER_FIREWALL_MANAGE:-1}"
NODE_EXPORTER_FIREWALL_PORT="${NODE_EXPORTER_FIREWALL_PORT:-9100/tcp}"

UNIT_LISTEN_RE='--web\.listen-address='
die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[+] $*"; }

# --- pre-flight -------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "run with sudo or as root"
command -v curl >/dev/null 2>&1 || die "curl is required (e.g. dnf install curl)"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

for f in node-exporter.service nvidia-gpu-heartbeat.sh nvidia-gpu-heartbeat.service nvidia-gpu-heartbeat.timer; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || die "missing ${SCRIPT_DIR}/${f} (run from the repo copy of this folder)"
done

# --- download + verify ------------------------------------------------------
info "downloading node_exporter v${NODE_EXPORTER_VERSION} (${ARCH})"
TMPDIR="$(mktemp -d)"; trap 'rm -rf "${TMPDIR}"' EXIT
ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
curl -fsSL --retry 3 -o "${TMPDIR}/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}" || die "download failed"

if [[ "${NODE_EXPORTER_VERIFY_SHA256}" == "1" ]]; then
  # Trust-on-first-use: the checksum manifest is fetched from the same release,
  # so this catches corruption and truncation, not a compromised upstream.
  if curl -fsSL --retry 3 -o "${TMPDIR}/sha256sums.txt" "${BASE_URL}/sha256sums.txt"; then
    expected="$(awk -v f="${ARCHIVE}" '$2 == f { print $1 }' "${TMPDIR}/sha256sums.txt")"
    actual="$(sha256sum "${TMPDIR}/${ARCHIVE}" | awk '{ print $1 }')"
    [[ -n "${expected}" ]] || die "no checksum published for ${ARCHIVE}"
    [[ "${expected}" == "${actual}" ]] || die "sha256 mismatch for ${ARCHIVE}"
    info "sha256 verified"
  else
    echo "[WARN] could not fetch sha256sums.txt; continuing unverified" >&2
  fi
else
  echo "[WARN] sha256 verification disabled by NODE_EXPORTER_VERIFY_SHA256=0" >&2
fi

tar -xzf "${TMPDIR}/${ARCHIVE}" -C "${TMPDIR}"
install -m 0755 "${TMPDIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" "${INSTALL_DIR}/node_exporter"
info "installed ${INSTALL_DIR}/node_exporter"

# --- user and directories ---------------------------------------------------
if ! id "${NODE_EXPORTER_USER}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${NODE_EXPORTER_USER}"
  info "created system user ${NODE_EXPORTER_USER}"
fi
getent group "${NODE_EXPORTER_GROUP}" >/dev/null || groupadd --system "${NODE_EXPORTER_GROUP}"

install -d -o "${NODE_EXPORTER_USER}" -g "${NODE_EXPORTER_GROUP}" -m 0755 "${STATE_DIR}"
install -d -o "${NODE_EXPORTER_USER}" -g "${NODE_EXPORTER_GROUP}" -m 0755 "${TEXTFILE_DIR}"
info "textfile collector dir: ${TEXTFILE_DIR}"

# --- units ------------------------------------------------------------------
install -m 0644 "${SCRIPT_DIR}/node-exporter.service" "${UNIT_DIR}/node-exporter.service"

if [[ "${GPU_HEARTBEAT_ENABLE}" == "1" ]]; then
  install -m 0755 "${SCRIPT_DIR}/nvidia-gpu-heartbeat.sh" "${INSTALL_DIR}/nvidia-gpu-heartbeat"
  install -m 0644 "${SCRIPT_DIR}/nvidia-gpu-heartbeat.service" "${UNIT_DIR}/nvidia-gpu-heartbeat.service"
  install -m 0644 "${SCRIPT_DIR}/nvidia-gpu-heartbeat.timer" "${UNIT_DIR}/nvidia-gpu-heartbeat.timer"
  # Keep the interval and timeout in one place: the shipped unit is the default,
  # an override file wins if the operator changed them.
  cat > "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d-overrides" <<EOF
# Generated by install-node-exporter.sh -- edit freely, it is not overwritten
# unless the script is re-run.
[Timer]
OnUnitActiveSec=${GPU_HEARTBEAT_INTERVAL}
EOF
  install -d -m 0755 "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d"
  mv "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d-overrides" \
     "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d/10-interval.conf"
  install -d -m 0755 "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d"
  cat > "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d/10-env.conf" <<EOF
# Generated by install-node-exporter.sh -- edit freely, it is not overwritten
# unless the script is re-run.
[Service]
Environment=NODE_GPU_TEXTFILE_DIR=${TEXTFILE_DIR}
Environment=NODE_GPU_TIMEOUT=${GPU_HEARTBEAT_TIMEOUT}
Environment=NODE_GPU_MAX_GAP_TTL=${GPU_HEARTBEAT_MAX_GAP_TTL}
EOF
  info "installed GPU heartbeat (${GPU_HEARTBEAT_INTERVAL}, timeout ${GPU_HEARTBEAT_TIMEOUT}s)"
else
  systemctl disable --now nvidia-gpu-heartbeat.timer &>/dev/null || true
  rm -f "${UNIT_DIR}/nvidia-gpu-heartbeat.timer" "${UNIT_DIR}/nvidia-gpu-heartbeat.service"
  rm -rf "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d" "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d"
  info "GPU heartbeat skipped (GPU_HEARTBEAT_ENABLE=0)"
fi

# The listen address and the textfile directory live in the shipped unit. If the
# operator changed either, say so now rather than at 3am during an incident.
grep -q -- "${UNIT_LISTEN_RE}${NODE_EXPORTER_LISTEN}\b" "${UNIT_DIR}/node-exporter.service" \
  || echo "[WARN] NODE_EXPORTER_LISTEN=${NODE_EXPORTER_LISTEN} but the unit says otherwise; edit ${UNIT_DIR}/node-exporter.service" >&2
grep -qF -- "${TEXTFILE_DIR}" "${UNIT_DIR}/node-exporter.service" \
  || echo "[WARN] NODE_EXPORTER_TEXTFILE_DIR=${TEXTFILE_DIR} is not the path in the unit; edit ${UNIT_DIR}/node-exporter.service" >&2

# --- firewall (best effort; a wrong guess must not abort the install) --------
if [[ "${FIREWALL_MANAGE}" == "1" ]]; then
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port="${NODE_EXPORTER_FIREWALL_PORT}" && firewall-cmd --reload \
      && info "opened ${NODE_EXPORTER_FIREWALL_PORT} (firewalld)" \
      || echo "[WARN] could not open the port in firewalld" >&2
  elif command -v ufw &>/dev/null && ufw status &>/dev/null; then
    ufw allow "${NODE_EXPORTER_FIREWALL_PORT}" &>/dev/null \
      && info "opened ${NODE_EXPORTER_FIREWALL_PORT} (ufw)" \
      || echo "[WARN] could not open the port in ufw" >&2
  else
    info "no active nftables/firewalld/ufw manager found; ${NODE_EXPORTER_FIREWALL_PORT} is reachable as-is"
  fi
fi

# --- start ------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now node-exporter
[[ "${GPU_HEARTBEAT_ENABLE}" == "1" ]] && systemctl enable --now nvidia-gpu-heartbeat.timer

# --- verify (do not trust it until the metrics are actually there) -----------
sleep 2
PORT="${NODE_EXPORTER_LISTEN##*:}"
if ! OUT="$(curl -fsS --max-time 15 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null)"; then
  echo "[WARN] could not scrape http://127.0.0.1:${PORT}/metrics" >&2
  systemctl --no-pager --lines 20 status node-exporter >&2 || true
  exit 1
fi

echo
echo "=== verification ==="
printf '  total metric lines : %s\n' "$(grep -c '^[a-z]' <<<"${OUT}")"
for m in node_filesystem_size_bytes node_filesystem_avail_bytes node_hwmon_temp_celsius node_disk_io_time_seconds_total node_systemd_unit_state node_boot_time_seconds node_load1; do
  if grep -q "^${m}" <<<"${OUT}"; then printf '  OK      %s\n' "$m"; else printf '  MISSING %s\n' "$m"; fi
done
# The failure mode this script exists to prevent: / silently absent because
# btrfs (or all of /run) got excluded from the filesystem collector.
if ! grep -q 'mountpoint="/"' <<<"${OUT}"; then
  echo "  [WARN] no metrics for mountpoint=\"/\" -- check the filesystem fs-types/mount-points exclusions"
else
  printf '  OK      mountpoint="/" is reported (fstype %s)\n' "$(sed -nE 's/.*mountpoint="\/".*fstype="([^"]*)".*/\1/p' <<<"${OUT}" | head -1)"
fi
if [[ "${GPU_HEARTBEAT_ENABLE}" == "1" ]]; then
  if grep -q '^node_gpu_last_query_timestamp_seconds' <<<"${OUT}"; then
    printf '  OK      GPU heartbeat file is being read (node_gpu_last_query_timestamp_seconds)\n'
  else
    sleep 3
    curl -fsS --max-time 15 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^node_gpu_last_query_timestamp_seconds' \
      && printf '  OK      GPU heartbeat appeared after the first timer run\n' \
      || printf '  MISSING GPU heartbeat -- check: systemctl status nvidia-gpu-heartbeat.timer / journalctl -u nvidia-gpu-heartbeat.service\n'
  fi
fi

echo
echo "=== done ==="
echo "listening on :${PORT}/metrics"
echo
echo "Next: add this device to the monitoring stack. Edit NODE_TARGETS in the"
echo "Monitoring stack (Portainer) as a name=host:port entry, e.g."
echo "    client-1=<this-host>:9100"
echo "then Update the stack. The name= prefix is what sets the 'host' label the"
echo "Grafana dashboards filter on, so a target without it renders as 'No data'."
echo "Do NOT edit targets/nodes.yml on the server: it is regenerated from"
echo "NODE_TARGETS on every stack start."
