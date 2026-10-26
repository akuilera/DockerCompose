#!/usr/bin/env bash
# =============================================================================
# Generic host heartbeat for the node_exporter textfile collector.
#
# WHY THIS EXISTS
# A node_exporter scrape cannot detect a hard lock. When the machine freezes the
# scrape fails and the series goes stale, which looks exactly like "the box was
# rebooted" or "the network died", and by the time it answers again the local
# timestamps are fresh again so the gap never appears in any series at all. This
# script writes a local file on a timer instead, and the interesting case is the
# one where it does NOT run: the machine was powered on and this timer did not
# fire, and that is only knowable from a timestamp this script left behind
# earlier. Prometheus can never see it, because Prometheus is by definition not
# running while it happens.
#
# WHAT THIS FIXES IN THE PREVIOUS NVIDIA-ONLY VERSION
# The old nvidia-gpu-heartbeat.sh kept exactly one number, the largest gap it had
# ever seen, latched for 30 days. That is wrong in two ways. First, one number
# cannot describe an intermittent fault: five separate hangs over 30 days are
# indistinguishable from one, and nothing recorded when any of them happened, so
# there is no history to correlate against temperatures, kernel versions or
# updates. The goal is a 30-day history, not a high-water mark. Second, the old
# version could not tell a suspend from a freeze. A laptop that sleeps for the
# night produces a multi-hour gap, so every ordinary night raised a hard-freeze
# alert for a freeze that never happened. That is a guaranteed false positive,
# not an edge case, and it is fixed below with a real suspend signal.
#
# Every gap is now CLASSIFIED, and the classification is the whole point:
#
#   order  class       condition                                                        what it means
#   -----  ----------  --------------------------------------------------------------  ----------------------------
#    1     unknown     state file missing / unreadable / malformed / wrong schema      not evidence of anything; rebase
#    2     reboot      boot_id differs from the stored one, OR stored uptime is        the machine went down and came
#                      greater than the current one                                     back; cause is INDETERMINATE
#    3     clock-step  now < last_epoch                                                the wall clock moved backwards
#    4     suspend     a completed sleep transition spans the gap (system-sleep hook)   the machine was asleep, not stuck
#    5     freeze      same boot_id, uptime did not decrease, gap above threshold     the real signal: powered on, but
#                                                                                      this timer did not run for that long
#    6     unknown     gap above the absolute sanity bound                            stored value is corrupt; rebase
#
# The order is not arbitrary: cheapest and most unambiguous first, so a corrupted
# or missing state file can never be misread as a hang, a reboot can never be
# misread as a freeze, and a clock correction can never turn into a negative
# "gap" that poisons the latch. Steps 1, 2, 3 and 6 are evaluated regardless of the
# gap size because they are state-integrity problems that must rebaseline even
# when they happen five seconds after the previous run. Steps 4 and 5 only apply
# above the threshold, because anything at or below it is a healthy run and must
# produce no event at all. Step 6 runs last over whatever class steps 2 to 5 just
# chose: nothing sane produces a 60-day gap between two timer runs, so a stored
# value that claims one is corrupt, and believing it would poison the latch with a
# number no human could ever reproduce.
#
# TWO INDEPENDENT REBOOT SIGNALS, and why the cause stays "indeterminate"
# boot_id is the primary signal: /proc/sys/kernel/random/boot_id is a random UUID
# regenerated on every boot, so a change proves a reboot happened. The uptime
# signal is the backup: the first field of /proc/uptime going DOWN when the stored
# value said the machine had been up longer also proves a reboot, and it still
# works on a kernel built without CONFIG_PROC_SYS_RANDOM, where the boot id file
# does not exist at all. Two signals rather than one because an agent that loses
# its only reboot signal starts calling every power cut a freeze, which is the
# exact failure mode the history exists to avoid.
# Neither signal can say WHY the machine went down. A user reboot, a power cut, a
# crash and a kernel panic with panic=N auto-reboot all leave the same state: a
# new boot id and a gap. That is not a gap in the implementation, it is
# information the system does not have, because the machine rebooted with the CPU
# wedged or the power gone and nothing recorded a reason. The description says
# "indeterminate" on purpose; writing "freeze" there would invent evidence.
#
# SUSPEND IS DETECTED WITH A systemd-sleep HOOK, NOT WITH A CLOCK
# This is not a stylistic preference. Comparing the wall clock across the gap is
# useless because /proc/uptime is CLOCK_BOOTTIME, which advances during a deep
# suspend exactly like CLOCK_REALTIME: both sides of the comparison advance
# together, so it cannot distinguish "the timer did not run" from "the machine was
# asleep". The one real alternative, CLOCK_BOOTTIME minus CLOCK_MONOTONIC, does
# isolate the suspended interval but fails on s2idle, the default suspend mode on
# modern systemd kernels, and CLOCK_MONOTONIC is not in /proc at all. The
# companion file host-heartbeat-sleep is therefore installed into
# /usr/lib/systemd/system-sleep/ and writes a small marker around each sleep
# transition, and this script consumes that marker. The honest caveat is that an
# EC-initiated sleep or a hand-written "echo mem > /sys/power/state" never runs
# the hook, so such a gap is still classified freeze.
#
# Tested on Fedora Linux. Writes into a directory only node_exporter reads.
# =============================================================================
set -uo pipefail

# --- configuration ----------------------------------------------------------
# Every setting is an environment variable with a sane default. The legacy
# NODE_GPU_* names are still honoured so an existing drop-in keeps working: this
# script replaces the old one rather than competing with it.
OUT_DIR="${NODE_HOST_TEXTFILE_DIR:-${NODE_GPU_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}}"
TIMEOUT_S="${NODE_GPU_TIMEOUT:-5}"
GAP_S="${NODE_HOST_GAP_THRESHOLD:-${NODE_GPU_GAP_THRESHOLD:-60}}"
SANITY_S="${NODE_HOST_SANITY_GAP:-5184000}"      # 60 days
LATCH_TTL="${NODE_HOST_MAX_GAP_TTL:-${NODE_GPU_MAX_GAP_TTL:-2592000}}"   # 30 days
EVENT_RETENTION="${NODE_HOST_EVENT_RETENTION:-2592000}"                # 30 days
EVENT_MAX="${NODE_HOST_EVENT_MAX:-5000}"
# auto = query nvidia-smi when it exists, 1 = force the query, 0 = never query.
GPU_MODE="${NODE_HOST_GPU:-auto}"
# The command itself, overridable so --self-test can inject a stub instead of the
# real driver, exactly like LOGGER and JOURNALCTL below.
NVIDIA_SMI="${NODE_HOST_NVIDIA_SMI:-nvidia-smi}"

# The two /proc facts that drive classification. Overridable only so --self-test
# can drive every branch on an unprivileged machine with synthetic values; the
# defaults are the real paths and nothing in production should change them.
BOOT_ID_FILE="${NODE_HOST_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
UPTIME_FILE="${NODE_HOST_UPTIME_FILE:-/proc/uptime}"
# The logger command, overridable so --self-test can capture what would go to
# journald instead of writing to a journal an unprivileged run does not have.
LOGGER="${NODE_HOST_LOGGER:-logger}"

# --- journal correlation ----------------------------------------------------
# Reads the kernel ring buffer and the LACT daemon journal and counts lines that
# match a known GPU-failure signature. This does NOT detect the freeze itself --
# by definition a hard lock usually wedges the kernel before anything is logged --
# it only answers "did the GPU or its userspace driver say something unusual just
# before the box stopped". A present event is a correlation, never a cause.
JOURNAL_MODE="${NODE_HOST_JOURNAL:-auto}"          # auto | 1 | 0
JOURNAL_RECENT="${NODE_HOST_JOURNAL_RECENT:-900}"  # "recent" window, seconds
JOURNAL_MAX="${NODE_HOST_JOURNAL_MAX:-20000}"      # per-source line cap
JOURNAL_TIMEOUT="${NODE_HOST_JOURNAL_TIMEOUT:-10}"
JOURNAL_SLACK="${NODE_HOST_JOURNAL_SLACK:-5}"      # re-read overlap that bounds the window
# Overridable so --self-test can feed synthetic lines instead of a real journal.
JOURNALCTL="${NODE_HOST_JOURNALCTL:-journalctl}"
# The signatures. Kept as variables so a host whose driver logs differently can be
# tuned without editing the script; the defaults are the stable strings the NVIDIA
# and DRM/amdgpu drivers and LACT actually emit.
JOURNAL_NVRM_RE="${NODE_HOST_JOURNAL_NVRM_RE:-NVRM:|nvAssert|fallen off the bus}"
JOURNAL_DRM_RE="${NODE_HOST_JOURNAL_DRM_RE:-[*]ERROR[*]|GPU reset|ring .* timeout|VM_L2_PROTECTION_FAULT|amdgpu}"
JOURNAL_LACT_RE="${NODE_HOST_JOURNAL_LACT_RE:-configuration reloaded|GPU list reloaded|reloading GPUs|kernel drm subsystem event|resume event detected|configuration applied}"
JOURNAL_LACT_ERR_RE="${NODE_HOST_JOURNAL_LACT_ERR_RE:-could not apply|could not reapply|could not load GPU controllers|no GPUs were found|could not find GPU with id}"

# Bumped whenever the state file layout changes. A mismatch is classified "unknown"
# and rebased, which is the only safe way to read a state file written by a version
# whose field meanings are no longer known.
SCHEMA_VERSION=1
# The journal counters live in their own file with their own schema on purpose, so
# this work never bumps SCHEMA_VERSION and never rebases the 30-day freeze history.
JOURNAL_SCHEMA=1

# The GPU part is an optional section of THIS script rather than a second script,
# so there is one timer and one state machine instead of two competing over the
# same question. A machine with no NVIDIA GPU still gets the full generic
# heartbeat, plus an honest node_gpu_present 0.
FIELDS_FULL="index,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.max_limit,clocks.current.graphics,clocks.current.memory,clocks_event_reasons.active,pcie.link.gen.current,pcie.link.width.current,pstate"
FIELDS_MIN="index,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,pstate"

# Throttle reasons come back as "Active"/"Not Active" strings, so they need a
# second query and a mapping. These are the ones that explain heat and stalls.
# A real array, not a string: it is indexed by position below.
THROTTLE_NAMES=(
  gpu_idle applications_clocks_setting sw_power_cap hw_slowdown
  hw_thermal_slowdown hw_power_brake_slowdown sw_thermal_slowdown sync_boost
)
THROTTLE_COUNT=${#THROTTLE_NAMES[@]}
# index first, so each line can be attributed to a GPU without cross-referencing
# the main query. Every element needs its own prefix, hence the loop.
THROTTLE_QUERY=""
for n in "${THROTTLE_NAMES[@]}"; do
  THROTTLE_QUERY+="${THROTTLE_QUERY:+,}clocks_throttle_reasons.${n}"
done
THROTTLE_FIELDS="index,${THROTTLE_QUERY}"

# --- helpers ----------------------------------------------------------------
# [N/A] and empty both mean "this driver does not report it". Emit no metric
# rather than a bogus 0, so a threshold rule cannot act on a fake value.
# Values are trimmed first: nvidia-smi's CSV format is "a, b, c" with a space
# after every comma, and an untrimmed " 56" is not a number.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
is_num() { local s; s="$(trim "${1:-}")"; case "$s" in ''|*[!0-9.eE+-]*) return 1 ;; *) return 0 ;; esac; }
# Stricter non-negative integer test for the state file. is_num deliberately
# accepts "1e5" and "2.5" because it has to pass driver CSV through, and neither is
# a safe operand of $(( )), so the state file gets a test of its own.
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
mib_to_bytes() { local m; m="$(trim "${1:-}")"; is_num "$m" && printf '%s' "$(awk -v m="$m" 'BEGIN{printf "%.0f", m*1048576}')"; }

