#!/usr/bin/env bash
# =============================================================================
# Peer watchdog installer.
#
# Installs the peer reachability watchdog on the ALWAYS-ON observing machine --
# the one that runs the Prometheus stack -- so it records the downtime of every
# other machine in the fleet from the outside, with its own clock and its own
# disk. Read the WHY block at the top of peer-watchdog.sh before enabling it: the
# short version is that a machine which has frozen cannot report its own
# downtime, so somebody else has to, and the somebody else must be a machine that
# is not going to freeze.
#
# Generic by design: every setting is an environment variable with a sane default,
# so the same script fits any Linux host of the monitoring stack. Nothing here is
# machine specific. Put overrides in peer-watchdog.env (or the shared .env) next
# to this script; see peer-watchdog.env.example. Both names are local-only files.
#
# Two conventions this installer keeps on purpose:
#   * It does NOT ask anything. No prompts, no TTY games: it is meant to be run
#     from a provisioning script or a copy-paste line, so every decision is a
#     variable and every default is safe to accept.
#   * It VERIFIES instead of trusting. Enabling a timer and walking away is how a
#     monitoring component fails silently for a month; every step below ends with
#     a check against a deadline, and a failure prints the exact commands to run.
#
# Tested on Fedora Linux. Run as root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration (override via environment, or a local settings file) --------
# peer-watchdog.env is this installer's own file; .env is the shared one the
# node_exporter installer reads. Both are loaded when present, own file first, so
# a peer-only override does not require touching the shared settings.
# shellcheck disable=SC1091
for f in "${SCRIPT_DIR}/peer-watchdog.env" "${SCRIPT_DIR}/.env"; do
  [ -f "$f" ] && { echo "[+] sourcing ${f}"; set -a; . "$f"; set +a; }
done

PEER_INTERVAL="${PEER_WATCHDOG_INTERVAL:-60s}"
PEER_TIMEOUT="${PEER_WATCHDOG_TIMEOUT:-5}"
PEER_CONCURRENCY="${PEER_WATCHDOG_CONCURRENCY:-8}"
PEER_CONFIG="${PEER_WATCHDOG_CONFIG:-/etc/peer-watchdog/peers.conf}"
PEER_HISTORY_RETENTION="${PEER_WATCHDOG_HISTORY_RETENTION:-2592000}"
PEER_HISTORY_MAX_LINES="${PEER_WATCHDOG_HISTORY_MAX_LINES:-5000}"
PEER_WAIT="${PEER_WATCHDOG_WAIT:-90}"
PEER_SEED_CONFIG="${PEER_WATCHDOG_SEED_CONFIG:-1}"
PEER_USER="${PEER_WATCHDOG_USER:-node_exporter}"
PEER_GROUP="${PEER_WATCHDOG_GROUP:-${PEER_WATCHDOG_USER:-node_exporter}}"
PEER_INSTALL_DIR="${PEER_WATCHDOG_INSTALL_DIR:-/usr/local/bin}"
PEER_UNIT_DIR="${PEER_WATCHDOG_UNIT_DIR:-/etc/systemd/system}"
# The textfile directory is the node_exporter one, not a directory of our own:
# the whole point is that Prometheus reads these metrics through the scrape that
# already happens, with no extra container and no extra port.
PEER_TEXTFILE_DIR="${PEER_WATCHDOG_TEXTFILE_DIR:-${NODE_EXPORTER_TEXTFILE_DIR:-${NODE_EXPORTER_STATE_DIR:-/var/lib/node_exporter}/textfile_collector}}"
PEER_STATE_DIR="${PEER_WATCHDOG_STATE_DIR:-/var/lib/peer-watchdog}"
# Only used to scrape the local exporter during verification. Reuses the
# node_exporter setting when there is one, so the two installers cannot disagree.
PEER_LOCAL_LISTEN="${PEER_WATCHDOG_LOCAL_LISTEN:-${NODE_EXPORTER_LISTEN:-:9100}}"

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[+] $*"; }

