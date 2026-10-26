#!/usr/bin/env bash
# =============================================================================
# Peer reachability watchdog for the node_exporter textfile collector.
#
# WHY THIS EXISTS
# Prometheus already scrapes every machine's native node_exporter on port 9100,
# so "the peer is down" is, in principle, already covered. It is not enough for
# the case this script was written for: a laptop that intermittently becomes
# completely unresponsive (the browser dies first, recovery takes hours,
# sometimes the machine has to be force-powered-off, and during the event even a
# Ctrl+Alt+F2 TTY switch does nothing).
#
# A frozen machine cannot report anything, so the only thing Prometheus ever
# learns is `up == 0` and it learns it only after the scrape's `for:` window.
# That is fine for DETECTION and useless for TIMING: Prometheus cannot know when
# the outage truly began or truly ended, to the second. Worse, a machine that
# hard-resets looks identical in a time series to a machine that was cleanly
# rebooted, so the distinction that matters most when debugging an intermittent
# hang is exactly the distinction a scrape throws away.
#
# So this is a second, INDEPENDENT WITNESS. It runs on an always-on machine,
# never on the machine being watched, and it records the start and the end of
# every down window itself. Two records of the same event written by two
# machines that did not share a failure are worth more than either one: if the
# target's own on-disk heartbeat latch and this history disagree about when a
# freeze began, that disagreement is itself a finding (a network partition, a
# clock problem, or a hang that also took the network stack down look different
# on the two sides, and the diff says which).
#
# WHY NO NEW CONTAINER AND NO NEW PORT
# The observing machine already runs node_exporter, and node_exporter already
# has a textfile collector reading one directory. This script writes its metrics
# into that directory and stops. Prometheus picks them up through the scrape that
# is already happening, so the metrics inherit the same job, instance and host
# labels as everything else on that machine and cost zero new network surface.
# A dedicated exporter for peer state would be one more container to keep alive
# on the one machine that must never be the thing that breaks.
#
# WHAT THIS CANNOT DO -- read this before you rely on it
# It cannot repair a wedged machine, and no amount of cleverness here will make
# it. If the peer is truly frozen there is no shell to SSH into, no agent on it
# to execute anything, and no remote channel that is not itself going through
# the same dead kernel. Every "remote remediation" story for this failure mode
# requires the machine to be alive enough to run a command, which is precisely
# the thing that is not true. What this script actually buys is (a) an accurate,
# independent, second-resolution timeline that survives for the retention
# period, and (b) an alert delivery path -- the notification happens on the
# healthy machine, so it still fires. It is a witness and a fire alarm, not a
# fire brigade.
#
# The main value is the HISTORY: the project wants 30 days of an intermittent
# hang, and an intermittent hang is exactly the thing that is never caught in
# the act. Durable per-window start/end records make the pattern visible after
# the fact even when nobody was looking.
#
# Tested on Fedora Linux. Runtime deps: bash, date, awk, curl, logger, coreutils.
# =============================================================================
set -uo pipefail

# --- configuration -----------------------------------------------------------
# Every setting is an environment variable with a default that works on a stock
# systemd Linux. The installer writes a drop-in with the operator's values; you
# can also export them and run the script by hand, which is the fastest way to
# debug a peer that is misbehaving.
OUT_DIR="${PEER_WATCHDOG_TEXTFILE_DIR:-${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}}"
OUT_FILE="${OUT_DIR}/peer_watchdog.prom"
STATE_DIR="${PEER_WATCHDOG_STATE_DIR:-/var/lib/peer-watchdog}"
CONFIG_FILE="${PEER_WATCHDOG_CONFIG:-/etc/peer-watchdog/peers.conf}"

# Per-probe wall clock cap. This is the whole reason the script cannot hang: a
# peer that accepts the TCP connection and then stops sending (a half-open
# network stack, a suspended-but-still-listening machine, a firewall that
# silently drops) would otherwise hold the run open until curl's own much larger
# default. curl gets an explicit --max-time and --connect-timeout, so a dead
# peer costs exactly this many seconds and no more.
PROBE_TIMEOUT="${PEER_WATCHDOG_TIMEOUT:-5}"