# Every state write goes through a temporary file in the same directory and is
# then renamed, so a reader -- node_exporter, or this script's next run -- never
# sees a half-written file even if the machine dies mid-write.
write_atomic() { # <destination> <single-line content>
  printf '%s\n' "$2" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1" 2>/dev/null
}

log() { # log <syslog priority> <message>
  "${LOGGER}" -t host-heartbeat -p "$1" -- "$2" 2>/dev/null || echo "host-heartbeat: $2" >&2
  return 0
}

query() { timeout "$TIMEOUT_S" "$NVIDIA_SMI" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null; }
query_with_rc() { # query_with_rc <fields> -> sets GLOBAL_RAW and GLOBAL_RC
  GLOBAL_RAW="$(timeout "$TIMEOUT_S" "$NVIDIA_SMI" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null)"; GLOBAL_RC=$?
}

# --- paths ------------------------------------------------------------------
# Kept in a function so --self-test can rebind every one of them into a sandbox
# without a second copy of the logic: a test that exercises a reimplementation
# proves nothing about the script that actually runs.
bind_paths() { # <textfile dir>
  OUT_DIR="$1"
  HOST_FILE="${OUT_DIR}/host_heartbeat.prom"
  GPU_FILE="${OUT_DIR}/nvidia_gpu.prom"
  # No .prom extension on the state files, so the textfile collector ignores them.
  STATE_FILE="${OUT_DIR}/host_heartbeat.state"
  EVENTS_FILE="${OUT_DIR}/host_heartbeat.events"
  # Deliberately the same file name and the same "<epoch> <gap>" format as the
  # previous version, so an existing alert rule and any file a human kept as
  # evidence keep working untouched. Nothing needs migrating.
  LATCH_FILE="${OUT_DIR}/nvidia_gpu.maxgap"
  MARKER_FILE="${NODE_HOST_SUSPEND_MARKER:-${OUT_DIR}/.hb_suspend.marker}"
  JOURNAL_FILE="${OUT_DIR}/journal_events.prom"
  JSTATE_FILE="${OUT_DIR}/host_heartbeat.journal.state"
}

# --- one run ----------------------------------------------------------------
run_once() {
  mkdir -p "$OUT_DIR" 2>/dev/null || { echo "host-heartbeat: no puedo crear $OUT_DIR" >&2; return 1; }
  local tmp_host="${HOST_FILE}.$$" tmp_gpu="${GPU_FILE}.$$" tmp_journal="${JOURNAL_FILE}.$$"
  trap 'rm -f "${tmp_host:-}" "${tmp_gpu:-}" "${tmp_journal:-}"' EXIT

  local now_epoch boot_id uptime_s up_int v
  now_epoch="$(date +%s)"
  boot_id="-"
  # Every read is guarded by -r on purpose: a read whose redirection fails makes
  # bash print its own "No such file or directory" on stderr, and this script runs
  # on every timer tick, so an unreadable /proc file must be silent, not noisy.
  if [[ -r "${BOOT_ID_FILE}" ]] && read -r boot_id < "${BOOT_ID_FILE}"; then
    [[ -n "${boot_id}" ]] || boot_id="-"
  fi
  uptime_s="-"
  if [[ -r "${UPTIME_FILE}" ]] && read -r _up _idle < "${UPTIME_FILE}"; then
    up_int="${_up%%.*}"
    is_uint "${up_int}" && uptime_s="${up_int}"
  fi

  # --- previous state -------------------------------------------------------
  local st_schema=0 st_epoch=0 st_boot="-" st_up="-" st_total=0
  local st_freeze=0 st_suspend=0 st_reboot=0 st_clock=0
  local st_le_epoch=0 st_le_gap=0 st_le_class="-" st_r_missing=0 st_r_malformed=0 st_r_absurd=0
  local st_ok=1
  if [[ -r "${STATE_FILE}" ]]; then
    read -r st_schema st_epoch st_boot st_up st_total st_freeze st_suspend st_reboot st_clock \
      st_le_epoch st_le_gap st_le_class st_r_missing st_r_malformed st_r_absurd < "${STATE_FILE}" || true
    # Every numeric field must validate. A state file torn by a freeze, truncated
    # by a reboot or written by another schema version all land here, and are
    # treated as "no information" -- never as a gap.
    for v in "$st_schema" "$st_epoch" "$st_total" "$st_freeze" "$st_suspend" "$st_reboot" \
             "$st_clock" "$st_le_epoch" "$st_le_gap" "$st_r_missing" "$st_r_malformed" "$st_r_absurd"; do
      is_uint "$v" || st_ok=0
    done
    [[ "${st_up}" == "-" ]] || is_uint "${st_up}" || st_ok=0
    case "${st_le_class}" in -|freeze|suspend|reboot|clock-step) ;; *) st_ok=0 ;; esac
    [[ -n "${st_boot}" ]] || st_ok=0
    [[ "${st_schema}" == "${SCHEMA_VERSION}" ]] || st_ok=0
  else
    st_ok=0
  fi

  # --- suspend marker -------------------------------------------------------
  # Consumed on read, always. A marker left over from a sleep that was already
  # classified would mislabel the next real freeze as a suspend, and a marker that
  # survived a reboot (the machine was power-cut mid-sleep, so no post hook ever
  # ran) is stale and must not turn the following reboot into a fake suspend.
  local mk_boot mk_start mk_end mk_phase mk_op
  mk_boot="-"; mk_start=0; mk_end=0; mk_phase="-"; mk_op="unknown"
  local marker_ok=0
  if [[ -r "${MARKER_FILE}" ]] && read -r mk_boot mk_start mk_end mk_phase mk_op < "${MARKER_FILE}" \
     && is_uint "${mk_start:-}" && is_uint "${mk_end:-}"; then
    if [[ "${mk_boot}" == "-" || "${mk_boot}" == "${boot_id}" ]]; then
      # An open marker (end == 0) means the post hook never ran. The machine is
      # awake now, so the sleep did end by some other means; take now as its end
      # rather than discarding evidence that has nothing to do without.
      [[ "${mk_end}" -eq 0 ]] && mk_end="${now_epoch}"
      marker_ok=1
    fi
  fi
  rm -f "${MARKER_FILE}" 2>/dev/null

  # --- classification, in the order documented at the top --------------------
  local cls="" reason="" gap=0 gap_known=0 reboot_signal=""
  if [[ "${st_ok}" -eq 0 ]]; then
    cls="unknown"
    if [[ ! -e "${STATE_FILE}" ]]; then reason="missing"; else reason="malformed"; fi
  else
    gap=$(( now_epoch - st_epoch ))
    gap_known=1
    # (2) reboot, from either of the two independent signals.
    if [[ "${boot_id}" != "-" && "${st_boot}" != "-" && "${boot_id}" != "${st_boot}" ]]; then
      cls="reboot"; reboot_signal="boot_id"
    elif [[ "${uptime_s}" != "-" && "${st_up}" != "-" ]] && [[ "${uptime_s}" -lt "${st_up}" ]]; then
      cls="reboot"; reboot_signal="uptime"
    fi
    # (3) a backwards clock. The delta is negative, so it is not a gap at all and
    # must not be exported as one: gap_known is cleared so the gap metric is
    # omitted rather than published as a negative duration, which reads as "the
    # machine ran backwards" and would drag any rate() or max_over_time() built on
    # it into nonsense. The magnitude goes to the journal instead.
    if [[ -z "${cls}" && "${gap}" -lt 0 ]]; then cls="clock-step"; gap_known=0; fi
    # (4) and (5) both need a gap above the threshold; below it this was a
    # healthy run and there is nothing to report.
    if [[ -z "${cls}" && "${gap}" -gt "${GAP_S}" ]]; then
      if [[ "${marker_ok}" -eq 1 && "${mk_end}" -ge "${st_epoch}" ]]; then
        cls="suspend"
      elif [[ "${boot_id}" != "-" && "${st_boot}" == "${boot_id}" ]] \
        && { [[ "${uptime_s}" == "-" ]] || [[ "${st_up}" == "-" ]] || [[ "${uptime_s}" -ge "${st_up}" ]]; }; then
        cls="freeze"
      else
        # A gap this large that cannot be attributed at all: no boot identity to
        # compare and no sleep marker. Calling that a freeze would be a guess, and
        # a guessed freeze is exactly the kind of evidence that sends someone
        # chasing a bug that never happened, so it is reported as unclassified.
        cls="unknown"; reason="unattributable"
      fi
    fi
    # (6) absolute sanity bound, applied to whatever class was just chosen.
    if [[ "${cls}" == "freeze" || "${cls}" == "suspend" || "${cls}" == "reboot" ]]; then
      [[ "${gap}" -gt "${SANITY_S}" ]] && { cls="unknown"; reason="absurd"; }
    fi
  fi

  # --- act ------------------------------------------------------------------
  local boot_changed=0
  [[ -n "${reboot_signal}" ]] && boot_changed=1
  local latch_epoch=0 latch_gap=0
  if [[ -r "${LATCH_FILE}" ]]; then
    read -r latch_epoch latch_gap < "${LATCH_FILE}" 2>/dev/null
    is_uint "${latch_epoch:-}" || latch_epoch=0
    is_uint "${latch_gap:-}" || latch_gap=0
  fi
  # Age out an old latch so one freeze does not nag forever.
  if [[ "${latch_epoch}" -gt 0 ]] && [[ $(( now_epoch - latch_epoch )) -gt "${LATCH_TTL}" ]]; then
    latch_epoch=0; latch_gap=0
  fi

  case "${cls}" in
    freeze)
      st_freeze=$(( st_freeze + 1 )); st_total=$(( st_total + 1 ))
      st_le_epoch="${now_epoch}"; st_le_gap="${gap}"; st_le_class="freeze"
      # Appended before the state write on purpose: a crash in between duplicates
      # one event line, which is self-healing and bounded by pruning, whereas a
      # crash after the state write would lose the worst-gap latch, and that is the
      # one artefact that cannot be reconstructed afterwards.
      printf '%s %s %s %s\n' "${now_epoch}" "${gap}" "freeze" "${boot_changed}" >> "${EVENTS_FILE}" 2>/dev/null
      # Only a freeze reaches the latch. A suspend, a reboot or a clock step must
      # never appear here: that false positive is the reason this rewrite exists.
      if [[ "${gap}" -gt "${latch_gap}" ]]; then
        latch_epoch="${now_epoch}"; latch_gap="${gap}"
        write_atomic "${LATCH_FILE}" "${latch_epoch} ${latch_gap}"
      fi
      log warning "heartbeat gap of ${gap}s (threshold ${GAP_S}s) classified freeze: the machine stayed powered on and this timer did not run for that long; worst gap latched at ${latch_gap}s"
      ;;
    suspend)
      st_suspend=$(( st_suspend + 1 )); st_total=$(( st_total + 1 ))
      st_le_epoch="${now_epoch}"; st_le_gap="${gap}"; st_le_class="suspend"
      printf '%s %s %s %s\n' "${now_epoch}" "${gap}" "suspend" "${boot_changed}" >> "${EVENTS_FILE}" 2>/dev/null
      log notice "heartbeat gap of ${gap}s classified suspend: a completed sleep transition (${mk_op}) spans it, so this is NOT a freeze and is deliberately not latched"
      ;;
    reboot)
      st_reboot=$(( st_reboot + 1 )); st_total=$(( st_total + 1 ))
      st_le_epoch="${now_epoch}"; st_le_gap="${gap}"; st_le_class="reboot"
      printf '%s %s %s %s\n' "${now_epoch}" "${gap}" "reboot" "${boot_changed}" >> "${EVENTS_FILE}" 2>/dev/null
      log notice "heartbeat gap of ${gap}s classified reboot (${reboot_signal} changed): cause is indeterminate - a user reboot, a power cut and a kernel panic with auto-reboot are indistinguishable from user space. This duration is how long the machine was down, a lower bound, not a measurement of a freeze."
      ;;
    clock-step)
      st_clock=$(( st_clock + 1 )); st_total=$(( st_total + 1 ))
      st_le_epoch="${now_epoch}"; st_le_gap="0"; st_le_class="clock-step"
      # Recorded as 0 on purpose: the real delta here is negative and a negative
      # duration is not a gap. The size of the correction is in the journal message,
      # which is where a free-form value belongs.
      printf '%s %s %s %s\n' "${now_epoch}" "0" "clock-step" "${boot_changed}" >> "${EVENTS_FILE}" 2>/dev/null
      log warning "wall clock moved backwards by $(( -gap ))s (stored epoch ${st_epoch} is later than ${now_epoch}): rebased, no gap reported, and the worst-gap latch was not touched"
      ;;
    *)
      # "unknown" is deliberately NOT an event: it is the absence of evidence, not
      # evidence of an absence, and putting it in the history would bury the real
      # events under rebase noise. It is counted separately so a machine that
      # rebases constantly is still visible, and it goes to journald, which is the
      # durable on-machine record.
      case "${reason}" in
        missing)
          st_r_missing=$(( st_r_missing + 1 ))
          log notice "no state file yet (${STATE_FILE}): baselining this run and reporting no gap for it" ;;
        malformed)
          st_r_malformed=$(( st_r_malformed + 1 ))
          log warning "state file present but unreadable, malformed or from another schema version (${STATE_FILE}): rebased, no gap reported. A state file torn by a freeze looks exactly like this, which is itself worth knowing." ;;
        absurd)
          st_r_absurd=$(( st_r_absurd + 1 ))
          log warning "computed gap of ${gap}s exceeds the ${SANITY_S}s sanity bound: treating the stored value as corrupt and rebasing" ;;
        unattributable)
          st_r_malformed=$(( st_r_malformed + 1 ))
          log warning "gap of ${gap}s (threshold ${GAP_S}s) with no boot identity and no suspend marker: not attributable to a freeze or to a sleep, so it is recorded as unclassified rather than guessed at" ;;
      esac
      ;;
  esac

  # --- state, written before anything slow ----------------------------------
  # This is the freeze-detection boundary. The epoch is stamped from the moment the
  # run STARTED, so if the machine dies in the middle of the work below, the next
  # run measures the gap from just before the death -- which is the freeze
  # duration. Stamping at the end instead would record the recovery time and
  # silently throw the freeze away.
  write_atomic "${STATE_FILE}" "${SCHEMA_VERSION} ${now_epoch} ${boot_id} ${uptime_s} ${st_total} ${st_freeze} ${st_suspend} ${st_reboot} ${st_clock} ${st_le_epoch} ${st_le_gap} ${st_le_class} ${st_r_missing} ${st_r_malformed} ${st_r_absurd}"

  prune_events
  emit_host_metrics "$tmp_host" "$gap_known" "$gap"
  mv -f "$tmp_host" "$HOST_FILE" 2>/dev/null
  emit_gpu_metrics "$tmp_gpu"
  mv -f "$tmp_gpu" "$GPU_FILE" 2>/dev/null
  emit_journal_metrics "$tmp_journal"
  mv -f "$tmp_journal" "$JOURNAL_FILE" 2>/dev/null
  return 0
}