# systemd durations are "60s"/"2min"; the arithmetic below needs seconds.
to_seconds() {
  # systemd durations are "60s", "2min", "1h", "5m", "1d" ... The arithmetic below
  # needs seconds, so it is parsed here. The suffixes accepted here are a SUPERSET
  # of what the regex used to allow on purpose: this function must accept
  # everything systemd accepts for OnActiveSec, otherwise the installer rejects a
  # value the timer itself would have been perfectly happy with, and the operator
  # is told their own interval is invalid. Note "ms"/"us" are matched before "m"
  # so 500ms is milliseconds and not 500 minutes; the trailing $ anchor is what
  # stops a partial match in the other direction.
  local v="$1" n u
  [[ "$v" =~ ^([0-9]+)(ms|us|s|sec|min|m|h|d)?$ ]] || { printf '0'; return 1; }
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]:-s}"
  case "$u" in
    s|sec)      printf '%s' "$n" ;;
    m|min)      printf '%s' "$(( n * 60 ))" ;;
    h)          printf '%s' "$(( n * 3600 ))" ;;
    d)          printf '%s' "$(( n * 86400 ))" ;;
    ms|us)      printf '0'; return 1 ;;   # sub-second makes no sense for a timer interval
  esac
}

# --- pre-flight --------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "run with sudo or as root"
command -v curl >/dev/null 2>&1 || die "curl is required (e.g. dnf install curl)"
command -v logger >/dev/null 2>&1 || echo "[WARN] logger not found; events will go to stderr only" >&2

for f in peer-watchdog.sh peer-watchdog.service peer-watchdog.timer; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || die "missing ${SCRIPT_DIR}/${f} (run from the repo copy of this folder)"
done

INTERVAL_S="$(to_seconds "${PEER_INTERVAL}")" \
  || die "PEER_WATCHDOG_INTERVAL must be ONE systemd duration like 60s, 5min or 1h (got '${PEER_INTERVAL}'; compound forms such as 1h30min are not accepted)"
[[ "${INTERVAL_S}" -ge 5 ]] || die "PEER_WATCHDOG_INTERVAL=${PEER_INTERVAL} is too short to be useful"
[[ "${PEER_TIMEOUT}" =~ ^[0-9]+$ ]] || die "PEER_WATCHDOG_TIMEOUT must be whole seconds (got '${PEER_TIMEOUT}')"
# The interval has to outlast the probe, or a run can still be in flight when the
# next tick arrives and the timer's pacing (OnUnitActiveSec) is the only thing
# keeping them from piling up. Say it now rather than discovering it at 3am.
if [[ "${INTERVAL_S}" -le "${PEER_TIMEOUT}" ]]; then
  echo "[WARN] PEER_WATCHDOG_INTERVAL=${PEER_INTERVAL} is not greater than PEER_WATCHDOG_TIMEOUT=${PEER_TIMEOUT}s" >&2
  echo "       A run can then still be in flight when the next tick fires. Raise the interval." >&2
fi

# --- account and directories -------------------------------------------------
# The watchdog writes into the node_exporter textfile directory, so it needs the
# node_exporter account to exist even on a host where this script is installed
# first. Created the same way the node_exporter installer creates it, so whichever
# runs first wins and the other one finds it already there.
if ! id "${PEER_USER}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${PEER_USER}"
  info "created system user ${PEER_USER}"
fi
getent group "${PEER_GROUP}" >/dev/null || groupadd --system "${PEER_GROUP}"

install -d -m 0755 "${PEER_CONFIG%/*}"
install -d -o "${PEER_USER}" -g "${PEER_GROUP}" -m 0755 "${PEER_STATE_DIR}"
install -d -o "${PEER_USER}" -g "${PEER_GROUP}" -m 0755 "${PEER_TEXTFILE_DIR}"
info "state dir: ${PEER_STATE_DIR} (owned by ${PEER_USER})"
info "textfile dir: ${PEER_TEXTFILE_DIR} (owned by ${PEER_USER})"