# How many probes may be in flight at once. Probing peers SEQUENTIALLY is the
# obvious implementation and it is wrong here: with 10 peers and a 5s timeout, a
# run where everything is down takes 50s, which is longer than the timer interval
# and the next run then stacks on top of the previous one. That is how a timer
# that exists to tell you about hangs ends up hiding them. With a concurrency
# pool the worst case is ceil(peers/concurrency) * timeout, which stays under the
# interval for any sane peer count, and a healthy peer still finishes in
# milliseconds because a fast answer frees its slot immediately.
PROBE_CONCURRENCY="${PEER_WATCHDOG_CONCURRENCY:-8}"

# History bounding. BOTH a period and a line count, because either one alone has
# a failure mode: retention alone lets a flapping peer (one short window per
# minute) fill the disk with a file that is large to rewrite every run, and a
# line count alone silently throws away the 30-day timeline the moment the count
# is reached. Pruning keeps the NEWEST entries in both cases, because the
# interesting windows are the recent ones and an old outage that matters is
# still visible in the aggregated metrics.
HISTORY_RETENTION="${PEER_WATCHDOG_HISTORY_RETENTION:-2592000}"   # 30 days
HISTORY_MAX_LINES="${PEER_WATCHDOG_HISTORY_MAX_LINES:-5000}"

# A peer is UP only if the body actually looks like a Prometheus exporter.
# Requiring an HTTP 200 alone is the tempting wrong approach and it is wrong in
# a way that corrupts the very timeline this script exists to keep: a router
# answering on the port, a captive portal, a reverse proxy returning an HTML
# error page, or a completely different service bound to 9100 after a config
# change will all answer instantly with a 200 or a 404, and each of those would
# be recorded as "the laptop was fine". Requiring the textfile format shape is a
# cheap, honest test of "is an exporter actually on the other end".
HEALTH_PATTERN="${PEER_WATCHDOG_HEALTH_PATTERN:-^#[[:space:]]+(HELP|TYPE)[[:space:]]}"

RUN_START_EPOCH="$(date +%s)"
RUN_START_NS="$(date +%s%N)"

# --- small helpers -----------------------------------------------------------
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
is_num() { local s; s="$(trim "${1:-}")"; case "$s" in ''|*[!0-9.eE+-]*) return 1 ;; *) return 0 ;; esac; }

# Prometheus label values are quoted strings, so a backslash, a double quote or
# a newline in a peer name would produce a file the textfile collector rejects
# (and, worse, a half-parsed file that silently loses metrics). Escape rather
# than strip: stripping would merge two differently-named peers into one series.
esc_label() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }

# Peer names come from a config file, so they are untrusted input for the
# purpose of building a FILE NAME. Restrict to a safe alphabet and cap the
# length, otherwise a peer called "../../etc/cron.d/x" writes outside the state
# directory. Leading dots are stripped too: sanitising "../../evil" would otherwise
# yield ".._.._evil", and a state file whose name starts with a dot is invisible
# to a plain `ls` of the state directory, which is where an operator goes to look
# after an incident.
#
# Two DIFFERENT peer names can still sanitise to the same file name ("a/b" and
# "a_b" both become "a_b"), and they would then share one state file and one
# history, which would silently cross-contaminate two machines' timelines. The
# parser therefore rejects a peer whose sanitised name is already taken.
safe_name() {
  local s="$1"
  s="${s//[^A-Za-z0-9_.-]/_}"
  while [[ "${s}" == .* ]]; do s="${s#.}"; done
  [[ -n "${s}" ]] || s="peer"
  printf '%s' "${s:0:64}"
}

# date +%s%N is nanoseconds on GNU coreutils and a literal "N" on toybox/busybox.
# Rather than emit a nonsense duration, detect that and fall back to whole
# seconds. Durations are a nicety here; a wrong duration is worse than a coarse
# one.
now_ms() {
  local ns; ns="$(date +%s%N)"
  if is_num "${ns}" && [[ "${ns}" != *N* ]]; then printf '%s' "$(( ns / 1000000 ))"; else printf '%s' "$(( $(date +%s) * 1000 ))"; fi
}

log() { logger -t peer-watchdog -- "$1" 2>/dev/null || printf 'peer-watchdog: %s\n' "$1" >&2; }

