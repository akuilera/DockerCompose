#!/usr/bin/env bash
# =============================================================================
# node_exporter installer (+ the host heartbeat that classifies freezes)
#
# Generic by design: every setting is an environment variable with a sane
# default, so the same script fits every Linux client of the monitoring stack.
# Nothing here is machine specific. Put overrides in a .env next to this script
# (see .env.example) or export them before running; .env stays gitignored.
#
# Three things this script exists to get right, all verified on real hardware:
#
#   1. btrfs is NOT in the filesystem fstype exclusions. Most hardening
#      examples exclude it, which silently blinds you on any btrfs root --
#      including the disk-full alert, silently. Same for excluding all of /run:
#      removable disks mount under /run/media/<user>/<label>, so excluding /run
#      hides them. /run itself is tmpfs and is already filtered by fstype.
#
#   2. The heartbeat exists to catch a HARD LOCK, which a plain scrape cannot
#      see: when the machine stops, the scrape fails and the series just goes
#      stale, so the only way to recover how long it was dead is a local file
#      written by a timer that was not running while it happened. It classifies
#      every gap it finds -- freeze, suspend, reboot, clock step -- because a
#      suspend looks exactly like a freeze from the clock and calling every night
#      a hard freeze is a guaranteed false positive.
#
#   3. The GPU part is OPTIONAL, the heartbeat is not. The heartbeat used to be
#      NVIDIA-only and was therefore skipped entirely on a machine without an
#      NVIDIA card, which is the normal case for a server: no timer, no freeze
#      evidence at all. Now there is one generic heartbeat everywhere and the GPU
#      query is just an optional section of it.
#
# Tested on Fedora Linux. Run as root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration (override via environment, or a local .env) --------------
# shellcheck disable=SC1091
[ -f "${SCRIPT_DIR}/.env" ] && { echo "[+] sourcing ${SCRIPT_DIR}/.env"; set -a; . "${SCRIPT_DIR}/.env"; set +a; }

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[+] $*"; }

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