# --- peer config -------------------------------------------------------------
# Seeded with placeholders only, and only when it does not exist: this file holds
# the fleet's addresses, which are personal data, so it lives outside the
# repository on this machine and is never committed. Seeding is skipped rather than
# merged, because a merge can silently resurrect a peer the operator deleted.
if [[ ! -f "${PEER_CONFIG}" && "${PEER_SEED_CONFIG}" == "1" ]]; then
  cat > "${PEER_CONFIG}" <<'EOF'
# Peers watched from THIS machine. One per line: name=host:port
#
# Only reachable hosts belong here. The watchdog records a down window for every
# peer that does not answer, so a peer you cannot reach from this machine turns
# into a permanent outage record that pollutes the history forever.
#
# The name becomes a metric label, so keep it short, stable and free of spaces.
# It is the join key against the rest of the monitoring stack, so renaming it
# orphans the history of that peer: the old windows stay on disk under the old
# name and the new name starts from zero.
#
# <peer-name>=<host>:<port>
EOF
  chmod 0644 "${PEER_CONFIG}"
  info "created ${PEER_CONFIG} with placeholders; add one 'name=host:port' line per peer"
fi
if [[ ! -f "${PEER_CONFIG}" ]]; then
  info "no peer config at ${PEER_CONFIG} (PEER_WATCHDOG_SEED_CONFIG=0); the watchdog will report 0 peers"
fi

# --- units -------------------------------------------------------------------
install -m 0755 "${SCRIPT_DIR}/peer-watchdog.sh" "${PEER_INSTALL_DIR}/peer-watchdog"
install -m 0644 "${SCRIPT_DIR}/peer-watchdog.service" "${PEER_UNIT_DIR}/peer-watchdog.service"
install -m 0644 "${SCRIPT_DIR}/peer-watchdog.timer" "${PEER_UNIT_DIR}/peer-watchdog.timer"
install -d -m 0755 "${PEER_UNIT_DIR}/peer-watchdog.timer.d" "${PEER_UNIT_DIR}/peer-watchdog.service.d"

# Both timer keys are always written, for the same reason the shipped timer has
# both: a drop-in that only overrides OnUnitActiveSec leaves the shipped
# OnActiveSec in place, and on a freshly booted machine that combination
# schedules nothing. Regenerated on every run, so keep local edits in a
# differently named drop-in (20-local.conf): systemd applies them in lexical
# order and the last one to set a key wins.
cat > "${PEER_UNIT_DIR}/peer-watchdog.timer.d/10-interval.conf" <<EOF
# Generated by install-peer-watchdog.sh. Regenerated on every run.
[Timer]
# Both are required. OnUnitActiveSec alone never fires on a fresh boot: it is
# relative to a previous activation that has not happened yet, so the timer
# reports "active" and schedules nothing.
OnActiveSec=${PEER_INTERVAL}
OnUnitActiveSec=${PEER_INTERVAL}
EOF

# Every path and tuning knob the service reads is written here, INCLUDING the two
# ReadWritePaths, because ProtectSystem=strict makes everything outside them
# read-only. Writing the paths in two places that can drift is how this unit ends
# up failing with a permission error that only shows up under the timer, so they
# come from the same variables here.
cat > "${PEER_UNIT_DIR}/peer-watchdog.service.d/10-env.conf" <<EOF
# Generated by install-peer-watchdog.sh. Regenerated on every run.
[Service]
Environment=PEER_WATCHDOG_TEXTFILE_DIR=${PEER_TEXTFILE_DIR}
Environment=PEER_WATCHDOG_STATE_DIR=${PEER_STATE_DIR}
Environment=PEER_WATCHDOG_CONFIG=${PEER_CONFIG}
Environment=PEER_WATCHDOG_TIMEOUT=${PEER_TIMEOUT}
Environment=PEER_WATCHDOG_CONCURRENCY=${PEER_CONCURRENCY}
Environment=PEER_WATCHDOG_HISTORY_RETENTION=${PEER_HISTORY_RETENTION}
Environment=PEER_WATCHDOG_HISTORY_MAX_LINES=${PEER_HISTORY_MAX_LINES}
ReadWritePaths=${PEER_TEXTFILE_DIR} ${PEER_STATE_DIR}
EOF
info "installed peer watchdog (${PEER_INTERVAL}, timeout ${PEER_TIMEOUT}s, concurrency ${PEER_CONCURRENCY})"