# --- pruning ----------------------------------------------------------------
# Bounded on BOTH axes on purpose. Retention answers "how far back do I care"; the
# line cap answers "how much may this cost if the machine reboot-loops and every
# reboot is an event", and either bound alone leaves a hole -- 30 days of a box
# that rebooted every 30 seconds is 260k lines. The single awk pass drops anything
# older than the retention window, buffers only the survivors, and prints the last
# `max` of them, so the newest events are the ones kept and an over-long file never
# has to be held in memory in full. A 0 in either setting disables that bound.
prune_events() {
  [[ -s "${EVENTS_FILE}" ]] || return 0
  local retention="${EVENT_RETENTION}" cap="${EVENT_MAX}"
  [[ "${retention}" -gt 0 || "${cap}" -gt 0 ]] || return 0
  awk -v cutoff="$(( $(date +%s) - retention ))" -v max="${cap}" '
    $1 ~ /^[0-9]+$/ && $1 + 0 >= cutoff { buf[++n] = $0 }
    END {
      if (max + 0 <= 0) { for (i = 1; i <= n; i++) print buf[i]; exit }
      start = (n > max + 0) ? n - (max + 0) + 1 : 1
      for (i = start; i <= n; i++) print buf[i]
    }' "${EVENTS_FILE}" > "${EVENTS_FILE}.tmp" 2>/dev/null \
    && mv -f "${EVENTS_FILE}.tmp" "${EVENTS_FILE}" 2>/dev/null
  return 0
}