# --- per-peer state ----------------------------------------------------------
# One small file per peer, replaced atomically. The invariant is:
#   down_since > 0  <=>  the peer is currently DOWN
# `up` is stored as well because a human reading the state directory should not
# have to remember the invariant, but it is derived, never the source of truth.
# The tmp+mv pair (never an in-place rewrite) is what keeps this file readable
# after a power cut: mv within a filesystem is atomic, so a reader sees either
# the previous state or the new one, never a half-written mixture. The temp file
# is created in the SAME directory as the target on purpose, because that is the
# only way to guarantee it is the same filesystem and therefore a real rename.
S_UP=1; S_DOWN_SINCE=0; S_LAST_OK=0; S_EVENTS=0; S_LAST_DUR=0

load_state() {
  local f="$1" k v
  S_UP=1; S_DOWN_SINCE=0; S_LAST_OK=0; S_EVENTS=0; S_LAST_DUR=0
  [[ -r "$f" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      up)           S_UP="$v" ;;
      down_since)   S_DOWN_SINCE="$v" ;;
      last_ok)      S_LAST_OK="$v" ;;
      events)       S_EVENTS="$v" ;;
      last_duration) S_LAST_DUR="$v" ;;
    esac
  done < "$f"
  for v in S_UP S_DOWN_SINCE S_LAST_OK S_EVENTS S_LAST_DUR; do is_num "${!v}" || printf -v "$v" '%s' 0; done
  # A hand-edited or corrupt file can end up saying "down" with no start time.
  # There is no honest start time to invent, so treat it as up and let the next
  # real failure open a fresh window rather than fabricating a zero-length one.
  if [[ "${S_DOWN_SINCE}" -eq 0 ]]; then S_UP=1; fi
  return 0
}

