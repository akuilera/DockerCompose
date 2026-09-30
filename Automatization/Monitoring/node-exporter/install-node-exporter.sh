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

# "auto" installs the heartbeat only when nvidia-smi is actually present, so a
# machine without an NVIDIA card does not end up with a timer whose only honest
# metric is node_gpu_present 0. Use 1 to force it on, 0 to force it off.
GPU_HEARTBEAT_ENABLE="${GPU_HEARTBEAT_ENABLE:-auto}"
GPU_HEARTBEAT_INTERVAL="${GPU_HEARTBEAT_INTERVAL:-15s}"
GPU_HEARTBEAT_TIMEOUT="${GPU_HEARTBEAT_TIMEOUT:-5}"
# How long to wait for the first heartbeat metric before calling it missing.
# Must comfortably exceed GPU_HEARTBEAT_INTERVAL: the file has to be written
# first and then scraped, so a fixed sleep is either too short or a waste.
GPU_HEARTBEAT_WAIT="${GPU_HEARTBEAT_WAIT:-45}"
# How long a recorded hard freeze keeps nagging, in seconds (30 days).
GPU_HEARTBEAT_MAX_GAP_TTL="${GPU_HEARTBEAT_MAX_GAP_TTL:-2592000}"

FIREWALL_MANAGE="${NODE_EXPORTER_FIREWALL_MANAGE:-1}"
NODE_EXPORTER_FIREWALL_PORT="${NODE_EXPORTER_FIREWALL_PORT:-9100/tcp}"

UNIT_LISTEN_RE='--web\.listen-address='
die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[+] $*"; }