# --- journal correlation (read-only) ----------------------------------------
# Counts, per source, the kernel and LACT journal lines that match a known
# GPU-failure signature, and remembers when each was last seen. The count is a
# monotonic counter carried in a state file (never derived by counting a log that
# retention can trim, which would make it decrease). The timestamp is the series a
# dashboard lines up against a heartbeat gap.
emit_journal_metrics() { # <tmpfile>
  local tmp="$1"
  local now; now="$(date +%s)"
  local enabled=0 scan_ok=0

  # Previous counters and cursor. A separate file and a separate schema, so this
  # never rebases the freeze history in host_heartbeat.state.
  local j_schema=0 cursor=0
  local c_nvrm=0 c_drm=0 c_lact=0 c_lacterr=0
  local l_nvrm=0 l_drm=0 l_lact=0 l_lacterr=0
  local have_state=0
  if [[ -r "$JSTATE_FILE" ]]; then
    read -r j_schema cursor c_nvrm c_drm c_lact c_lacterr l_nvrm l_drm l_lact l_lacterr < "$JSTATE_FILE" || true
    if [[ "$j_schema" == "$JOURNAL_SCHEMA" ]] && [[ "$cursor" =~ ^[0-9]+([.][0-9]+)?$ ]] \
       && is_uint "${c_nvrm:-}" && is_uint "${c_drm:-}" && is_uint "${c_lact:-}" && is_uint "${c_lacterr:-}" \
       && is_uint "${l_nvrm:-}" && is_uint "${l_drm:-}" && is_uint "${l_lact:-}" && is_uint "${l_lacterr:-}"; then
      have_state=1
    fi
  fi
  if [[ "$have_state" -eq 0 ]]; then
    # First run, or an unreadable/corrupt state file: baseline the cursor at now and
    # count nothing from the past. Replaying history on a fresh install would
    # invent events that no gap of ours can be correlated with.
    cursor="$now"
    c_nvrm=0; c_drm=0; c_lact=0; c_lacterr=0
    l_nvrm=0; l_drm=0; l_lact=0; l_lacterr=0
  fi

  # Off by request, or nothing to read: say so rather than going silently empty, so
  # an empty panel can be told apart from "this host never logs GPU errors".
  local want=1
  case "$JOURNAL_MODE" in
    0) want=0 ;;
    auto) command -v "$JOURNALCTL" >/dev/null 2>&1 || want=0 ;;
  esac
  command -v "$JOURNALCTL" >/dev/null 2>&1 || want=0
  if [[ "$want" -eq 0 ]]; then
    {
      echo "# HELP node_journal_enabled 1 when this host exports GPU/kernel journal correlation metrics, 0 when the journal could not be read or the section is off."
      echo "# TYPE node_journal_enabled gauge"
      echo "node_journal_enabled 0"
    } > "$tmp" 2>/dev/null
    return 0
  fi
  enabled=1

  local since="${cursor%%.*}"
  [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  local kout="" lout="" rc_k=0 rc_l=0
  kout="$(timeout "$JOURNAL_TIMEOUT" "$JOURNALCTL" -k -o short-unix -n "$JOURNAL_MAX" --since "@${since}" --no-pager 2>/dev/null)"; rc_k=$?
  lout="$(timeout "$JOURNAL_TIMEOUT" "$JOURNALCTL" -u lactd.service -o short-unix -n "$JOURNAL_MAX" --since "@${since}" --no-pager 2>/dev/null)"; rc_l=$?
  [[ "$rc_k" -eq 0 && "$rc_l" -eq 0 ]] && scan_ok=1

  # One awk pass per journal. It skips anything at or before the cursor (the strict
  # skip that makes the --since overlap harmless), matches both signatures, and
  # reports the count and newest-to-see epoch for each, plus the overall newest.
  local k_scan l_scan
  k_scan="$(printf '%s\n' "$kout" | awk -v cur="$cursor" -v re1="$JOURNAL_NVRM_RE" -v re2="$JOURNAL_DRM_RE" '
    { ep = $1 + 0
      if (ep <= cur + 0) next
      if (ep > mx) mx = ep
      if ($0 ~ re1) { c1++; if (ep > f1) f1 = ep }
      if ($0 ~ re2) { c2++; if (ep > f2) f2 = ep } }
    END { printf "%d %.6f %d %.6f %.6f\n", c1, f1, c2, f2, mx }')"
  l_scan="$(printf '%s\n' "$lout" | awk -v cur="$cursor" -v re1="$JOURNAL_LACT_RE" -v re2="$JOURNAL_LACT_ERR_RE" '
    { ep = $1 + 0
      if (ep <= cur + 0) next
      if (ep > mx) mx = ep
      if ($0 ~ re1) { c1++; if (ep > f1) f1 = ep }
      if ($0 ~ re2) { c2++; if (ep > f2) f2 = ep } }
    END { printf "%d %.6f %d %.6f %.6f\n", c1, f1, c2, f2, mx }')"

  local d_cn d_l1 d_cd d_l2 d_mxk d_cl d_l3 d_ce d_l4 d_mxl
  read -r d_cn d_l1 d_cd d_l2 d_mxk <<< "$k_scan"
  read -r d_cl d_l3 d_ce d_l4 d_mxl <<< "$l_scan"

  c_nvrm=$(( c_nvrm + ${d_cn:-0} ));  c_drm=$(( c_drm + ${d_cd:-0} ))
  c_lact=$(( c_lact + ${d_cl:-0} ));  c_lacterr=$(( c_lacterr + ${d_ce:-0} ))

  local fl
  fl="${d_l1%%.*}"; [[ "$fl" =~ ^[0-9]+$ ]] && [[ "$fl" -gt "$l_nvrm" ]] && l_nvrm="$fl"
  fl="${d_l2%%.*}"; [[ "$fl" =~ ^[0-9]+$ ]] && [[ "$fl" -gt "$l_drm" ]] && l_drm="$fl"
  fl="${d_l3%%.*}"; [[ "$fl" =~ ^[0-9]+$ ]] && [[ "$fl" -gt "$l_lact" ]] && l_lact="$fl"
  fl="${d_l4%%.*}"; [[ "$fl" =~ ^[0-9]+$ ]] && [[ "$fl" -gt "$l_lacterr" ]] && l_lacterr="$fl"

  # Advance the cursor, never backwards: to the newest line seen, or to now minus a
  # small slack when the batch was empty or old, so an empty journal cannot grow the
  # window without bound. The slack re-reads a few seconds on purpose, and the
  # strict "<= cursor" skip above makes that overlap harmless.
  local new_cursor
  new_cursor="$(awk -v c="$cursor" -v a="${d_mxk:-0}" -v b="${d_mxl:-0}" -v f="$(( now - JOURNAL_SLACK ))" \
    'BEGIN { m = c + 0; if (a + 0 > m) m = a + 0; if (b + 0 > m) m = b + 0; if (f + 0 > m) m = f + 0; printf "%.6f", m }')"
  write_atomic "$JSTATE_FILE" "${JOURNAL_SCHEMA} ${new_cursor} ${c_nvrm} ${c_drm} ${c_lact} ${c_lacterr} ${l_nvrm} ${l_drm} ${l_lact} ${l_lacterr}"

  local nvrm_recent=0 drm_recent=0 lact_recent=0 lacerr_recent=0
  [[ "$l_nvrm" -gt 0 && $(( now - l_nvrm )) -le "$JOURNAL_RECENT" ]] && nvrm_recent=1
  [[ "$l_drm" -gt 0 && $(( now - l_drm )) -le "$JOURNAL_RECENT" ]] && drm_recent=1
  [[ "$l_lact" -gt 0 && $(( now - l_lact )) -le "$JOURNAL_RECENT" ]] && lact_recent=1
  [[ "$l_lacterr" -gt 0 && $(( now - l_lacterr )) -le "$JOURNAL_RECENT" ]] && lacerr_recent=1

  {
    echo "# HELP node_journal_enabled 1 when this host exports GPU/kernel journal correlation metrics, 0 when the journal could not be read or the section is off."
    echo "# TYPE node_journal_enabled gauge"
    echo "node_journal_enabled ${enabled}"
    echo "# HELP node_journal_scan_success 1 when both journal reads succeeded on the last run. 0 means the journal could not be read, so an empty chart must not be read as 'nothing happened'."
    echo "# TYPE node_journal_scan_success gauge"
    echo "node_journal_scan_success ${scan_ok}"
    echo "# HELP node_journal_last_scan_timestamp_seconds When the journal was last scanned."
    echo "# TYPE node_journal_last_scan_timestamp_seconds gauge"
    echo "node_journal_last_scan_timestamp_seconds ${now}"
    echo "# HELP node_journal_events_total Kernel and LACT journal lines matching a known GPU-failure signature, by source. Monotonic: counted in a state file, so pruning logs cannot make it decrease. nvrm NVIDIA driver errors, drm DRM/amdgpu errors, lact LACT reload/apply activity, lact-error LACT errors."
    echo "# TYPE node_journal_events_total counter"
    echo "node_journal_events_total{source=\"nvrm\"} ${c_nvrm}"
    echo "node_journal_events_total{source=\"drm\"} ${c_drm}"
    echo "node_journal_events_total{source=\"lact\"} ${c_lact}"
    echo "node_journal_events_total{source=\"lact-error\"} ${c_lacterr}"
    echo "# HELP node_journal_last_event_timestamp_seconds When the most recent matching line per source was logged, or 0 if none has been seen. Line this up against a heartbeat gap to see what the GPU was doing just before."
    echo "# TYPE node_journal_last_event_timestamp_seconds gauge"
    echo "node_journal_last_event_timestamp_seconds{source=\"nvrm\"} ${l_nvrm}"
    echo "node_journal_last_event_timestamp_seconds{source=\"drm\"} ${l_drm}"
    echo "node_journal_last_event_timestamp_seconds{source=\"lact\"} ${l_lact}"
    echo "node_journal_last_event_timestamp_seconds{source=\"lact-error\"} ${l_lacterr}"
    echo "# HELP node_journal_event_recent 1 while a matching line for this source was seen within the recent window (NODE_HOST_JOURNAL_RECENT). Present so alert and annotation queries do not have to do timestamp arithmetic."
    echo "# TYPE node_journal_event_recent gauge"
    echo "node_journal_event_recent{source=\"nvrm\"} ${nvrm_recent}"
    echo "node_journal_event_recent{source=\"drm\"} ${drm_recent}"
    echo "node_journal_event_recent{source=\"lact\"} ${lact_recent}"
    echo "node_journal_event_recent{source=\"lact-error\"} ${lacerr_recent}"
  } > "$tmp" 2>/dev/null
  return 0
}
# --- generic metrics --------------------------------------------------------
emit_host_metrics() { # <tmpfile> <gap known: 0|1> <gap>
  local tmp="$1" gap_known="$2" gap="$3"
  {
    echo "# HELP node_heartbeat_schema_version Layout version of the heartbeat state file. A jump means the state was rebaselined, which is worth knowing when comparing history across an upgrade."
    echo "# TYPE node_heartbeat_schema_version gauge"
    echo "node_heartbeat_schema_version ${SCHEMA_VERSION}"

    # Absent, not zero, when the system does not know the gap: on a fresh install
    # or right after a rebase there was no previous run to measure against, and a 0
    # would be indistinguishable from "ran back to back" to anything reading it.
    # The rule in this repo is that an unknown value emits no metric at all.
    if [[ "${gap_known}" -eq 1 ]]; then
      echo "# HELP node_heartbeat_gap_seconds Seconds between the previous heartbeat run and this one. Above the threshold the machine was powered on and this timer did not run for that long. Absent when there is no previous run to measure against."
      echo "# TYPE node_heartbeat_gap_seconds gauge"
      echo "node_heartbeat_gap_seconds ${gap}"
    fi

    if [[ "${st_le_class}" != "-" ]]; then
      echo "# HELP node_heartbeat_last_event_class Classification of the most recent heartbeat gap, as a label with a value of 1. The classes are freeze (powered on, timer starved), suspend (a completed sleep spans the gap), reboot (came back up), clock-step (the wall clock moved backwards) and unknown (state was unusable and had to be rebased)."
      echo "# TYPE node_heartbeat_last_event_class gauge"
      echo "node_heartbeat_last_event_class{class=\"${st_le_class}\"} 1"
      echo "# HELP node_heartbeat_last_event_duration_seconds Duration of the most recent classified gap. 0 for a clock-step, whose real delta is negative and is not a duration."
      echo "# TYPE node_heartbeat_last_event_duration_seconds gauge"
      echo "node_heartbeat_last_event_duration_seconds ${st_le_gap}"
      echo "# HELP node_heartbeat_last_event_timestamp_seconds When the most recent classified gap was detected."
      echo "# TYPE node_heartbeat_last_event_timestamp_seconds gauge"
      echo "node_heartbeat_last_event_timestamp_seconds ${st_le_epoch}"
    fi

    # Counters come from the state file, never from counting the event log. A
    # counter derived from a pruned log would go DOWN whenever retention trimmed it,
    # and a decreasing counter makes rate() and increase() produce nonsense and
    # fires counter-reset noise. These only ever go up.
    echo "# HELP node_heartbeat_events_total Heartbeat gaps classified as a real event of any kind (freeze, suspend, reboot, clock-step). Gaps at or below the threshold and unclassified rebases are not events and are not counted. Monotonic: counted in the state file, so pruning the event log cannot make it decrease."
    echo "# TYPE node_heartbeat_events_total counter"
    echo "node_heartbeat_events_total ${st_total}"
    echo "# HELP node_freeze_events_total Heartbeat gaps classified as a hard freeze: the machine stayed powered on and this timer did not run for longer than the threshold. This is the count behind an intermittent hang, as opposed to the worst-gap gauge which only remembers the single largest one. Suspends, reboots and clock steps are never counted here."
    echo "# TYPE node_freeze_events_total counter"
    echo "node_freeze_events_total ${st_freeze}"
    echo "# HELP node_heartbeat_suspend_events_total Heartbeat gaps explained by a completed sleep transition rather than by a hang. Published so the suspend filter is auditable: without it, a filter that works correctly looks exactly like a machine that never sleeps."
    echo "# TYPE node_heartbeat_suspend_events_total counter"
    echo "node_heartbeat_suspend_events_total ${st_suspend}"
    echo "# HELP node_heartbeat_events_by_class_total Classified heartbeat events per class, one series per class seen on this host. Use this rather than the worst-gap gauge to answer how often the machine hangs over a period."
    echo "# TYPE node_heartbeat_events_by_class_total counter"
    echo "node_heartbeat_events_by_class_total{class=\"freeze\"} ${st_freeze}"
    echo "node_heartbeat_events_by_class_total{class=\"suspend\"} ${st_suspend}"
    echo "node_heartbeat_events_by_class_total{class=\"reboot\"} ${st_reboot}"
    echo "node_heartbeat_events_by_class_total{class=\"clock-step\"} ${st_clock}"

    echo "# HELP node_heartbeat_rebases_total Runs where the stored state was unusable and had to be rebaselined, by reason. A state file torn by a freeze is indistinguishable from a corrupt one, so a rising malformed count is evidence of something rather than noise."
    echo "# TYPE node_heartbeat_rebases_total counter"
    echo "node_heartbeat_rebases_total{reason=\"missing\"} ${st_r_missing}"
    echo "node_heartbeat_rebases_total{reason=\"malformed\"} ${st_r_malformed}"
    echo "node_heartbeat_rebases_total{reason=\"absurd\"} ${st_r_absurd}"

    echo "# HELP node_heartbeat_boot_id_info Current kernel boot id as an info series. It changes on every boot, and that change is the signal used to tell a reboot from a freeze."
    echo "# TYPE node_heartbeat_boot_id_info gauge"
    if [[ "${boot_id}" != "-" ]]; then
      echo "node_heartbeat_boot_id_info{boot_id=\"${boot_id}\"} 1"
    fi
  } > "$tmp" 2>/dev/null
  return 0
}