# --- the host heartbeat -----------------------------------------------------
# Enabled unconditionally. The one thing it exists for -- noticing that the box was
# powered on while nothing ran on it -- does not depend on any hardware, and a
# monitoring agent that quietly installs nothing is worse than no agent at all.
HOST_HEARTBEAT_ENABLE="${HOST_HEARTBEAT_ENABLE:-1}"
# Each new name falls back to the legacy one it replaces, so a .env written for the
# old NVIDIA-only heartbeat keeps working and its values are not silently dropped.
HOST_HEARTBEAT_INTERVAL="${HOST_HEARTBEAT_INTERVAL:-${GPU_HEARTBEAT_INTERVAL:-15s}}"
# Only the GPU section is conditional, and "auto" means exactly what it used to
# mean for the whole heartbeat: query nvidia-smi when it is there, and say so
# plainly (node_gpu_present 0) when it is not. 1 forces the query, 0 skips it.
HOST_HEARTBEAT_GPU_ENABLE="${HOST_HEARTBEAT_GPU_ENABLE:-auto}"
# nvidia-smi is wrapped in timeout(1). On a healthy machine it answers in well
# under a second, so 5s is generous; a lower value means a wedged GPU is reported
# sooner instead of delaying the next run.
HOST_HEARTBEAT_TIMEOUT="${HOST_HEARTBEAT_TIMEOUT:-${GPU_HEARTBEAT_TIMEOUT:-5}}"
# A gap longer than this is an event worth recording. Must comfortably exceed
# HOST_HEARTBEAT_INTERVAL, or every ordinary scheduling hiccup becomes a freeze.
HOST_HEARTBEAT_GAP_THRESHOLD="${HOST_HEARTBEAT_GAP_THRESHOLD:-${GPU_HEARTBEAT_GAP_THRESHOLD:-60}}"
# A gap longer than this is rejected as a corrupt stored value instead of being
# believed. 60 days: no real machine is ever legitimately missing for two months.
HOST_HEARTBEAT_SANITY_GAP="${HOST_HEARTBEAT_SANITY_GAP:-5184000}"
# How long a recorded hard freeze keeps nagging, in seconds (30 days). 0 latches
# forever until the file is cleared by hand.
HOST_HEARTBEAT_MAX_GAP_TTL="${HOST_HEARTBEAT_MAX_GAP_TTL:-${GPU_HEARTBEAT_MAX_GAP_TTL:-2592000}}"
# How long the classified event history is kept, in seconds. 2592000 is 30 days,
# which is the stated goal: an intermittent hang is only useful with a history to
# correlate it against. Bounded by a line cap as well, so a reboot loop cannot
# fill the disk.
HOST_HEARTBEAT_EVENT_RETENTION="${HOST_HEARTBEAT_EVENT_RETENTION:-2592000}"
HOST_HEARTBEAT_EVENT_MAX="${HOST_HEARTBEAT_EVENT_MAX:-5000}"
# Where host-heartbeat-sleep leaves its marker. systemd runs sleep hooks as root
# with no environment of its own, so the installer also writes /etc/default/
# host-heartbeat pointing at this path.
HOST_HEARTBEAT_MARKER_DIR="${HOST_HEARTBEAT_MARKER_DIR:-${TEXTFILE_DIR}}"
HOST_HEARTBEAT_SLEEP_HOOK_DIR="${HOST_HEARTBEAT_SLEEP_HOOK_DIR:-/usr/lib/systemd/system-sleep}"
# How long to wait for the first heartbeat metric before calling it missing. Must
# comfortably exceed the interval: the file has to be written first and then
# scraped, so a wait of one interval is not enough.
HOST_HEARTBEAT_WAIT="${HOST_HEARTBEAT_WAIT:-${GPU_HEARTBEAT_WAIT:-45}}"
# Journal correlation. auto reads the kernel and LACT journals when journalctl is
# present, 1 forces it and 0 turns it off (node_journal_enabled 0). It is
# read-only and cheap, but it is a second journal read per timer tick.
HOST_HEARTBEAT_JOURNAL="${HOST_HEARTBEAT_JOURNAL:-auto}"
# How long a matched journal line keeps node_journal_event_recent at 1, in seconds.
HOST_HEARTBEAT_JOURNAL_RECENT="${HOST_HEARTBEAT_JOURNAL_RECENT:-900}"

FIREWALL_MANAGE="${NODE_EXPORTER_FIREWALL_MANAGE:-1}"
NODE_EXPORTER_FIREWALL_PORT="${NODE_EXPORTER_FIREWALL_PORT:-9100/tcp}"

# Backward compatibility: a .env written for the old NVIDIA-only heartbeat sets
# GPU_HEARTBEAT_*. Those names are read here so an existing deployment does not
# silently change behaviour after an upgrade, but everything new is spelled
# HOST_HEARTBEAT_* and .env.example documents only those.
if [[ -n "${GPU_HEARTBEAT_ENABLE:-}" ]]; then
  HOST_HEARTBEAT_GPU_ENABLE="${GPU_HEARTBEAT_ENABLE}"
  info "[+] legacy GPU_HEARTBEAT_ENABLE=${GPU_HEARTBEAT_ENABLE} honoured for the GPU section (new name: HOST_HEARTBEAT_GPU_ENABLE)"
fi

UNIT_LISTEN_RE='--web\.listen-address='

# --- validation -------------------------------------------------------------
[[ "${HOST_HEARTBEAT_ENABLE}" == "1" || "${HOST_HEARTBEAT_ENABLE}" == "0" ]] \
  || die "HOST_HEARTBEAT_ENABLE must be 0 or 1 (got '${HOST_HEARTBEAT_ENABLE}')"

