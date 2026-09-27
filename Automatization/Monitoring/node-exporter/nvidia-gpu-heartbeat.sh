#!/usr/bin/env bash
# =============================================================================
# NVIDIA GPU heartbeat for the node_exporter textfile collector.
#
# WHY THIS EXISTS
# A node_exporter scrape cannot detect a hard lock. When the machine freezes,
# the scrape fails and the series goes stale, which looks exactly like "the box
# was rebooted" or "the network died" -- you lose the moment it happened. This
# script writes a local file every N seconds instead, so:
#   * file stops being refreshed while the box is up  -> something froze
#   * nvidia-smi itself wedges                          -> query_success 0
# The second one is the valuable one: a hung nvidia-smi is a well known NVIDIA
# failure mode, and the timeout turns a potential hang into a metric.
#
# Tested on Fedora Linux. Writes into a directory only node_exporter reads.
# =============================================================================
set -uo pipefail

OUT_DIR="${NODE_GPU_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT_FILE="${OUT_DIR}/nvidia_gpu.prom"
TIMEOUT_S="${NODE_GPU_TIMEOUT:-5}"
GAP_S="${NODE_GPU_GAP_THRESHOLD:-60}"

# Full field set, then a reduced fallback. nvidia-smi rejects the WHOLE query
# if a single field is unknown, so every field here must be verified to exist.
# Note: power.limit returns [N/A] on some laptop drivers even when the limit is
# readable, hence power.max_limit. temperature.memory is often N/A -> omitted.
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

# [N/A] and empty both mean "this driver does not report it". Emit no metric
# rather than a bogus 0, so a threshold rule cannot act on a fake value.
# Values are trimmed first: nvidia-smi's CSV format is "a, b, c" with a space
# after every comma, and an untrimmed " 56" is not a number.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
is_num() { local s; s="$(trim "${1:-}")"; case "$s" in ''|*[!0-9.eE+-]*) return 1 ;; *) return 0 ;; esac; }
mib_to_bytes() { local m; m="$(trim "${1:-}")"; is_num "$m" && printf '%s' "$(awk -v m="$m" 'BEGIN{printf "%.0f", m*1048576}')"; }

query() { timeout "$TIMEOUT_S" nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null; }

# ---------------------------------------------------------------------------
# Freeze gap detection.
#
# This is the part that survives a hard lock, and it is the reason this script
# keeps state on disk. Prometheus CANNOT see a freeze: the box stops answering
# scrapes, and by the time it answers again the local timestamp is fresh again,
# so the gap never appears in any series. The only way to recover "the box was
# dead for N seconds at time T" after the fact is a local record written by
# something that did not run during the freeze -- which is exactly what this
# state file is: the timestamp of the previous run, compared against now.
#
# A raw gap is only visible for one scrape, which is easy to miss, so the worst
# gap is also LATCHED: it keeps the largest gap and when it happened until it
# ages out (or is cleared by hand). That latch is the only hard-freeze evidence
# that reaches Prometheus at all.
#
# The state files deliberately have NO .prom extension so the textfile collector
# ignores them, and they live next to the metrics so permissions are identical.
# ---------------------------------------------------------------------------
STATE_FILE="${OUT_DIR}/nvidia_gpu.lastrun"
LATCH_FILE="${OUT_DIR}/nvidia_gpu.maxgap"
LATCH_TTL="${NODE_GPU_MAX_GAP_TTL:-2592000}"   # 30 days
now_epoch="$(date +%s)"
last_epoch="0"
[[ -r "${STATE_FILE}" ]] && read -r last_epoch < "${STATE_FILE}" 2>/dev/null
is_num "${last_epoch:-}" || last_epoch=0
gap=0
if [[ "${last_epoch}" -gt 0 && "${now_epoch}" -gt "${last_epoch}" ]]; then
  gap=$(( now_epoch - last_epoch ))
fi

# Read the latch: "<epoch when it happened> <gap seconds>".
latch_epoch=0
latch_gap=0
if [[ -r "${LATCH_FILE}" ]]; then
  read -r latch_epoch latch_gap < "${LATCH_FILE}" 2>/dev/null
  is_num "${latch_epoch:-}" || latch_epoch=0
  is_num "${latch_gap:-}" || latch_gap=0
fi
# Age out an old latch so one freeze does not nag forever.
if [[ "${latch_epoch}" -gt 0 && $(( now_epoch - latch_epoch )) -gt "${LATCH_TTL}" ]]; then
  latch_epoch=0; latch_gap=0
fi
if [[ "${gap}" -gt "${latch_gap}" ]]; then
  latch_epoch="${now_epoch}"; latch_gap="${gap}"
  printf '%s %s\n' "${latch_epoch}" "${latch_gap}" > "${LATCH_FILE}.tmp" 2>/dev/null \
    && mv -f "${LATCH_FILE}.tmp" "${LATCH_FILE}" 2>/dev/null
fi

TMP="${OUT_FILE}.$$"
trap 'rm -f "$TMP"' EXIT

mkdir -p "$OUT_DIR" 2>/dev/null || { echo "nvidia-gpu-heartbeat: no puedo crear $OUT_DIR" >&2; exit 1; }

# A gap means the heartbeat did not run for longer than it should have: a
# freeze, a suspend, or a power cut. Journald is the durable record, because
# this is the only artefact that still exists after the machine comes back.
if [[ "${gap}" -gt "${GAP_S}" ]]; then
  msg="heartbeat gap of ${gap}s (threshold ${GAP_S}s) -- freeze, suspend or power loss suspected"
  logger -t nvidia-gpu-heartbeat -- "${msg}" 2>/dev/null || echo "nvidia-gpu-heartbeat: ${msg}" >&2