# Helper to emit GPU status lines once per branch.
gpu_status() {
  local present="$1" success="$2" duration="$3"
  local ts
  ts="$(date +%s)"
  echo "node_gpu_present $present" >> "$tmp"
  echo "node_gpu_query_success $success" >> "$tmp"
  if [[ -n "$duration" ]]; then
    echo "node_gpu_query_duration_seconds $duration" >> "$tmp"
  fi
  echo "node_gpu_last_query_timestamp_seconds $ts" >> "$tmp"
}
emit_gpu_metrics() { # <tmpfile>
  local tmp="$1"
  {
    # A negative delta is not a duration, so this legacy gauge is omitted for it,
    # exactly as the generic one is. Every other case is byte-identical to what
    # the old script published, including the 0 it emitted on a first run, which
    # existing queries may rely on.
    if [[ "${gap}" -ge 0 ]]; then
      echo "# HELP node_gpu_heartbeat_gap_seconds Seconds since the previous heartbeat run; above the threshold it means the box was not running this script. Kept under the historical node_gpu_ name for existing dashboards: the gap is now measured by the generic host heartbeat, not by a GPU-specific one."
      echo "# TYPE node_gpu_heartbeat_gap_seconds gauge"
      echo "node_gpu_heartbeat_gap_seconds ${gap}"
    fi
    echo "# HELP node_gpu_heartbeat_max_gap_seconds Longest gap still within the latch window, latched ONLY for gaps classified as a hard freeze. A suspend, a reboot or a clock step never reaches it, so this stays hard-freeze evidence instead of becoming the machine's bedtime."
    echo "# TYPE node_gpu_heartbeat_max_gap_seconds gauge"
    echo "node_gpu_heartbeat_max_gap_seconds ${latch_gap}"
    echo "# HELP node_gpu_heartbeat_max_gap_timestamp_seconds When that worst freeze gap was observed, or 0 if none is latched."
    echo "# TYPE node_gpu_heartbeat_max_gap_timestamp_seconds gauge"
    echo "node_gpu_heartbeat_max_gap_timestamp_seconds ${latch_epoch}"
  } > "$tmp" 2>/dev/null

  # No driver, or the operator turned the GPU section off: say so honestly and stop.
  # The generic heartbeat above is already complete without it.
  if [[ "${GPU_MODE}" == "0" ]] || { [[ "${GPU_MODE}" == "auto" ]] && ! command -v "$NVIDIA_SMI" >/dev/null 2>&1; }; then
    gpu_status 0 0 ""
    return 0
  fi

  local start end duration RAW TRAW line idx temp util utilmem memused memtotal pdraw pmax
  local clk_g clk_m evr pcgen pcwidth pstate gpu b v i
  local GLOBAL_RAW="" GLOBAL_RC=0
  start=$(date +%s.%N)
  query_with_rc "$FIELDS_FULL"
  RAW="$GLOBAL_RAW"
  # Fall back to the reduced set if the driver rejects any of the full fields.
  if [[ "$GLOBAL_RC" -ne 0 ]] || [[ -z "$RAW" ]]; then
    query_with_rc "$FIELDS_MIN"
    RAW="$GLOBAL_RAW"
  fi
  end=$(date +%s.%N)
  duration="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.4f", b-a}')"

  if [[ "$GLOBAL_RC" -ne 0 ]] || [[ -z "$RAW" ]]; then
    gpu_status 1 0 "$duration"
    echo "host-heartbeat: $NVIDIA_SMI no respondio (timeout ${TIMEOUT_S}s o fallo)" >&2
    return 0
  fi
  # Be defensive: some failures print to stdout but exit 0; only treat as success
  # if the first line starts with a numeric GPU index.
  local first_line idx_first
  first_line="$(printf '%s\n' "$RAW" | head -n1)"
  first_line="${first_line//[[:space:]]/}"
  IFS=',' read -r idx_first _ <<< "$first_line"
  if ! is_uint "$idx_first"; then
    gpu_status 1 0 "$duration"
    echo "host-heartbeat: $NVIDIA_SMI devolvio salida inesperada o con error (sin indice numerico)" >&2
    return 0
  fi

  {
    gpu_status 1 1 "$duration"
    echo "# HELP node_gpu_collectors_count Number of GPUs reported by nvidia-smi."
    echo "# TYPE node_gpu_collectors_count gauge"
    echo "node_gpu_collectors_count $(printf '%s\n' "$RAW" | grep -c .)"
  } >> "$tmp"

  emit() { # emit <name> <value> <gpu-label>
    local val; val="$(trim "${2:-}")"
    is_num "$val" && echo "node_gpu_$1{gpu=\"$3\"} $val" >> "$tmp"
    return 0
  }

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # nvidia-smi pads its CSV with "a, b, c"; drop the padding before splitting.
    line="${line//[[:space:]]/}"
    IFS=',' read -r idx temp util utilmem memused memtotal pdraw pmax clk_g clk_m evr pcgen pcwidth pstate <<<"$line"
    gpu="gpu${idx}"
    emit temperature_celsius      "$temp"      "$gpu"
    emit utilization_percent      "$util"      "$gpu"
    emit memory_utilization_percent "$utilmem" "$gpu"
    if b="$(mib_to_bytes "$memused")"; then echo "node_gpu_memory_used_bytes{gpu=\"$gpu\"} $b" >> "$tmp"; fi
    if b="$(mib_to_bytes "$memtotal")"; then echo "node_gpu_memory_total_bytes{gpu=\"$gpu\"} $b" >> "$tmp"; fi
    emit power_draw_watts         "$pdraw"     "$gpu"
    emit power_max_limit_watts    "$pmax"      "$gpu"
    emit clocks_sm_mhz            "$clk_g"     "$gpu"
    emit clocks_mem_mhz           "$clk_m"     "$gpu"
    emit pcie_link_gen_current    "$pcgen"     "$gpu"
    emit pcie_link_width_current  "$pcwidth"   "$gpu"
    # pstate is a string (P0..P8). Expose it as a label so it is queryable.
    case "${pstate:-}" in P[0-9]*) echo "node_gpu_pstate_info{gpu=\"$gpu\",pstate=\"$pstate\"} 1" >> "$tmp" ;; esac
    # clocks_event_reasons.active is a hex bitmask; bash arithmetic reads 0x.. for us.
    case "${evr:-}" in 0x*) echo "node_gpu_clocks_event_reasons_active{gpu=\"$gpu\"} $((evr))" >> "$tmp" ;; esac
  done <<< "$RAW"

  # Throttle reasons: best effort. If this query fails we simply lose the throttle
  # detail, which is not worth failing the whole heartbeat for.
  if TRAW="$(query "$THROTTLE_FIELDS")" && [ -n "$TRAW" ]; then
    {
      echo "# HELP node_gpu_throttle_reason_active 1 while this clock throttle reason is asserted."
      echo "# TYPE node_gpu_throttle_reason_active gauge"
    } >> "$tmp"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=',' read -r -a cells <<<"$line"
      # one index cell + one cell per reason; anything else means the driver
      # answered with a different shape than we asked for, so skip it.
      [ "${#cells[@]}" -eq "$((THROTTLE_COUNT + 1))" ] || continue
      idx="$(trim "${cells[0]}")"
      for ((i = 0; i < THROTTLE_COUNT; i++)); do
        case "$(trim "${cells[i + 1]}")" in
          Active) v=1 ;;
          *)      v=0 ;;
        esac
        echo "node_gpu_throttle_reason_active{gpu=\"gpu${idx}\",reason=\"${THROTTLE_NAMES[i]}\"} $v" >> "$tmp"
      done
    done <<< "$TRAW"
  fi
  return 0
}

# --- self test --------------------------------------------------------------
# The only way to test freeze detection without actually freezing, so it lives in
# the script instead of waiting for a machine that happens to hang one day. Every
# case drives the real run_once() against a sandbox directory with synthetic /proc
# facts; nothing here re-implements the classifier, because a test that exercises a
# copy proves nothing about the script that runs. No root, no systemd, no sleep, no
# contact with the real state directory.
SELFTMP=""
SELF_PASS=0
SELF_FAIL=0
LOG_CAPTURE=""
ST_BOOT="aaaaaaaa-0000-0000-0000-000000000001"
ST_UPTIME="1000"

sandbox() { # <name>: fresh directory with a synthetic boot id and uptime
  local d="${SELFTMP}/$1"
  rm -rf "${d}"; mkdir -p "${d}"
  printf '%s\n' "${ST_BOOT}" > "${d}/boot_id"
  printf '%s\n' "${ST_UPTIME}" > "${d}/uptime"
  printf '%s\n' "${d}"
}

# Synthesise a state file exactly as run_once writes it:
# schema epoch boot uptime total freeze suspend reboot clock le_epoch le_gap le_class r_missing r_malformed r_absurd
selftest_state() {
  write_atomic "${STATE_FILE}" "${SCHEMA_VERSION} $1 $2 $3 ${4:-0} ${5:-0} ${6:-0} ${7:-0} ${8:-0} ${9:-0} ${10:-0} ${11:--} ${12:-0} ${13:-0} ${14:-0}"
}

ok() { SELF_PASS=$(( SELF_PASS + 1 )); printf '  PASS  %s\n' "$1"; return 0; }
no() {
  SELF_FAIL=$(( SELF_FAIL + 1 ))
  printf '  FAIL  %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
  return 0
}
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
# Like check, but tolerant of a one-second wall-clock tick between when the case
# captures `now` and when run_once reads the clock. A gap is derived from two real
# date +%s calls, so exact equality is a race, not a property of the script.
check_near() { # check_near <label> <expected> <actual> [tolerance]
  local d=$(( $3 - $2 )); d="${d#-}"
  if [[ "$d" -le "${4:-1}" ]]; then ok "$1"; else no "$1" "expected ~[$2] +/-${4:-1}, got [$3]"; fi
}
classes() { awk '{ printf "%s ", $3 }' "$1" 2>/dev/null; }
last_field() { awk -v n="$2" 'END { print $n }' "$1" 2>/dev/null; }
lines_in() { awk 'END { print NR }' "$1" 2>/dev/null; }
reset_log() { : > "${LOG_CAPTURE}"; }
log_says() { grep -q "$1" "${LOG_CAPTURE}" 2>/dev/null; }
# Read one source's value out of the journal metrics file: src_metric <metric> <source>
src_metric() { grep -F "$1{source=\"$2\"}" "${JOURNAL_FILE}" 2>/dev/null | awk '{ print $2 }'; }
# Seed the journal state file directly, so a case can put the cursor in the past
# on purpose instead of having to wait for a real baseline.
selftest_jstate() { write_atomic "${JSTATE_FILE}" "$1"; }