write_state() {
  # Two statements, not one: inside a single `local` every word is expanded BEFORE
  # the builtin runs, so `local f="$1" tmp="${f}.tmp.$$"` would expand ${f} while
  # it is still unset and, under set -u, abort the whole run.
  local f="$1" tmp
  tmp="${f}.tmp.$$"
  {
    printf 'up=%s\n' "$2"
    printf 'down_since=%s\n' "$3"
    printf 'last_ok=%s\n' "$4"
    printf 'events=%s\n' "$5"
    printf 'last_duration=%s\n' "$6"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

# --- history -----------------------------------------------------------------
# One line per COMPLETED down window: "<end_epoch> <start_epoch> <duration>
# <start_iso8601> <end_iso8601>". Append-only, because a timeline you can
# rewrite is not a timeline; the only mutation is pruning, and pruning removes
# whole lines from the oldest end.
append_history() {
  local f="$1" end="$2" start="$3" dur="$4"
  local end_iso start_iso
  # ISO stamps are for a human reading the file after the fact. Two date calls
  # per EVENT (not per run) is cheap: a flapping peer still only pays on close.
  end_iso="$(date -u -d "@${end}" +%FT%TZ 2>/dev/null)"
  start_iso="$(date -u -d "@${start}" +%FT%TZ 2>/dev/null)"
  printf '%s %s %s %s %s\n' "${end}" "${start}" "${dur}" "${start_iso:-unknown}" "${end_iso:-unknown}" >> "$f" 2>/dev/null
  return 0
}

prune_history() {
  local f="$1" cutoff="$2" keep="$3" lines
  local tmp
  tmp="${f}.tmp.$$"
  [[ -s "$f" ]] || return 0
  # Retention first, then the line cap. awk keeps the file's ascending order (it
  # is append-only, so the file is already sorted by end epoch), and tail -n
  # keeps the NEWEST, which is what both limits are meant to do: drop old detail,
  # never recent detail. Writing to a temp and renaming keeps a reader (the
  # exporter, an operator with cat) from ever seeing the truncated half.
  if ! awk -v c="${cutoff}" '$1 >= c' "$f" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  lines="$(wc -l < "$tmp" 2>/dev/null || printf '0')"
  is_num "${lines}" || lines=0
  if [[ "${lines}" -gt "${keep}" ]]; then
    tail -n "${keep}" "$tmp" > "${tmp}.cut" 2>/dev/null && mv -f "${tmp}.cut" "$tmp" 2>/dev/null
  fi
  mv -f "$tmp" "$f" 2>/dev/null
}

history_total_down() {
  local f="$1"
  [[ -s "$f" ]] || { printf '0'; return 0; }
  awk '{ d += $3 } END { printf "%d", d + 0 }' "$f" 2>/dev/null || printf '0'
}

# --- probe -------------------------------------------------------------------
# Runs in a background subshell. Writes "<healthy> <rc> <duration_ms>" to the
# result file and nothing else: passing a metrics body between processes through
# a variable would be both slow and pointless, and a subshell cannot export
# anything useful back, so the result is a file just like everything else.
probe_worker() {
  local idx="$1" name="$2" host="$3" port="$4" out_dir="$5" timeout="$6" pattern="$7"
  local body="" rc started ended ms healthy=0
  started="$(now_ms)"
  # No --fail on purpose: we want the BODY even on a 404 so the health check can
  # reject it with evidence, instead of "curl failed" being indistinguishable
  # from "connection refused". Both are DOWN, but the former is a machine whose
  # web server is alive and is not exporting, which is a different problem.
  body="$(curl -s --max-time "${timeout}" --connect-timeout "${timeout}" -H 'User-Agent: peer-watchdog/1' "http://${host}:${port}/metrics" 2>/dev/null)"
  rc=$?
  ended="$(now_ms)"
  ms=$(( ended - started ))
  [[ "${ms}" -ge 0 ]] || ms=0
  # Two independent conditions, both required: the transfer succeeded (rc 0), and
  # the body looks like an exporter (a HELP/TYPE comment plus at least one sample
  # line with a numeric value). The sample-line check is what rejects an HTML
  # error page that happens to contain the word HELP, and what rejects an empty
  # 200 from a service that accepted the connection and had nothing to say.
  if [[ "${rc}" -eq 0 && -n "${body}" ]] \
     && grep -qE "${pattern}" <<<"${body}" \
     && grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*(\{[^}]*\})?[ \t]+-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' <<<"${body}"; then
    healthy=1
  fi
  printf '%s %s %s\n' "${healthy}" "${rc}" "${ms}" > "${out_dir}/probe.${idx}" 2>/dev/null
  return 0
}

# --- main --------------------------------------------------------------------
[[ "${PROBE_CONCURRENCY}" -ge 1 ]] 2>/dev/null || PROBE_CONCURRENCY=1
is_num "${PROBE_TIMEOUT}" && [[ "${PROBE_TIMEOUT}" -ge 1 ]] || PROBE_TIMEOUT=5
is_num "${HISTORY_RETENTION}" || HISTORY_RETENTION=2592000
is_num "${HISTORY_MAX_LINES}" && [[ "${HISTORY_MAX_LINES}" -ge 1 ]] || HISTORY_MAX_LINES=5000

if ! mkdir -p "$OUT_DIR" "$STATE_DIR" 2>/dev/null; then
  printf 'peer-watchdog: no puedo crear %s o %s\n' "$OUT_DIR" "$STATE_DIR" >&2
  exit 1
fi
[[ -w "$OUT_DIR"  ]] || { printf 'peer-watchdog: %s no es escribible\n' "$OUT_DIR" >&2; exit 1; }
[[ -w "$STATE_DIR" ]] || { printf 'peer-watchdog: %s no es escribible\n' "$STATE_DIR" >&2; exit 1; }

TMP="${OUT_FILE}.$$"
WORK="$(mktemp -d "${STATE_DIR}/work.XXXXXX" 2>/dev/null)" || WORK="${STATE_DIR}/work.$$"
mkdir -p "$WORK" 2>/dev/null
# Trap removes BOTH the metrics temp file and the per-run work directory. The
# work dir lives under the state directory rather than /tmp because the unit
# sets PrivateTmp=true, which gives this service a private /tmp anyway; keeping
# everything in one place means one cleanup path and no surprise.
trap 'rm -f "$TMP"; rm -rf "$WORK"' EXIT

# --- read the peer list ------------------------------------------------------
# No config means no peers, which is a valid state: the watcher still refreshes
# its own liveness metrics, so "the watchdog is running but has no peers" is
# visible in Prometheus instead of being indistinguishable from a dead watchdog.
PEER_NAMES=() PEER_TARGETS=()
if [[ ! -r "$CONFIG_FILE" ]]; then
  log "peer config ${CONFIG_FILE} is missing or unreadable; no peers checked (this is normal until you create it)"
else
  seen_names=" "; seen_safe=" "
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    line="$(trim "${raw%%#*}")"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *=* ]] || { log "ignoring malformed peer line (expected name=host:port): ${raw}"; continue; }
    pname="$(trim "${line%%=*}")"
    target="$(trim "${line#*=}")"
    [[ -n "${pname}" && -n "${target}" ]] || { log "ignoring peer line with an empty name or target: ${raw}"; continue; }
    phost="${target%:*}"; pport="${target##*:}"
    # A bare "host" with no port is a common typo, and defaulting it silently
    # would probe port 80 and report a bogus outage; refuse instead.
    [[ "${phost}" != "${target}" && -n "${phost}" ]] || { log "ignoring peer '${pname}': no port, expected name=host:port"; continue; }
    is_num "${pport}" && [[ "${pport}" -ge 1 && "${pport}" -le 65535 ]] || { log "ignoring peer '${pname}': invalid port in '${target}'"; continue; }
    # Duplicate names would produce two series with the same label set, and a
    # textfile with duplicate series is rejected wholesale by the collector: one
    # typo in the config would take out every metric this script produces.
    if [[ "${seen_names}" == *" ${pname} "* ]]; then log "ignoring duplicate peer name '${pname}'"; continue; fi
    # Distinct names that sanitise to the same FILE name ("a/b" and "a_b") would
    # share one state file and one history, so one machine's windows would end up
    # in another machine's timeline. Two different machines, silently merged.
    psafe="$(safe_name "${pname}")"
    if [[ "${seen_safe}" == *" ${psafe} "* ]]; then
      log "ignoring peer '${pname}': its name sanitises to '${psafe}', which is already taken by another peer"
      continue
    fi
    seen_names+="${pname} "; seen_safe+="${psafe} "
    PEER_NAMES+=("${pname}")
    PEER_TARGETS+=("${phost}:${pport}")
  done < "${CONFIG_FILE}"
fi

PEER_COUNT="${#PEER_NAMES[@]}"

# --- probe every peer concurrently -------------------------------------------
# Launch into the pool; when the pool is full, reap ONE finished probe before
# launching the next. Reaping one at a time (rather than running in fixed
# batches) is what keeps a run with one dead peer as short as a run with none:
# a batch barrier makes every peer wait for the slowest one in its batch.
pids=()
for (( i = 0; i < PEER_COUNT; i++ )); do
  probe_worker "${i}" "${PEER_NAMES[i]}" "${PEER_TARGETS[i]%%:*}" "${PEER_TARGETS[i]##*:}" "$WORK" "${PROBE_TIMEOUT}" "${HEALTH_PATTERN}" &
  pids+=("$!")
  if [[ "${#pids[@]}" -ge "${PROBE_CONCURRENCY}" ]]; then
    wait "${pids[0]}" 2>/dev/null
    pids=("${pids[@]:1}")
  fi
done
for p in ${pids[@]+"${pids[@]}"}; do wait "${p}" 2>/dev/null; done
unset p

# --- fold the results into state, history and metrics ------------------------
{
  echo "# HELP node_watchdog_last_run_timestamp_seconds Unix time of the last completed run of this watchdog. A value that stops advancing is a dead watchdog, which is worse than no watchdog at all."
  echo "# TYPE node_watchdog_last_run_timestamp_seconds gauge"
  echo "# HELP node_watchdog_run_duration_seconds Wall clock seconds the last run took, including waiting for the slowest peer."
  echo "# TYPE node_watchdog_run_duration_seconds gauge"
  echo "# HELP node_watchdog_peers_configured Number of peers read from the peer config on the last run. 0 means the config is missing or empty, not that everything is up."
  echo "# TYPE node_watchdog_peers_configured gauge"
  echo "# HELP node_watchdog_peers_up Number of configured peers that answered the last probe with something that looks like an exporter."
  echo "# TYPE node_watchdog_peers_up gauge"
  # Every HELP and TYPE line is emitted exactly once, here, before the peer loop.
  # Repeating them per peer looks harmless and is not: a second HELP line for the
  # same metric name is a parse error, and the textfile collector discards the
  # whole file when it hits one, which would take the liveness metrics down with
  # it.
  echo "# HELP node_watchdog_peer_up 1 if the peer answered the last probe with a body that looks like a Prometheus exporter. A port that answers with an unrelated HTTP response, an HTML page or an empty body is DOWN, on purpose."
  echo "# TYPE node_watchdog_peer_up gauge"
  echo "# HELP node_watchdog_peer_probe_duration_seconds How long the last probe took, wall clock. Useful as a leading indicator: a peer that answers slowly is often a peer about to stop."
  echo "# TYPE node_watchdog_peer_probe_duration_seconds gauge"
  echo "# HELP node_watchdog_peer_down_since_timestamp_seconds Unix time the current down window began, or 0 when there is no open window."
  echo "# TYPE node_watchdog_peer_down_since_timestamp_seconds gauge"
  echo "# HELP node_watchdog_peer_last_success_timestamp_seconds Unix time of the last successful probe, or 0 if this peer has never answered since its state file was created."
  echo "# TYPE node_watchdog_peer_last_success_timestamp_seconds gauge"
  echo "# HELP node_watchdog_peer_down_windows_total Number of completed down windows recorded for this peer. Monotonic: it only ever increases, and it counts events, not probes."
  echo "# TYPE node_watchdog_peer_down_windows_total counter"
  echo "# HELP node_watchdog_peer_last_down_duration_seconds Duration in seconds of the most recently completed down window, or 0 if there has not been one yet."
  echo "# TYPE node_watchdog_peer_last_down_duration_seconds gauge"
  echo "# HELP node_watchdog_peer_down_seconds Seconds since the current down window began. Only present while the peer is down; absent means there is no open window."
  echo "# TYPE node_watchdog_peer_down_seconds gauge"
  echo "# HELP node_watchdog_peer_total_down_seconds Total seconds this peer was recorded down over the retained history window, including the window that is still open. A gauge, not a counter, because it can fall when old entries age out of the retention period."
  echo "# TYPE node_watchdog_peer_total_down_seconds gauge"
} > "$TMP"

# Values are validated before they are printed, because a hand-edited or truncated
# state file must never turn into a malformed .prom: the textfile collector
# discards the WHOLE file on a parse error, so one bad line would take down every
# metric this script produces, including the liveness ones.
emit() { # emit <metric-suffix> <value> <peer> <target>
  local v; v="$(trim "${2:-}")"
  is_num "${v}" || return 0
  echo "node_watchdog_${1}{peer=\"$(esc_label "${3}")\",target=\"$(esc_label "${4}")\"} ${v}" >> "$TMP"
}

peers_up=0
for (( i = 0; i < PEER_COUNT; i++ )); do
  pname="${PEER_NAMES[i]}"; target="${PEER_TARGETS[i]}"
  safe="$(safe_name "${pname}")"
  state_file="${STATE_DIR}/${safe}.state"
  hist_file="${STATE_DIR}/${safe}.history"

  healthy=0; rc=1; ms=0
  if [[ -r "${WORK}/probe.${i}" ]]; then
    read -r healthy rc ms < "${WORK}/probe.${i}" 2>/dev/null
  fi
  is_num "${healthy:-}" || healthy=0
  is_num "${rc:-}" || rc=1
  is_num "${ms:-}" || ms=0

  load_state "${state_file}"

  if [[ "${healthy}" -eq 1 ]]; then
    peers_up=$(( peers_up + 1 ))
    if [[ "${S_DOWN_SINCE}" -gt 0 ]]; then
      # DOWN -> UP: close the window. Everything about this event is recorded from
      # values we actually observed -- the start from the run that first failed,
      # the end from now -- never from a back-of-the-envelope estimate.
      dur=$(( RUN_START_EPOCH - S_DOWN_SINCE ))
      [[ "${dur}" -ge 0 ]] || dur=0
      append_history "${hist_file}" "${RUN_START_EPOCH}" "${S_DOWN_SINCE}" "${dur}"
      prune_history "${hist_file}" "$(( RUN_START_EPOCH - HISTORY_RETENTION ))" "${HISTORY_MAX_LINES}"
      S_EVENTS=$(( S_EVENTS + 1 ))
      S_LAST_DUR="${dur}"
      log "peer '${pname}' (${target}) came back up after ${dur}s down (window started at epoch ${S_DOWN_SINCE})"
      S_DOWN_SINCE=0
    fi
    S_UP=1
    S_LAST_OK="${RUN_START_EPOCH}"
  else
    if [[ "${S_DOWN_SINCE}" -eq 0 ]]; then
      # UP -> DOWN: open a window, ONCE. Note what is NOT done here: the start
      # time is not refreshed on subsequent failures. A peer that is down for an
      # hour and fails every check is one outage of an hour, not 24 outages of
      # 150 seconds, and re-stamping on every miss would record exactly that and
      # destroy the timeline.
      S_DOWN_SINCE="${RUN_START_EPOCH}"
      S_UP=0
      log "peer '${pname}' (${target}) did not answer as an exporter (curl rc ${rc}); recording down window from epoch ${RUN_START_EPOCH}"
    else
      S_UP=0
    fi
  fi

  write_state "${state_file}" "${S_UP}" "${S_DOWN_SINCE}" "${S_LAST_OK}" "${S_EVENTS}" "${S_LAST_DUR}"

  emit peer_up "${healthy}" "${pname}" "${target}"
  emit peer_probe_duration_seconds "$(awk -v m="${ms}" 'BEGIN{printf "%.3f", m/1000}')" "${pname}" "${target}"
  emit peer_down_since_timestamp_seconds "${S_DOWN_SINCE}" "${pname}" "${target}"
  emit peer_last_success_timestamp_seconds "${S_LAST_OK}" "${pname}" "${target}"
  emit peer_down_windows_total "${S_EVENTS}" "${pname}" "${target}"
  emit peer_last_down_duration_seconds "${S_LAST_DUR}" "${pname}" "${target}"

  # Total time down over the RETAINED history plus the window that is still open.
  # It is a gauge and not a counter precisely because it can fall when old entries
  # age out: a counter that decreased would break rate() and every increase() built
  # on it. "How much of the last 30 days was this machine gone" is a bounded-window
  # question, so a bounded-window gauge is the honest shape for it.
  total_down="$(history_total_down "${hist_file}")"
  is_num "${total_down}" || total_down=0
  if [[ "${S_DOWN_SINCE}" -gt 0 ]]; then
    open=$(( RUN_START_EPOCH - S_DOWN_SINCE ))
    [[ "${open}" -ge 0 ]] || open=0
    total_down=$(( total_down + open ))
  fi
  emit peer_total_down_seconds "${total_down}" "${pname}" "${target}"

  # down_seconds is emitted ONLY while the peer is down. Emitting 0 while up would
  # be a fabricated value: the honest reading while up is "there is no down
  # window", and a rule that alerts on this has to handle the series being absent,
  # which up==0 already tells it unambiguously.
  if [[ "${S_DOWN_SINCE}" -gt 0 ]]; then
    open=$(( RUN_START_EPOCH - S_DOWN_SINCE ))
    [[ "${open}" -ge 0 ]] || open=0
    emit peer_down_seconds "${open}" "${pname}" "${target}"
  fi
done

RUN_END_NS="$(date +%s%N)"
if is_num "${RUN_END_NS}" && [[ "${RUN_END_NS}" != *N* ]]; then
  run_dur="$(awk -v a="${RUN_START_NS}" -v b="${RUN_END_NS}" 'BEGIN{printf "%.3f", (b-a)/1000000000}')"
else
  run_dur="$(awk -v a="${RUN_START_EPOCH}" -v b="$(date +%s)" 'BEGIN{printf "%.3f", b-a+0}')"
fi
is_num "${run_dur}" || run_dur=0
peers_up_metric="${peers_up}"

{
  echo "node_watchdog_last_run_timestamp_seconds ${RUN_START_EPOCH}"
  echo "node_watchdog_run_duration_seconds ${run_dur}"
  echo "node_watchdog_peers_configured ${PEER_COUNT}"
  echo "node_watchdog_peers_up ${peers_up_metric}"
} >> "$TMP"

# Stamp the run as soon as it is finished so a run that dies mid-way does not
# look like a hung watchdog on the next tick, and replace the metrics file
# atomically so the exporter never reads a half-written exposition.
printf '%s\n' "${RUN_START_EPOCH}" > "${STATE_DIR}/lastrun.tmp.$$" 2>/dev/null \
  && mv -f "${STATE_DIR}/lastrun.tmp.$$" "${STATE_DIR}/lastrun" 2>/dev/null

if mv -f "$TMP" "$OUT_FILE" 2>/dev/null; then
  printf 'peer-watchdog: %s peer(s) checked, %s up, %ss, metrics in %s\n' \
    "${PEER_COUNT}" "${peers_up}" "${run_dur}" "$OUT_FILE" >&2
else
  printf 'peer-watchdog: no se pudo escribir %s\n' "$OUT_FILE" >&2
  exit 1
fi
exit 0