# --- GPU autodetection ------------------------------------------------------
if [[ "${GPU_HEARTBEAT_ENABLE}" == "auto" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_HEARTBEAT_ENABLE=1
  else
    GPU_HEARTBEAT_ENABLE=0
    info "no nvidia-smi on PATH; the GPU heartbeat will not be installed"
  fi
fi
[[ "${GPU_HEARTBEAT_ENABLE}" == "1" || "${GPU_HEARTBEAT_ENABLE}" == "0" ]] \
  || die "GPU_HEARTBEAT_ENABLE must be auto, 0 or 1 (got '${GPU_HEARTBEAT_ENABLE}')"

# Report what is filtering on this host, without touching it. Printed at the end
# so the operator can tell a closed port from a port nobody is listening on.
active_filtering_services() {
  local found=() u
  for u in firewalld nftables ufw iptables pf; do
    systemctl is-active --quiet "$u" 2>/dev/null && found+=("$u")
  done
  printf '%s' "${found[*]:-}"
}

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
  install -d -m 0755 "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d" "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d"
  # Keep the interval and timeout in one place. Both timer keys are set: a drop-in
  # that only overrides OnUnitActiveSec leaves the shipped OnActiveSec in place,
  # and one that only sets OnActiveSec loses the self-pacing. Regenerated on every
  # run, so keep local edits in a differently named drop-in (20-local.conf) --
  # systemd applies them in lexical order and the last one to set a key wins.
  cat > "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d/10-interval.conf" <<EOF
# Generated by install-node-exporter.sh. Regenerated on every run.
[Timer]
# Both are required. OnUnitActiveSec alone never fires on a fresh boot: it is
# relative to a previous activation that has not happened yet, so the timer
# reports "active" and schedules nothing.
OnActiveSec=${GPU_HEARTBEAT_INTERVAL}
OnUnitActiveSec=${GPU_HEARTBEAT_INTERVAL}
EOF
  cat > "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d/10-env.conf" <<EOF
# Generated by install-node-exporter.sh. Regenerated on every run.
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
# Only the per-port managers are touched. Raw nftables/iptables rulesets are left
# alone on purpose: editing a ruleset you did not write is how you lock yourself
# out of your own machine.
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
    info "no active firewalld or ufw manager; nothing was changed"
  fi
fi

# --- start ------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now node-exporter
if [[ "${GPU_HEARTBEAT_ENABLE}" == "1" ]]; then
  systemctl enable --now nvidia-gpu-heartbeat.timer
  # Nudge the service once so verification is not blocked on the timer being
  # correct in order to prove the timer is correct. --no-block: nvidia-smi can
  # take a few seconds and nothing here should hang on it.
  systemctl start --no-block nvidia-gpu-heartbeat.service || true
fi

# --- verify (do not trust it until the metrics are actually there) -----------
# Poll against a deadline rather than sleeping a fixed amount: a fixed sleep is
# too short on a loaded machine and a waste on a fast one.
PORT="${NODE_EXPORTER_LISTEN##*:}"
OUT=""
deadline=$(( SECONDS + 30 ))
until OUT="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null)" && [[ -n "${OUT}" ]]; do
  if (( SECONDS >= deadline )); then
    echo "[WARN] could not scrape http://127.0.0.1:${PORT}/metrics within 30s" >&2
    systemctl --no-pager --lines 20 status node-exporter >&2 || true
    exit 1
  fi
  sleep 1
done

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
  # The order of labels inside a series is not guaranteed, so take fstype from
  # the matching line rather than assuming it follows mountpoint.
  fs_line="$(grep -m1 'mountpoint="/"' <<<"${OUT}")"
  fs_type="$(sed -nE 's/.*fstype="([^"]*)".*/\1/p' <<<"${fs_line}")"
  printf '  OK      mountpoint="/" is reported (fstype %s)\n' "${fs_type:-unknown}"
fi
if [[ "${GPU_HEARTBEAT_ENABLE}" == "1" ]]; then
  hb_ok=0
  hb_deadline=$(( SECONDS + GPU_HEARTBEAT_WAIT ))
  while (( SECONDS < hb_deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
         | grep -q '^node_gpu_last_query_timestamp_seconds'; then
      hb_ok=1; break
    fi
    sleep 1
  done
  if (( hb_ok )); then
    printf '  OK      GPU heartbeat file is being read (node_gpu_last_query_timestamp_seconds)\n'
  else
    printf '  MISSING GPU heartbeat after %ss.\n' "${GPU_HEARTBEAT_WAIT}"
    echo "           The timer must schedule a first run, not just repeat one:"
    echo "             systemctl list-timers nvidia-gpu-heartbeat.timer   # NEXT/LAST must not be '-'"
    echo "             journalctl -u nvidia-gpu-heartbeat.service -n 20 --no-pager"
  fi
fi

echo
echo "=== done ==="
echo "listening on :${PORT}/metrics"
echo
echo "=== port ${PORT}/tcp reachability ==="
if command -v ss &>/dev/null; then
  if ss -lnt 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    echo "  listening : yes"
  else
    echo "  listening : NO -- nothing is bound to ${PORT}, so nothing can reach it"
  fi
else
  echo "  listening : unknown (install iproute2 to get ss)"
fi
if [[ -z "$(active_filtering_services)" ]]; then
  echo "  filtering : none of firewalld/nftables/ufw/iptables/pf is active"
else
  echo "  filtering : $(active_filtering_services)"
fi
cat <<EOF
  Reachability from the monitoring server is deliberately NOT asserted here: a
  local script cannot know it, and the two most common causes are invisible from
  this machine:
    * an application firewall / network monitor (Portmaster and similar) filters
      per process, so every service listed above reads "inactive" while it
      blocks the connection;
    * an upstream router, a hypervisor security group, or a firewall on the
      machine that runs Prometheus.
  If the target shows down, test it from the monitoring server:
      curl -s --max-time 5 http://<this-host>:${PORT}/metrics | head -1
  and compare the result with the filtering list above.
EOF
echo
echo "Next: register this device in the monitoring stack. In the repository"
echo "clone on the server create"
echo "${PATH_TO_COMPOSE:-<compose-root>}/Automatization/Monitoring/Devices/<device>/.env"
echo "following the template in the repo (Automatization/Monitoring/Devices.example/example/.env.example), e.g."
echo "    DEVICE_NAME=\"<device display name>\""
echo "    DEVICE_ADDR=<this-host>:${PORT}"
echo "    DEVICE_BATTERY=0      # set 1 if this machine has a battery"
echo "    DEVICE_GPU=0          # set 1 if this machine has a discrete NVIDIA GPU"
echo "then Update the stack. DEVICE_NAME sets the 'host' label the Grafana"
echo "dashboards filter on, so a missing or mismatched name renders as 'No data'."
echo "Do NOT edit targets/nodes.yml on the server: it is regenerated from the"
echo "Devices/ registry on every stack start."