if [[ "${HOST_HEARTBEAT_GPU_ENABLE}" == "auto" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    HOST_HEARTBEAT_GPU_ENABLE=1
  else
    HOST_HEARTBEAT_GPU_ENABLE=0
    info "no nvidia-smi on PATH; the generic heartbeat is installed and the GPU section stays off"
  fi
fi
[[ "${HOST_HEARTBEAT_GPU_ENABLE}" == "1" || "${HOST_HEARTBEAT_GPU_ENABLE}" == "0" ]] \
  || die "HOST_HEARTBEAT_GPU_ENABLE must be auto, 0 or 1 (got '${HOST_HEARTBEAT_GPU_ENABLE}')"

# A threshold below the interval would report the machine's own scheduling noise
# as a freeze, and the resulting flood is exactly how an operator learns to ignore
# this metric. Refused rather than warned about.
if [[ "${HOST_HEARTBEAT_ENABLE}" == "1" ]] && [[ "${HOST_HEARTBEAT_GAP_THRESHOLD}" -le 0 ]]; then
  die "HOST_HEARTBEAT_GAP_THRESHOLD must be greater than 0"
fi
[[ "${HOST_HEARTBEAT_SANITY_GAP}" -gt "${HOST_HEARTBEAT_GAP_THRESHOLD}" ]] \
  || die "HOST_HEARTBEAT_SANITY_GAP (${HOST_HEARTBEAT_SANITY_GAP}) must be greater than HOST_HEARTBEAT_GAP_THRESHOLD (${HOST_HEARTBEAT_GAP_THRESHOLD}), or no gap could ever reach the sanity check"
[[ "${HOST_HEARTBEAT_JOURNAL}" == "auto" || "${HOST_HEARTBEAT_JOURNAL}" == "0" || "${HOST_HEARTBEAT_JOURNAL}" == "1" ]] \
  || die "HOST_HEARTBEAT_JOURNAL must be auto, 0 or 1 (got '${HOST_HEARTBEAT_JOURNAL}')"
[[ "${HOST_HEARTBEAT_JOURNAL_RECENT}" =~ ^[0-9]+$ ]] \
  || die "HOST_HEARTBEAT_JOURNAL_RECENT must be a whole number of seconds (got '${HOST_HEARTBEAT_JOURNAL_RECENT}')"

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

for f in node-exporter.service host-heartbeat.sh host-heartbeat.service host-heartbeat.timer host-heartbeat-sleep; do
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

if [[ "${HOST_HEARTBEAT_ENABLE}" == "1" ]]; then
  install -m 0755 "${SCRIPT_DIR}/host-heartbeat.sh" "${INSTALL_DIR}/host-heartbeat"
  install -m 0644 "${SCRIPT_DIR}/host-heartbeat.service" "${UNIT_DIR}/host-heartbeat.service"
  install -m 0644 "${SCRIPT_DIR}/host-heartbeat.timer" "${UNIT_DIR}/host-heartbeat.timer"
  install -d -m 0755 "${UNIT_DIR}/host-heartbeat.timer.d" "${UNIT_DIR}/host-heartbeat.service.d"
  # Keep the interval in one place. Both timer keys are set: a drop-in that only
  # overrides OnUnitActiveSec leaves the shipped OnActiveSec in place, and one that
  # only sets OnActiveSec loses the self-pacing. Regenerated on every run, so keep
  # local edits in a differently named drop-in (20-local.conf) -- systemd applies
  # them in lexical order and the last one to set a key wins.
  cat > "${UNIT_DIR}/host-heartbeat.timer.d/10-interval.conf" <<EOF
# Generated by install-node-exporter.sh. Regenerated on every run.
[Timer]
# Both are required. OnUnitActiveSec alone never fires on a fresh boot: it is
# relative to a previous activation that has not happened yet, so the timer
# reports "active" and schedules nothing.
OnActiveSec=${HOST_HEARTBEAT_INTERVAL}
OnUnitActiveSec=${HOST_HEARTBEAT_INTERVAL}
EOF
  # Everything else the script reads, in the same place, so tuning the heartbeat
  # never means editing a unit file that the next install would overwrite.
  cat > "${UNIT_DIR}/host-heartbeat.service.d/10-env.conf" <<EOF
# Generated by install-node-exporter.sh. Regenerated on every run.
[Service]
Environment=NODE_HOST_TEXTFILE_DIR=${TEXTFILE_DIR}
Environment=NODE_HOST_GAP_THRESHOLD=${HOST_HEARTBEAT_GAP_THRESHOLD}
Environment=NODE_HOST_SANITY_GAP=${HOST_HEARTBEAT_SANITY_GAP}
Environment=NODE_HOST_MAX_GAP_TTL=${HOST_HEARTBEAT_MAX_GAP_TTL}
Environment=NODE_HOST_EVENT_RETENTION=${HOST_HEARTBEAT_EVENT_RETENTION}
Environment=NODE_HOST_EVENT_MAX=${HOST_HEARTBEAT_EVENT_MAX}
Environment=NODE_HOST_SUSPEND_MARKER=${HOST_HEARTBEAT_MARKER_DIR}/.hb_suspend.marker
Environment=NODE_HOST_GPU=${HOST_HEARTBEAT_GPU_ENABLE}
Environment=NODE_GPU_TIMEOUT=${HOST_HEARTBEAT_TIMEOUT}
Environment=NODE_HOST_JOURNAL=${HOST_HEARTBEAT_JOURNAL}
Environment=NODE_HOST_JOURNAL_RECENT=${HOST_HEARTBEAT_JOURNAL_RECENT}
EOF
  info "installed host heartbeat (${HOST_HEARTBEAT_INTERVAL}, gap threshold ${HOST_HEARTBEAT_GAP_THRESHOLD}s, GPU section ${HOST_HEARTBEAT_GPU_ENABLE}, journal ${HOST_HEARTBEAT_JOURNAL})"

  # The sleep hook is what keeps an overnight suspend from being reported as a
  # hard freeze, so its absence is not a cosmetic problem and it is installed
  # unconditionally with the heartbeat. There is no way to detect a missing hook
  # after the fact, because the failure is a suspend being classified as a freeze.
  install -d -m 0755 "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}"
  install -m 0755 -o root -g root "${SCRIPT_DIR}/host-heartbeat-sleep" \
    "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep"
  # systemd runs sleep hooks with no environment of its own, so the marker path has
  # to be communicated out of band. Only two keys, read with a whitelist.
  install -d -m 0755 /etc/default
  cat > /etc/default/host-heartbeat <<EOF
# Generated by install-node-exporter.sh. Regenerated on every run.
# Read by ${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep, which cannot receive an environment from systemd.
NODE_EXPORTER_STATE_DIR=${TEXTFILE_DIR}
NODE_HOST_SUSPEND_MARKER=${HOST_HEARTBEAT_MARKER_DIR}/.hb_suspend.marker
EOF
  chmod 0644 /etc/default/host-heartbeat
  info "installed sleep hook ${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep"
  echo "[WARN] the sleep hook only sees logind/systemd-mediated sleeps. A suspend requested" >&2
  echo "       straight from the embedded controller, or a hand-written" >&2
  echo "       'echo mem > /sys/power/state', bypasses it and is still classified freeze." >&2
else
  systemctl disable --now host-heartbeat.timer &>/dev/null || true
  rm -f "${UNIT_DIR}/host-heartbeat.timer" "${UNIT_DIR}/host-heartbeat.service" \
        "${INSTALL_DIR}/host-heartbeat" "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep"
  rm -rf "${UNIT_DIR}/host-heartbeat.timer.d" "${UNIT_DIR}/host-heartbeat.service.d"
  info "heartbeat skipped (HOST_HEARTBEAT_ENABLE=0); this host will report no freeze evidence"
fi

# --- migration from the NVIDIA-only heartbeat -------------------------------
# The old units are removed instead of being left installed alongside the new ones.
# Two timers measuring the same gap and both writing nvidia_gpu.maxgap is a race,
# and a race in the one artefact that is the only hard-freeze evidence is not
# something to leave in place for a future incident to discover.
for f in "${UNIT_DIR}/nvidia-gpu-heartbeat.service" "${UNIT_DIR}/nvidia-gpu-heartbeat.timer" \
         "${INSTALL_DIR}/nvidia-gpu-heartbeat"; do
  [[ -e "${f}" ]] && { ts=$(date +%Y%m%d%H%M%S); mv -f "${f}" "${f}.migrated-${ts}.bak"; info "migrated ${f} to ${f}.migrated-${ts}.bak"; }
done
for d in "${UNIT_DIR}/nvidia-gpu-heartbeat.timer.d" "${UNIT_DIR}/nvidia-gpu-heartbeat.service.d"; do
  [[ -d "${d}" ]] && { ts=$(date +%Y%m%d%H%M%S); mv -f "${d}" "${d}.migrated-${ts}.bak"; info "migrated ${d} to ${d}.migrated-${ts}.bak"; }
done
systemctl disable --now nvidia-gpu-heartbeat.timer &>/dev/null || true
# The old state file held one bare epoch. The new script needs a schema version, a
# boot id and an uptime alongside it, and it cannot trust a value whose provenance
# it does not know, so it would discard that file anyway. Seeding the new state from
# it would instead produce a gap spanning the whole upgrade window, which is
# measured in minutes and says nothing about the machine's health.
if [[ -e "${TEXTFILE_DIR}/nvidia_gpu.lastrun" ]]; then
  ts=$(date +%Y%m%d%H%M%S); mv -f "${TEXTFILE_DIR}/nvidia_gpu.lastrun" "${TEXTFILE_DIR}/nvidia_gpu.lastrun.migrated-${ts}.bak"
  info "migrated ${TEXTFILE_DIR}/nvidia_gpu.lastrun to .bak (superseded; the first run rebaselines instead)"
fi
# The latch is the opposite case and is deliberately KEPT. It is the same file with
# the same "<epoch> <gap>" format that the new heartbeat reads and writes, so it
# needs no migration and it is real evidence of a hang somebody has not finished
# investigating. It is not silently deleted, and it is not silently trusted either:
# the old script could not tell a suspend from a freeze, so this file may well
# contain an ordinary night of sleep.
if [[ -e "${TEXTFILE_DIR}/nvidia_gpu.maxgap" ]]; then
  info "kept ${TEXTFILE_DIR}/nvidia_gpu.maxgap (same file and format, now frozen-freeze-only)"
  echo "[WARN] it was written by the old script, which classified an ordinary SUSPEND as a freeze." >&2
  echo "       Read it before trusting it: '<epoch> <seconds>'. If that gap was a night of" >&2
  echo "       sleep, delete the file and the next alert you get will be a real freeze." >&2
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
if [[ "${HOST_HEARTBEAT_ENABLE}" == "1" ]]; then
  systemctl enable --now host-heartbeat.timer
  # Nudge the service once so verification is not blocked on the timer being correct
  # in order to prove the timer is correct. --no-block: nvidia-smi can take a few
  # seconds and nothing here should hang on it.
  systemctl start --no-block host-heartbeat.service || true
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

if [[ "${HOST_HEARTBEAT_ENABLE}" == "1" ]]; then
  # The generic metric, polled first and on its own. node_heartbeat_schema_version is
  # written on every run including the very first, which makes it the one heartbeat
  # series that can be waited for without racing the first classification.
  hb_ok=0
  hb_deadline=$(( SECONDS + HOST_HEARTBEAT_WAIT ))
  while (( SECONDS < hb_deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
         | grep -q '^node_heartbeat_schema_version'; then
      hb_ok=1; break
    fi
    sleep 1
  done
  if (( hb_ok )); then
    printf '  OK      host heartbeat file is being read (node_heartbeat_schema_version)\n'
  else
    printf '  MISSING host heartbeat after %ss.\n' "${HOST_HEARTBEAT_WAIT}"
    echo "           The timer must schedule a first run, not just repeat one:"
    echo "             systemctl list-timers host-heartbeat.timer   # NEXT/LAST must not be '-'"
    echo "             journalctl -u host-heartbeat.service -n 20 --no-pager"
    echo "             systemctl cat host-heartbeat.timer host-heartbeat.service"
  fi
  # Then the GPU-specific one. "auto" is checked too, because auto on a machine
  # that does have a card is exactly the case where a silent failure would go
  # unnoticed: the section is supposed to be answering and nothing would say so.
  if [[ "${HOST_HEARTBEAT_GPU_ENABLE}" != "0" ]]; then
    gpu_ok=0
    gpu_deadline=$(( SECONDS + HOST_HEARTBEAT_WAIT ))
    while (( SECONDS < gpu_deadline )); do
      if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
           | grep -q '^node_gpu_last_query_timestamp_seconds'; then
        gpu_ok=1; break
      fi
      sleep 1
    done
    if (( gpu_ok )); then
      printf '  OK      GPU section is being read (node_gpu_last_query_timestamp_seconds)\n'
    elif [[ "${HOST_HEARTBEAT_GPU_ENABLE}" == "auto" ]] && ! command -v nvidia-smi &>/dev/null; then
      printf '  --      no nvidia-smi on this host, node_gpu_present is 0 (expected for auto)\n'
    else
      printf '  MISSING GPU heartbeat after %ss.\n' "${HOST_HEARTBEAT_WAIT}"
      echo "             journalctl -u host-heartbeat.service -n 20 --no-pager"
      echo "             command -v nvidia-smi && nvidia-smi -L"
    fi
  else
    printf '  --      GPU section disabled (HOST_HEARTBEAT_GPU_ENABLE=0), node_gpu_present will be 0\n'
  fi
  # Journal correlation. Only meaningful when the section is on and journalctl is
  # actually present; otherwise the script reports node_journal_enabled 0 on purpose.
  if [[ "${HOST_HEARTBEAT_JOURNAL}" == "0" ]] || ! command -v journalctl &>/dev/null; then
    printf '  --      journal correlation off (HOST_HEARTBEAT_JOURNAL=%s, journalctl %s)\n' \
      "${HOST_HEARTBEAT_JOURNAL}" "$(command -v journalctl &>/dev/null && echo present || echo absent)"
  else
    jr_ok=0
    jr_deadline=$(( SECONDS + HOST_HEARTBEAT_WAIT ))
    while (( SECONDS < jr_deadline )); do
      if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
           | grep -q '^node_journal_last_scan_timestamp_seconds'; then
        jr_ok=1; break
      fi
      sleep 1
    done
    if (( jr_ok )); then
      printf '  OK      journal correlation is being read (node_journal_last_scan_timestamp_seconds)\n'
    else
      printf '  MISSING journal metrics after %ss.\n' "${HOST_HEARTBEAT_WAIT}"
      echo "             journalctl -u host-heartbeat.service -n 20 --no-pager"
      echo "             journalctl -k -o short-unix -n 5 --no-pager   # does the kernel journal read at all?"
    fi
  fi
  # The sleep hook is the difference between a suspend and a reported freeze, and
  # nothing about a healthy scrape will tell the operator it is missing.
  if [[ -x "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep" ]]; then
    printf '  OK      sleep hook present (%s)\n' "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep"
  else
    printf '  MISSING sleep hook %s -- suspends will be reported as freezes\n' "${HOST_HEARTBEAT_SLEEP_HOOK_DIR}/host-heartbeat-sleep"
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