# The textfile directory has to be the one the exporter is actually reading, or
# every metric this watchdog produces is written and never scraped. That is a
# silent failure, so it is checked here rather than left for the verification
# step to guess about.
UNIT_EXPORTER="${PEER_UNIT_DIR}/node-exporter.service"
if [[ -f "${UNIT_EXPORTER}" ]]; then
  grep -qF -- "${PEER_TEXTFILE_DIR}" "${UNIT_EXPORTER}" \
    || echo "[WARN] ${UNIT_EXPORTER} does not mention ${PEER_TEXTFILE_DIR}; the exporter may be reading another textfile directory and will never serve these metrics" >&2
else
  echo "[WARN] ${UNIT_EXPORTER} not found; is node_exporter installed on this host? The watchdog will run but nothing will scrape it" >&2
fi

# --- start -------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now peer-watchdog.timer
# Nudge the service once so verification does not depend on the timer being
# correct in order to prove the timer is correct. --no-block: the first run waits
# for a probe timeout and nothing here should hang on it.
systemctl start --no-block peer-watchdog.service || true

# --- verify (do not trust it until the metrics are actually there) -----------
# Polled against a deadline rather than slept for: a fixed sleep is too short on a
# loaded machine and a waste on a fast one. Two layers are checked separately on
# purpose, because they fail for unrelated reasons and the operator needs to know
# WHICH one broke: the file existing means the script ran, the metric appearing on
# /metrics means the exporter is reading that file.
PROM_FILE="${PEER_TEXTFILE_DIR}/peer_watchdog.prom"
PORT="${PEER_LOCAL_LISTEN##*:}"
LIVENESS='node_watchdog_last_run_timestamp_seconds'

file_ok=0
deadline=$(( SECONDS + PEER_WAIT ))
until [[ -s "${PROM_FILE}" ]] && grep -q "^${LIVENESS}" "${PROM_FILE}" 2>/dev/null; do
  if (( SECONDS >= deadline )); then break; fi
  sleep 1
done
[[ -s "${PROM_FILE}" ]] && grep -q "^${LIVENESS}" "${PROM_FILE}" 2>/dev/null && file_ok=1

export_ok=0
if (( file_ok )); then
  deadline=$(( SECONDS + 30 ))
  until curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q "^${LIVENESS}"; do
    if (( SECONDS >= deadline )); then break; fi
    sleep 1
  done
  curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q "^${LIVENESS}" && export_ok=1
fi

echo
echo "=== verification ==="
if (( file_ok )); then
  peers_configured="$(awk '/^node_watchdog_peers_configured/ { print $2 }' "${PROM_FILE}" 2>/dev/null)"
  peers_up="$(awk '/^node_watchdog_peers_up/ { print $2 }' "${PROM_FILE}" 2>/dev/null)"
  printf '  OK      %s is being written\n' "$PROM_FILE"
  printf '  OK      %s present (peers configured %s, up %s)\n' "${LIVENESS}" "${peers_configured:-?}" "${peers_up:-?}"