selftest() {
  SELFTMP="$(mktemp -d "${TMPDIR:-/tmp}/host-heartbeat-selftest.XXXXXX")" || { echo "cannot create a temp dir"; return 1; }
  # Capture what would go to journald instead of writing to it, so the class in
  # each message can be asserted on a machine with no journal.
  LOG_CAPTURE="${SELFTMP}/journal.log"
  : > "${LOG_CAPTURE}"
  local capscript="${SELFTMP}/capture-logger"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${LOG_CAPTURE}" > "${capscript}"
  chmod 0755 "${capscript}"
  LOGGER="${NODE_HOST_LOGGER:-${capscript}}"
  GPU_MODE=0
  # Off by default so no case accidentally reads the real journal; the journal
  # section below turns it on with a shim.
  JOURNAL_MODE=0
  NVIDIA_SMI="nvidia-smi"

  printf '\n== gpu query ==\n'

  # Stub that returns a valid CSV for one GPU
  local gpu_ok="${SELFTMP}/nvidia-smi-ok"
  printf '#!/bin/sh\ncat <<'"'"'EOF'"'"'\n0, 56, 23, 5, 1024, 4096, 35, 120, 1500, 7000, 0x0, 1, 16, P0\nEOF\n' > "$gpu_ok"
  chmod 0755 "$gpu_ok"
  # Stub that prints NVML error to stdout and exits 1 (driver/library mismatch)
  local gpu_bad="${SELFTMP}/nvidia-smi-bad"
  printf '#!/bin/sh\necho "Failed to initialize NVML: Driver/library version mismatch"\nexit 1\n' > "$gpu_bad"
  chmod 0755 "$gpu_bad"
  # Stub that prints garbage to stdout but exits 0
  local gpu_garbage="${SELFTMP}/nvidia-smi-garbage"
  printf '#!/bin/sh\necho "ERROR: garbage"\nexit 0\n' > "$gpu_garbage"
  chmod 0755 "$gpu_garbage"

  d="$(sandbox gpu-ok)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  GPU_MODE=1; NVIDIA_SMI="$gpu_ok"
  run_once >/dev/null 2>&1
  grep -q '^node_gpu_query_success 1$' "${GPU_FILE}" && ok "gpu: valid CSV with exit 0 -> query_success 1" || no "gpu: valid CSV with exit 0 -> query_success 1"
  grep -q '^node_gpu_temperature_celsius{gpu="gpu0"}' "${GPU_FILE}" && ok "gpu: temperature parsed from valid CSV" || no "gpu: temperature parsed from valid CSV"

  d="$(sandbox gpu-bad)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  GPU_MODE=1; NVIDIA_SMI="$gpu_bad"
  run_once >/dev/null 2>&1
  grep -q '^node_gpu_query_success 0$' "${GPU_FILE}" && ok "gpu: NVML error on stdout + exit 1 -> query_success 0" || no "gpu: NVML error on stdout + exit 1 -> query_success 0"
  grep -q '^node_gpu_temperature_celsius' "${GPU_FILE}" && no "gpu: no temperature invented on failure" "temperature emitted" || ok "gpu: no temperature invented on failure"

  d="$(sandbox gpu-garbage)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  GPU_MODE=1; NVIDIA_SMI="$gpu_garbage"
  run_once >/dev/null 2>&1
  grep -q '^node_gpu_query_success 0$' "${GPU_FILE}" && ok "gpu: garbage stdout + exit 0 -> query_success 0 (defensive)" || no "gpu: garbage stdout + exit 0 -> query_success 0 (defensive)"
  grep -q '^node_gpu_temperature_celsius' "${GPU_FILE}" && no "gpu: no temperature invented on garbage" "temperature emitted" || ok "gpu: no temperature invented on garbage"

  GPU_MODE=0; NVIDIA_SMI="${NODE_HOST_NVIDIA_SMI:-nvidia-smi}"

  local now small_gap=10 large_gap=900 i
  now="$(date +%s)"
  local boot_a="11111111-1111-1111-1111-111111111111" boot_b="22222222-2222-2222-2222-222222222222"
  # The sandbox writes ST_BOOT into its synthetic boot id file, so it has to be the
  # same id the stored state claims, or every case would trivially be a reboot.
  ST_BOOT="${boot_a}"
  local d

  printf '\n== classification ==\n'

  # --- fresh state ---------------------------------------------------------
  d="$(sandbox fresh)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  run_once >/dev/null 2>&1
  check "fresh state: baselined, no event, no latch" "" "$(classes "${EVENTS_FILE}")"
  [[ -s "${STATE_FILE}" ]] && ok "fresh state: state file written" || no "fresh state: state file written"
  [[ -e "${LATCH_FILE}" ]] && no "fresh state: no latch created" "a latch file exists" || ok "fresh state: no latch created"
  grep -q '^node_heartbeat_events_total 0$' "${HOST_FILE}" && ok "fresh state: events_total is 0" || no "fresh state: events_total 0"
  grep -q '^node_heartbeat_gap_seconds' "${HOST_FILE}" && no "fresh state: gap metric omitted, no previous run" "gap metric emitted" || ok "fresh state: gap metric omitted, no previous run"
  grep -q '^node_heartbeat_last_event_class' "${HOST_FILE}" && no "fresh state: last event class omitted, no event yet" "class emitted" || ok "fresh state: last event class omitted, no event yet"

  # --- normal repeat -------------------------------------------------------
  d="$(sandbox normal)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - small_gap ))" "${boot_a}" "1000"
  run_once >/dev/null 2>&1
  check "normal repeat: a gap below the threshold produces no event" "" "$(classes "${EVENTS_FILE}")"
  check_near "normal repeat: the real gap is exposed" "${small_gap}" "$(grep '^node_heartbeat_gap_seconds ' "${HOST_FILE}" | awk '{print $2}')"

  # --- freeze --------------------------------------------------------------
  d="$(sandbox freeze)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - large_gap ))" "${boot_a}" "1000"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '4000\n' > "${d}/uptime"    # uptime rose by more than the gap: stayed powered on
  reset_log
  run_once >/dev/null 2>&1
  check "freeze: same boot_id and rising uptime classifies freeze" "freeze " "$(classes "${EVENTS_FILE}")"
  check_near "freeze: the event records the gap duration" "${large_gap}" "$(last_field "${EVENTS_FILE}" 2)"
  check_near "freeze: worst gap latched" "${large_gap}" "$(last_field "${LATCH_FILE}" 2)"
  grep -q "^node_freeze_events_total 1$" "${HOST_FILE}" && ok "freeze: node_freeze_events_total is 1" || no "freeze: node_freeze_events_total"
  check_near "freeze: legacy latch metric keeps its name and value" "${large_gap}" "$(grep '^node_gpu_heartbeat_max_gap_seconds ' "${GPU_FILE}" | awk '{print $2}')"
  grep -q '^node_heartbeat_last_event_class{class="freeze"} 1$' "${HOST_FILE}" && ok "freeze: last event class exported as a label" || no "freeze: last event class label"
  log_says "classified freeze" && ok "freeze: journald message names the class" || no "freeze: journald message names the class"

  # --- reboot, detected by boot_id ----------------------------------------
  d="$(sandbox reboot-bootid)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  write_atomic "${LATCH_FILE}" "1 5000"     # pre-existing evidence that must survive
  selftest_state "$(( now - large_gap ))" "${boot_b}" "9999"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '50\n' > "${d}/uptime"
  reset_log
  run_once >/dev/null 2>&1
  check "reboot (boot_id): classified reboot" "reboot " "$(classes "${EVENTS_FILE}")"
  check_near "reboot (boot_id): offline duration recorded" "${large_gap}" "$(last_field "${EVENTS_FILE}" 2)"
  check "reboot (boot_id): boot_changed flag set" "1" "$(last_field "${EVENTS_FILE}" 4)"
  check "reboot (boot_id): nvidia_gpu.maxgap left untouched" "1 5000" "$(last_field "${LATCH_FILE}" 1) $(last_field "${LATCH_FILE}" 2)"
  grep -q '^node_freeze_events_total 0$' "${HOST_FILE}" && ok "reboot (boot_id): no freeze counted" || no "reboot (boot_id): freeze counted"
  grep -q '^node_heartbeat_events_by_class_total{class="reboot"} 1$' "${HOST_FILE}" && ok "reboot (boot_id): counted per class" || no "reboot (boot_id): per-class counter"
  log_says "indeterminate" && ok "reboot (boot_id): the cause is reported as indeterminate" || no "reboot (boot_id): indeterminate wording"
  log_says "classified freeze" && no "reboot (boot_id): never claims a freeze" "the log says freeze" || ok "reboot (boot_id): never claims a freeze"

  # --- reboot, detected by a decreased uptime with an identical boot_id ----
  d="$(sandbox reboot-uptime)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  write_atomic "${LATCH_FILE}" "7 4242"
  selftest_state "$(( now - large_gap ))" "${boot_a}" "9999"
  printf '120\n' > "${d}/uptime"      # stored 9999 > now 120, but the boot_id never changed
  run_once >/dev/null 2>&1
  check "reboot (uptime): classified reboot from the uptime signal alone" "reboot " "$(classes "${EVENTS_FILE}")"
  check "reboot (uptime): nvidia_gpu.maxgap left untouched" "7 4242" "$(last_field "${LATCH_FILE}" 1) $(last_field "${LATCH_FILE}" 2)"
  grep -q '^node_freeze_events_total 0$' "${HOST_FILE}" && ok "reboot (uptime): no freeze counted" || no "reboot (uptime): freeze counted"

  # --- clock moved backwards ----------------------------------------------
  d="$(sandbox clockstep)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  write_atomic "${LATCH_FILE}" "3 3333"
  selftest_state "$(( now + 3600 ))" "${boot_a}" "1000"
  printf '4000\n' > "${d}/uptime"
  reset_log
  run_once >/dev/null 2>&1
  check "clock-step: classified clock-step" "clock-step " "$(classes "${EVENTS_FILE}")"
  check "clock-step: the negative delta is never stored as a gap" "0" "$(last_field "${EVENTS_FILE}" 2)"
  check "clock-step: the latch is not updated" "3 3333" "$(last_field "${LATCH_FILE}" 1) $(last_field "${LATCH_FILE}" 2)"
  grep -q '^node_freeze_events_total 0$' "${HOST_FILE}" && ok "clock-step: no freeze counted" || no "clock-step: freeze counted"
  log_says "moved backwards" && ok "clock-step: the correction size is logged" || no "clock-step: logged correction size"
  # The published gauges are the part a dashboard actually reads, and a negative
  # one there survives every rate() and max_over_time() built on it. Both files
  # are scanned because the legacy name lives in the GPU file.
  grep -h '^[a-z]' "${HOST_FILE}" "${GPU_FILE}" | grep -q ' -[0-9]' \
    && no "clock-step: no gauge anywhere publishes a negative duration" "a negative value was published" \
    || ok "clock-step: no gauge anywhere publishes a negative duration"
  grep -q '^node_heartbeat_gap_seconds ' "${HOST_FILE}" \
    && no "clock-step: the generic gap gauge is omitted, not zeroed" "gap gauge emitted" \
    || ok "clock-step: the generic gap gauge is omitted, not zeroed"
  grep -q '^node_gpu_heartbeat_gap_seconds ' "${GPU_FILE}" \
    && no "clock-step: the legacy gap gauge is omitted too" "legacy gap gauge emitted" \
    || ok "clock-step: the legacy gap gauge is omitted too"

  # --- an extreme backwards step, same branch ------------------------------
  d="$(sandbox negative)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  write_atomic "${LATCH_FILE}" "5 5555"
  selftest_state "$(( now + 31536000 ))" "${boot_a}" "1000"
  run_once >/dev/null 2>&1
  check "negative gap (1 year back): still clock-step, never a negative duration" "clock-step 0" "$(awk '{ printf "%s %s", $3, $2 }' "${EVENTS_FILE}")"
  check "negative gap: the latch is untouched" "5 5555" "$(last_field "${LATCH_FILE}" 1) $(last_field "${LATCH_FILE}" 2)"

  # --- suspend -------------------------------------------------------------
  d="$(sandbox suspend)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  write_atomic "${LATCH_FILE}" "2 2222"
  selftest_state "$(( now - large_gap ))" "${boot_a}" "1000"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '%s %s %s %s %s\n' "${boot_a}" "$(( now - large_gap ))" "$(( now - 5 ))" "post" "suspend" > "${MARKER_FILE}"
  reset_log
  run_once >/dev/null 2>&1
  check "suspend: classified suspend, not freeze" "suspend " "$(classes "${EVENTS_FILE}")"
  check "suspend: no freeze latch is written" "2 2222" "$(last_field "${LATCH_FILE}" 1) $(last_field "${LATCH_FILE}" 2)"
  check "suspend: the legacy latch metric is unchanged" "0" "$(grep '^node_gpu_heartbeat_max_gap_seconds ' "${GPU_FILE}" | awk '{print $2}')"
  grep -q '^node_heartbeat_suspend_events_total 1$' "${HOST_FILE}" && ok "suspend: the suspend counter is incremented" || no "suspend: suspend counter"
  grep -q '^node_freeze_events_total 0$' "${HOST_FILE}" && ok "suspend: the freeze counter stays 0" || no "suspend: freeze counter"
  [[ -e "${MARKER_FILE}" ]] && no "suspend: the marker is consumed after use" "the marker is still there" || ok "suspend: the marker is consumed after use"
  log_says "NOT a freeze" && ok "suspend: the message states it is not a freeze" || no "suspend: message wording"

  # The same 200s gap with the marker removed has to come out the other way, or
  # "classified suspend" proves nothing: it must be a freeze that latches.
  d="$(sandbox no-marker)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - 200 ))" "${boot_a}" "40"
  run_once >/dev/null 2>&1
  check "no marker: the identical gap is a freeze, not a suspend" "freeze " "$(classes "${EVENTS_FILE}")"
  check_near "no marker: and it does latch" "200" "$(last_field "${LATCH_FILE}" 2)"

  # A marker whose boot id does not match this boot is a leftover from a machine
  # that was power-cut mid-sleep. Trusting it would turn the next real freeze into
  # a fake suspend, i.e. it would silence exactly the alert this exists to raise.
  d="$(sandbox foreign-marker)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - 200 ))" "${boot_a}" "40"
  printf '%s %s %s %s %s\n' "${boot_b}" "$(( now - 200 ))" "$(( now - 1 ))" "post" "suspend" > "${MARKER_FILE}"
  run_once >/dev/null 2>&1
  check "foreign marker: ignored, so the gap is a freeze" "freeze " "$(classes "${EVENTS_FILE}")"
  grep -q '^node_heartbeat_suspend_events_total 0$' "${HOST_FILE}" && ok "foreign marker: no suspend counted" || no "foreign marker: suspend counted"
  [[ -e "${MARKER_FILE}" ]] && no "foreign marker: it is consumed rather than left to mislabel the next gap" "still present" || ok "foreign marker: it is consumed rather than left to mislabel the next gap"

  # --- hibernate ------------------------------------------------------------
  d="$(sandbox hibernate)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - large_gap ))" "${boot_a}" "1000"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '%s %s %s %s %s\n' "${boot_a}" "$(( now - large_gap ))" "$(( now - 2 ))" "post" "hibernate" > "${MARKER_FILE}"
  run_once >/dev/null 2>&1
  check "hibernate: a hibernate marker classifies suspend as well" "suspend " "$(classes "${EVENTS_FILE}")"

  # --- a leftover marker from before a reboot is ignored --------------------
  d="$(sandbox stale-marker)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - large_gap ))" "${boot_b}" "9999"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '40\n' > "${d}/uptime"
  printf '%s %s %s %s %s\n' "${boot_b}" "$(( now - large_gap ))" "$(( now - 1 ))" "post" "suspend" > "${MARKER_FILE}"
  run_once >/dev/null 2>&1
  check "stale marker: a reboot outranks a leftover suspend marker" "reboot " "$(classes "${EVENTS_FILE}")"

  # --- missing state file --------------------------------------------------
  d="$(sandbox missing)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  run_once >/dev/null 2>&1
  check "missing state: unknown, and no event is invented" "" "$(classes "${EVENTS_FILE}")"
  [[ -s "${STATE_FILE}" ]] && ok "missing state: rebased into a usable state file" || no "missing state: rebased"
  grep -q '^node_heartbeat_rebases_total{reason="missing"} 1$' "${HOST_FILE}" && ok "missing state: counted as a missing rebase" || no "missing state: rebase counter"

  # --- corrupt state files -------------------------------------------------
  local n=0
  for corrupt in "garbage" "1 2 3" "" "9999999999999999999999 abc 1 0 0 0 0 0 0 0 0 0 0 0" "1 $(( now - large_gap )) $boot_a 1 0 0 0 0 0 0 - 0 0 0"; do
    n=$(( n + 1 ))
    d="$(sandbox "corrupt-$n")"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
    printf '%s\n' "${corrupt}" > "${STATE_FILE}"
    printf '%s\n' "${boot_a}" > "${d}/boot_id"
    run_once >/dev/null 2>&1
    check "corrupt state #${n} (${#corrupt} bytes): no event, rebased" "" "$(classes "${EVENTS_FILE}")"
    grep -q "^${SCHEMA_VERSION} " "${STATE_FILE}" && ok "corrupt state #${n}: rewritten with the current schema" || no "corrupt state #${n}: rewrite"
  done

  # --- wrong schema version ------------------------------------------------
  d="$(sandbox schema)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  printf '99 %s %s 1000 0 0 0 0 0 0 0 - 0 0 0\n' "$(( now - large_gap ))" "${boot_a}" > "${STATE_FILE}"
  run_once >/dev/null 2>&1
  check "wrong schema version: rebased, no event" "" "$(classes "${EVENTS_FILE}")"

  # --- absurd gap ----------------------------------------------------------
  d="$(sandbox absurd)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - 1000000000 ))" "${boot_a}" "1000"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  printf '2000000000\n' > "${d}/uptime"
  run_once >/dev/null 2>&1
  check "absurd gap (1e9 s): rejected as unknown, no event recorded" "" "$(classes "${EVENTS_FILE}")"
  check "absurd gap: no latch written" "" "$(cat "${LATCH_FILE}" 2>/dev/null)"
  grep -q '^node_heartbeat_rebases_total{reason="absurd"} 1$' "${HOST_FILE}" && ok "absurd gap: counted as an absurd rebase" || no "absurd gap: rebase counter"
  grep -q '^node_heartbeat_last_event_class' "${HOST_FILE}" && no "absurd gap: no last-event class is invented" "a class was emitted" || ok "absurd gap: no last-event class is invented"

  # --- a gap that cannot be attributed at all ------------------------------
  d="$(sandbox unattributable)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - large_gap ))" "-" "1000"
  printf '\n' > "${d}/boot_id"
  run_once >/dev/null 2>&1
  check "no boot id and no marker: not guessed to be a freeze" "" "$(classes "${EVENTS_FILE}")"
  grep -q '^node_freeze_events_total 0$' "${HOST_FILE}" && ok "unattributable gap: no freeze counted" || no "unattributable gap: freeze counted"

  printf '\n== history and pruning ==\n'

  # --- pruning: the line cap keeps the newest events ------------------------
  d="$(sandbox prune-cap)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  for ((i = 0; i < 60; i++)); do
    # Oldest first, the way an append-only log actually grows.
    printf '%s %s freeze 0\n' "$(( now - 60 * (59 - i) ))" "$(( 300 + i ))" >> "${EVENTS_FILE}"
  done
  EVENT_MAX=20 EVENT_RETENTION=2592000
  run_once >/dev/null 2>&1
  check "pruning: the file shrinks to the cap" "20" "$(lines_in "${EVENTS_FILE}")"
  check "pruning: the newest event is kept" "${now}" "$(last_field "${EVENTS_FILE}" 1)"
  check "pruning: the oldest survivors are the ones dropped" "$(( now - 60 * 19 ))" "$(awk 'NR==1 { print $1 }' "${EVENTS_FILE}")"
  check "pruning: the latch metric still reports no freeze" "0" "$(grep '^node_gpu_heartbeat_max_gap_seconds ' "${GPU_FILE}" | awk '{print $2}')"

  # --- pruning: the retention window on its own ----------------------------
  # Retention of two days against events one day apart, so the survivors sit a full
  # day away from the cutoff. A test that puts an event exactly ON the boundary is
  # not testing the filter, it is testing whether the second hand ticked between
  # building the data and running the script.
  d="$(sandbox prune-retention)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  # Offset by an hour so no seeded event sits exactly on the cutoff: an event on
  # the boundary is in or out depending on whether a wall-clock second ticked
  # between seeding and running, which would make this a flaky test of the clock.
  for ((i = 1; i <= 10; i++)); do
    printf '%s %s freeze 0\n' "$(( now - 86400 * i - 3600 ))" "400" >> "${EVENTS_FILE}"
  done
  printf '%s %s freeze 0\n' "${now}" "400" >> "${EVENTS_FILE}"
  EVENT_MAX=0 EVENT_RETENTION=172800
  run_once >/dev/null 2>&1
  check "pruning: the retention window alone drops everything older than it" "2" "$(lines_in "${EVENTS_FILE}")"
  check "pruning: the newest event survived the retention pass" "${now}" "$(last_field "${EVENTS_FILE}" 1)"
  check "pruning: the oldest survivor is the newest event inside the window" "$(( now - 90000 ))" "$(awk 'NR==1 { print $1 }' "${EVENTS_FILE}")"
  EVENT_MAX=5000 EVENT_RETENTION=2592000

  # --- counters stay monotonic even when the log is pruned away -------------
  d="$(sandbox counters)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  selftest_state "$(( now - large_gap ))" "${boot_a}" "1000" "40" "30" "5" "3" "2"
  printf '%s\n' "${boot_a}" > "${d}/boot_id"
  EVENT_MAX=1
  run_once >/dev/null 2>&1
  grep -q '^node_freeze_events_total 31$' "${HOST_FILE}" && ok "counters: monotonic even with the log pruned to a single line" || no "counters: monotonic" "$(grep '^node_freeze_events_total' "${HOST_FILE}")"

  printf '\n== the sleep hook ==\n'

  # --- suspend-then-hibernate, the four invocations -------------------------
  # Simulated by hand first, so a regression in the classification is visible even
  # if the hook script itself changes.
  d="$(sandbox hook-sim)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  local mk="${d}/sim.marker" t1=$(( now - 900 )) t2=$(( now - 890 )) t3=$(( now - 300 )) t4="${now}"
  # The inner pre must NOT overwrite the outer start epoch, and neither post may
  # shorten it. This is precisely what a naive implementation gets wrong.
  printf '%s %s 0 pre suspend-then-hibernate\n'  "${boot_a}" "${t1}" > "${mk}"
  printf '%s %s 0 pre suspend-then-hibernate\n'  "${boot_a}" "${t2}" > "${mk}.t"; mv -f "${mk}.t" "${mk}"
  printf '%s %s %s post suspend-then-hibernate\n' "${boot_a}" "${t1}" "${t3}" > "${mk}.t"; mv -f "${mk}.t" "${mk}"
  printf '%s %s %s post suspend-then-hibernate\n' "${boot_a}" "${t1}" "${t4}" > "${mk}.t"; mv -f "${mk}.t" "${mk}"
  check "nested marker: the outermost start epoch survived both inner writes" "${t1}" "$(last_field "${mk}" 2)"
  check "nested marker: the outermost end epoch survived both posts" "${t4}" "$(last_field "${mk}" 3)"
  cp "${mk}" "${MARKER_FILE}"
  selftest_state "${t1}" "${boot_a}" "1000"
  run_once >/dev/null 2>&1
  check "suspend-then-hibernate: a nested marker classifies suspend, not freeze" "suspend " "$(classes "${EVENTS_FILE}")"

  # --- and now the real hook script, through its four invocations -----------
  local hook; hook="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/host-heartbeat-sleep"
  if [[ -r "${hook}" ]]; then
    d="$(sandbox hook-real)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
    local hookdir="${d}/hookstate"; mkdir -p "${hookdir}"
    (
      export NODE_EXPORTER_STATE_DIR="${hookdir}"
      export NODE_HOST_SUSPEND_MARKER="${hookdir}/.hb_suspend.marker"
      bash "${hook}" pre suspend-then-hibernate
      bash "${hook}" pre suspend-then-hibernate
      bash "${hook}" post suspend-then-hibernate
      bash "${hook}" post suspend-then-hibernate
    )
    local hmk="${hookdir}/.hb_suspend.marker" hb hs he hphase hop
    read -r hb hs he hphase hop < "${hmk}" 2>/dev/null
    if is_uint "${hs:-}" && is_uint "${he:-}" && [[ "${hs}" -gt 0 && "${he}" -ge "${hs}" ]]; then
      ok "sleep hook: after four invocations the marker is one completed span (start set, end >= start)"
    else
      no "sleep hook: marker after four invocations" "start=${hs:-unset} end=${he:-unset}"
    fi
    # The hook stamps the real /proc boot id, so restate it with the sandbox one
    # before classifying; the heartbeat must reject a marker from another boot.
    awk -v b="${boot_a}" 'NR==1 { $1 = b } { print }' "${hmk}" > "${MARKER_FILE}"
    selftest_state "$(( $(date +%s) - large_gap ))" "${boot_a}" "1000"
    run_once >/dev/null 2>&1
    check "sleep hook: its real marker classifies the gap as suspend" "suspend " "$(classes "${EVENTS_FILE}")"
    # And a plain single suspend must work too.
    d="$(sandbox hook-single)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
    local sdir="${d}/hookstate"; mkdir -p "${sdir}"
    (
      export NODE_EXPORTER_STATE_DIR="${sdir}"
      export NODE_HOST_SUSPEND_MARKER="${sdir}/.hb_suspend.marker"
      bash "${hook}" pre suspend
      bash "${hook}" post suspend
    )
    awk -v b="${boot_a}" 'NR==1 { $1 = b } { print }' "${sdir}/.hb_suspend.marker" > "${MARKER_FILE}"
    selftest_state "$(( $(date +%s) - large_gap ))" "${boot_a}" "1000"
    run_once >/dev/null 2>&1
    check "sleep hook: a plain suspend classifies the gap as suspend" "suspend " "$(classes "${EVENTS_FILE}")"
  else
    printf '  SKIP  sleep hook cases: host-heartbeat-sleep is not next to this script\n'
  fi

  printf '\n== journal correlation ==\n'

  # A shim for journalctl that just prints a file each case rewrites, so the real
  # journal is never read. The failed variant proves scan_success can say 0.
  local jctl_out="${SELFTMP}/jctl.out" shim="${SELFTMP}/journalctl-shim" shim_fail="${SELFTMP}/journalctl-fail"
  printf '#!/bin/sh\ncat "%s"\n' "${jctl_out}" > "${shim}"; chmod 0755 "${shim}"
  printf '#!/bin/sh\nexit 1\n' > "${shim_fail}"; chmod 0755 "${shim_fail}"
  : > "${jctl_out}"
  local jbase=$(( now - 100 ))

  # --- first run baselines and counts nothing from history ------------------
  d="$(sandbox journal-fresh)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${shim}"; JOURNAL_RECENT=900
  run_once >/dev/null 2>&1
  check "journal: enabled reports 1 when journalctl is present" "1" "$(awk '/^node_journal_enabled /{print $2}' "${JOURNAL_FILE}")"
  check "journal: a fresh baseline counts nothing from history" "0" "$(src_metric node_journal_events_total nvrm)"
  [[ -s "${JSTATE_FILE}" ]] && ok "journal: a cursor state file is written" || no "journal: cursor state file written"

  # --- counting, last-seen, and the idempotent second pass ------------------
  d="$(sandbox journal-count)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${shim}"; JOURNAL_RECENT=900
  selftest_jstate "1 1000 0 0 0 0 0 0 0 0"
  {
    printf '%s kernel: NVRM: Xid (PCI:0000:01:00): 79, GPU has fallen off the bus\n' "$(( jbase + 1 ))"
    printf '%s kernel: amdgpu 0000:05:00.0: [drm] *ERROR* ring gfx timeout\n' "$(( jbase + 2 ))"
    printf '%s lactd: configuration reloaded\n' "$(( jbase + 3 ))"
    printf '%s lactd: could not apply new config: nope\n' "$(( jbase + 4 ))"
    printf '%s kernel: usb 1-1: new low-speed USB device\n' "$(( jbase + 5 ))"
  } > "${jctl_out}"
  run_once >/dev/null 2>&1
  check "journal: an NVRM/Xid line is counted" "1" "$(src_metric node_journal_events_total nvrm)"
  check "journal: a DRM/amdgpu error is counted" "1" "$(src_metric node_journal_events_total drm)"
  check "journal: a LACT reload line is counted" "1" "$(src_metric node_journal_events_total lact)"
  check "journal: a LACT error line is counted" "1" "$(src_metric node_journal_events_total lact-error)"
  check "journal: the newest NVRM epoch is remembered, not the newest line" "$(( jbase + 1 ))" "$(src_metric node_journal_last_event_timestamp_seconds nvrm)"
  check "journal: a line seen just now is flagged recent" "1" "$(src_metric node_journal_event_recent nvrm)"
  # Re-running with the same input must not count anything twice: the cursor is
  # past every synthetic line.
  run_once >/dev/null 2>&1
  check "journal: an identical second scan does not double count" "1" "$(src_metric node_journal_events_total nvrm)"
  [[ "$(awk '{ print $2 }' "${JSTATE_FILE}")" != "1000" ]] && ok "journal: the cursor advanced past the seeded value" || no "journal: cursor advanced"

  # --- an unrelated line matches nothing ------------------------------------
  d="$(sandbox journal-benign)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${shim}"; JOURNAL_RECENT=900
  selftest_jstate "1 1000 0 0 0 0 0 0 0 0"
  printf '%s kernel: usb 1-1: new low-speed USB device\n' "$(( jbase + 1 ))" > "${jctl_out}"
  run_once >/dev/null 2>&1
  check "journal: a benign line is not counted by any source" "0" "$(src_metric node_journal_events_total nvrm)"
  check "journal: a benign line leaves the LACT counter at zero too" "0" "$(src_metric node_journal_events_total lact)"

  # --- an old event is counted but not flagged recent -----------------------
  d="$(sandbox journal-old)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${shim}"; JOURNAL_RECENT=900
  selftest_jstate "1 1000 0 0 0 0 0 0 0 0"
  printf '%s kernel: NVRM: Xid (PCI:0000:01:00): 62\n' "$(( now - 100000 ))" > "${jctl_out}"
  run_once >/dev/null 2>&1
  check "journal: an old event is still counted" "1" "$(src_metric node_journal_events_total nvrm)"
  check "journal: but it is not flagged recent" "0" "$(src_metric node_journal_event_recent nvrm)"

  # --- an unreadable journal is reported, not hidden ------------------------
  d="$(sandbox journal-fail)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${shim_fail}"
  run_once >/dev/null 2>&1
  check "journal: a failed read sets scan_success to 0" "0" "$(awk '/^node_journal_scan_success /{print $2}' "${JOURNAL_FILE}")"
  check "journal: a failed read still reports enabled 1" "1" "$(awk '/^node_journal_enabled /{print $2}' "${JOURNAL_FILE}")"

  # --- off, or no journalctl at all -----------------------------------------
  d="$(sandbox journal-off)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=0; JOURNALCTL="${shim}"
  run_once >/dev/null 2>&1
  check "journal: mode 0 reports enabled 0" "0" "$(awk '/^node_journal_enabled /{print $2}' "${JOURNAL_FILE}")"

  d="$(sandbox journal-none)"; BOOT_ID_FILE="${d}/boot_id"; UPTIME_FILE="${d}/uptime"; bind_paths "$d"
  JOURNAL_MODE=1; JOURNALCTL="${SELFTMP}/no-such-journalctl"
  run_once >/dev/null 2>&1
  check "journal: a missing journalctl reports enabled 0 without crashing" "0" "$(awk '/^node_journal_enabled /{print $2}' "${JOURNAL_FILE}")"

  JOURNAL_MODE=0; JOURNALCTL="${NODE_HOST_JOURNALCTL:-journalctl}"

  printf '\n  %d passed, %d failed\n' "${SELF_PASS}" "${SELF_FAIL}"
  rm -rf "${SELFTMP}"
  [[ "${SELF_FAIL}" -eq 0 ]] || return 1
  return 0
}

# --- entry point ------------------------------------------------------------
case "${1:-}" in
  --self-test)
    # Never touch the real state directory from a test.
    selftest
    exit $?
    ;;
  --help|-h)
    printf 'usage: host-heartbeat.sh [--self-test]\n\n'
    printf 'Writes host_heartbeat.prom, nvidia_gpu.prom and journal_events.prom into\n'
    printf 'NODE_HOST_TEXTFILE_DIR, classifies every gap between runs and correlates the\n'
    printf 'kernel and LACT journals against it. --self-test drives every classification\n'
    printf 'branch in a sandbox and needs no root, no systemd and no real hang.\n'
    exit 0
    ;;
esac

bind_paths "$OUT_DIR"
run_once