fi

{
  echo "# HELP node_gpu_present 1 if an NVIDIA GPU is visible to nvidia-smi."
  echo "# TYPE node_gpu_present gauge"
  echo "# HELP node_gpu_heartbeat_gap_seconds Seconds since the previous heartbeat run; above the threshold it means the box was not running this script."
  echo "# TYPE node_gpu_heartbeat_gap_seconds gauge"
  echo "node_gpu_heartbeat_gap_seconds ${gap}"
  echo "# HELP node_gpu_heartbeat_max_gap_seconds Longest heartbeat gap still within the latch window. This is the only hard-freeze evidence that reaches Prometheus."
  echo "# TYPE node_gpu_heartbeat_max_gap_seconds gauge"
  echo "node_gpu_heartbeat_max_gap_seconds ${latch_gap}"
  echo "# HELP node_gpu_heartbeat_max_gap_timestamp_seconds When that worst gap was observed, or 0 if none is latched."
  echo "# TYPE node_gpu_heartbeat_max_gap_timestamp_seconds gauge"
  echo "node_gpu_heartbeat_max_gap_timestamp_seconds ${latch_epoch}"
} > "$TMP"

# Stamp the run as soon as it starts, so a run that dies mid-way still counts as
# a run and does not produce a bogus gap on the next invocation.
printf '%s\n' "${now_epoch}" > "${STATE_FILE}.tmp" 2>/dev/null && mv -f "${STATE_FILE}.tmp" "${STATE_FILE}" 2>/dev/null

if ! command -v nvidia-smi >/dev/null 2>&1; then
  {
    echo "node_gpu_present 0"
    echo "node_gpu_query_success 0"
    echo "node_gpu_last_query_timestamp_seconds $(date +%s)"
  } >> "$TMP"
  mv -f "$TMP" "$OUT_FILE"; exit 0
fi

start=$(date +%s.%N)
RAW="$(query "$FIELDS_FULL")"
# Fall back to the reduced set if the driver rejects any of the full fields.
[ -n "$RAW" ] || RAW="$(query "$FIELDS_MIN")"
end=$(date +%s.%N)
duration="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.4f", b-a}')"

if [ -z "$RAW" ]; then
  {
    echo "node_gpu_present 1"
    echo "node_gpu_query_success 0"
    echo "node_gpu_query_duration_seconds $duration"
    echo "node_gpu_last_query_timestamp_seconds $(date +%s)"
  } >> "$TMP"
  mv -f "$TMP" "$OUT_FILE"
  echo "nvidia-gpu-heartbeat: nvidia-smi no respondio (timeout ${TIMEOUT_S}s o fallo)" >&2
  exit 0
fi

{
  echo "node_gpu_present 1"
  echo "node_gpu_query_success 1"
  echo "node_gpu_query_duration_seconds $duration"
  echo "node_gpu_last_query_timestamp_seconds $(date +%s)"
  echo "# HELP node_gpu_collectors_count Number of GPUs reported by nvidia-smi."
  echo "# TYPE node_gpu_collectors_count gauge"
  echo "node_gpu_collectors_count $(printf '%s\n' "$RAW" | grep -c .)"
} >> "$TMP"

emit() { # emit <name> <value> <gpu-label>
  local v; v="$(trim "${2:-}")"
  is_num "$v" && echo "node_gpu_$1{gpu=\"$3\"} $v" >> "$TMP"
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
  if b="$(mib_to_bytes "$memused")"; then echo "node_gpu_memory_used_bytes{gpu=\"$gpu\"} $b" >> "$TMP"; fi
  if b="$(mib_to_bytes "$memtotal")"; then echo "node_gpu_memory_total_bytes{gpu=\"$gpu\"} $b" >> "$TMP"; fi
  emit power_draw_watts         "$pdraw"     "$gpu"
  emit power_max_limit_watts    "$pmax"      "$gpu"
  emit clocks_sm_mhz            "$clk_g"     "$gpu"
  emit clocks_mem_mhz           "$clk_m"     "$gpu"
  emit pcie_link_gen_current    "$pcgen"     "$gpu"
  emit pcie_link_width_current  "$pcwidth"   "$gpu"
  # pstate is a string (P0..P8). Expose it as a label so it is queryable.
  case "${pstate:-}" in P[0-9]*) echo "node_gpu_pstate_info{gpu=\"$gpu\",pstate=\"$pstate\"} 1" >> "$TMP" ;; esac
  # clocks_event_reasons.active is a hex bitmask; bash arithmetic reads 0x.. for us.
  case "${evr:-}" in 0x*) echo "node_gpu_clocks_event_reasons_active{gpu=\"$gpu\"} $((evr))" >> "$TMP" ;; esac
done <<< "$RAW"

# Throttle reasons: best effort. If this query fails we simply lose the
# throttle detail, which is not worth failing the whole heartbeat for.
if TRAW="$(query "$THROTTLE_FIELDS")" && [ -n "$TRAW" ]; then
  {
    echo "# HELP node_gpu_throttle_reason_active 1 while this clock throttle reason is asserted."
    echo "# TYPE node_gpu_throttle_reason_active gauge"
  } >> "$TMP"
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
      echo "node_gpu_throttle_reason_active{gpu=\"gpu${idx}\",reason=\"${THROTTLE_NAMES[i]}\"} $v" >> "$TMP"
    done
  done <<< "$TRAW"
fi

mv -f "$TMP" "$OUT_FILE"