else
  printf '  MISSING %s was not written within %ss\n' "$PROM_FILE" "$PEER_WAIT"
  echo "           The timer must schedule a first run, not just repeat one:"
  echo "             systemctl list-timers peer-watchdog.timer    # NEXT/LAST must not be '-'"
  echo "             systemctl --no-pager status peer-watchdog.service"
  echo "             journalctl -u peer-watchdog.service -n 30 --no-pager"
  echo "           Then run the script by hand, which shows the failure without the unit in the way:"
  echo "             sudo -u ${PEER_USER} ${PEER_INSTALL_DIR}/peer-watchdog"
  echo "           and check it can write both directories:"
  echo "             sudo -u ${PEER_USER} test -w ${PEER_STATE_DIR} -a -w ${PEER_TEXTFILE_DIR} && echo writable"
  if [[ "${PEER_SEED_CONFIG}" != "1" || ! -f "${PEER_CONFIG}" ]]; then
    echo "           ${PEER_CONFIG} does not exist, so the run would report 0 peers rather than fail."
  fi
  exit 1
fi

if (( export_ok )); then
  printf '  OK      the local exporter is serving %s\n' "${LIVENESS}"
else
  printf '  MISSING %s is not on http://127.0.0.1:%s/metrics\n' "${LIVENESS}" "$PORT"
  echo "           The watchdog ran, so this is the exporter, not the watchdog:"
  echo "             grep textfile ${UNIT_EXPORTER}"
  echo "             grep 'peer_watchdog' ${PROM_FILE} | head -3"
  echo "             curl -s http://127.0.0.1:${PORT}/metrics | grep node_scrape_collector_success"
  echo "           node_scrape_collector_success{collector=\"textfile\"} == 0 means the collector"
  echo "           rejected the file or cannot read the directory."
  echo "           Peers are still being recorded either way; only the export is missing."
fi

echo
echo "=== done ==="
echo "timer: peer-watchdog.timer, service: peer-watchdog.service"
echo "metrics: ${PROM_FILE}"
echo "history: ${PEER_STATE_DIR}/<peer>.history (one line per completed down window)"
echo "config:  ${PEER_CONFIG}"
echo
echo "=== peer reachability is NOT verified by this script ==="
cat <<EOF
  A local script cannot know whether another machine is reachable from here. The
  most common causes are invisible from this host, and the watchdog will happily
  record every one of them as an outage:
    * an application firewall or network monitor on the PEER (Portmaster and
      similar) filters per process, so every conventional firewall service on that
      machine reads "inactive" while it drops the connection;
    * a packet filter on this host (firewalld, ufw, nftables, iptables, pf) with
      the peer's port closed;
    * an upstream router, a hypervisor security group, or Wi-Fi power saving
      between the two machines.
  So the history is only as good as that configuration, and the first thing to do
  with a surprise down window is to try the probe by hand from this machine:
      curl -s --max-time ${PEER_TIMEOUT} http://<host>:<port>/metrics | head -3
  An exporter prints \# HELP and metric lines. An HTML page, a router login form or
  an empty answer means the port is answered by something that is not an exporter,
  which the watchdog also records as down, on purpose.
EOF
echo
echo "Next:"
echo "  1. Add one peer per line to ${PEER_CONFIG}:"
echo "       <peer-name>=<host>:9100"
echo "  2. Check that port really is reachable FROM THIS MACHINE (curl the command above)."
echo "  3. Confirm the peers appear on the local exporter:"
echo "       curl -s http://127.0.0.1:${PORT}/metrics | grep '^node_watchdog_peer_up'"
echo "  4. Prometheus needs no change: these metrics arrive through the scrape of"
echo "     this host's own node_exporter, already registered in the Devices registry."
echo
echo "What this does NOT do: it cannot repair a frozen peer. If the machine is wedged"
echo "there is no shell to run anything on, so the value here is the independent"
echo "timeline and the alert firing from a healthy machine, not recovery."
echo "To remove it:"
echo "  systemctl disable --now peer-watchdog.timer"
echo "  rm -f ${PEER_UNIT_DIR}/peer-watchdog.{service,timer} ${PEER_INSTALL_DIR}/peer-watchdog"
echo "  systemctl daemon-reload"
echo "The state directory and ${PEER_CONFIG} are left in place: they hold the history."