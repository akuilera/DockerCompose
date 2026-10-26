#!/bin/sh
# Bootstrap for the Prometheus + Alertmanager stack.
#
# Seeds the template and config directories under ${PATH_TO_CONTAINERS} on the
# first run, then syncs the committed templates from the repository clone (both
# mounted read-only), and always regenerates targets/nodes.yml from the device
# registry in ${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices.
set -eu

echo "[bootstrap] 1/5 dirs"
mkdir -p "$TMPL/rules" "$TMPL/targets" \
         "$C_PROM/rules" "$C_PROM/targets" \
         "$TMPL_ALERT" "$C_ALERT" \
         "$DATA" "$ALERTDATA"

echo "[bootstrap] 2/5 templates"
if [ ! -s "$TMPL/prometheus.yml" ]; then
  cp /seed-prometheus/prometheus.yml "$TMPL/prometheus.yml"
fi
if [ ! -s "$TMPL/rules/alerts.yml" ]; then
  cp /seed-prometheus/rules/alerts.yml "$TMPL/rules/alerts.yml"
fi
if [ ! -s "$TMPL_ALERT/alertmanager.yml" ]; then
  cp /seed-alertmanager/alertmanager.yml "$TMPL_ALERT/alertmanager.yml"
fi

echo "[bootstrap] 3/5 sync"
for f in prometheus.yml rules/alerts.yml; do
  [ -e "$C_PROM/$f" ] || cp "$TMPL/$f" "$C_PROM/$f"
done
[ -e "$C_ALERT/alertmanager.yml" ] || cp "$TMPL_ALERT/alertmanager.yml" "$C_ALERT/alertmanager.yml"

echo "[bootstrap] 4/5 nodes.yml (always regenerated from Devices/)"
: > "$C_PROM/targets/nodes.yml"
n_devices=0
for f in /devices/*/.env; do
  [ -f "$f" ] || continue
  unset DEVICE_NAME DEVICE_ADDR DEVICE_BATTERY DEVICE_GPU
  . "$f"
  [ -n "${DEVICE_NAME:-}" ] || {
    echo "[bootstrap] ERROR: $f -> DEVICE_NAME is missing"
    exit 1
  }
  case "$DEVICE_NAME" in
    *[!A-Za-z0-9.\ _-]*)
      echo "[bootstrap] ERROR: $f -> DEVICE_NAME has disallowed characters"
      echo "[bootstrap]        allowed: [A-Za-z0-9 ._-]"
      exit 1
      ;;
  esac
  [ -n "${DEVICE_ADDR:-}" ] || {
    echo "[bootstrap] ERROR: $f -> DEVICE_ADDR is missing"
    exit 1
  }
  printf "%s\n" \
    "- targets:" \
    "    - $DEVICE_ADDR" \
    "  labels:" \
    "    host: $DEVICE_NAME" \
    >> "$C_PROM/targets/nodes.yml"
  n_devices=$((n_devices + 1))
done

echo "[bootstrap] 5/5 validar nodes.yml"
n_blocks=$(grep -c "^[[:space:]]*-[[:space:]]targets:[[:space:]]*$" "$C_PROM/targets/nodes.yml" || true)
n_items=$(grep -c "^[[:space:]]*-[[:space:]]" "$C_PROM/targets/nodes.yml" || true)
if [ "$n_blocks" -eq 0 ] || [ "$n_devices" -eq 0 ]; then
  echo "[bootstrap] ERROR: no devices found in /devices."
  echo "[bootstrap]        Create one per machine in the repository clone at"
  echo "[bootstrap]        \${PATH_TO_COMPOSE}/Automatization/Monitoring/Devices/"
  echo "[bootstrap]        following the template: Automatization/Monitoring/Devices.example/example/.env.example"
  echo "[bootstrap]        (DEVICE_NAME=..., DEVICE_ADDR=ip:9100, DEVICE_BATTERY, DEVICE_GPU)"
  exit 1
fi
if [ "$n_items" -ne $((n_blocks * 2)) ]; then
  echo "[bootstrap] ERROR: nodes.yml malformed ($n_items items for $n_blocks blocks);"
  echo "[bootstrap]        Prometheus could not read it and every panel would be empty."
  exit 1
fi
echo "[bootstrap] nodes.yml OK: $n_blocks target(s) for $n_devices device(s)"

chown -R 65534:65534 "$DATA" "$ALERTDATA"
echo "[bootstrap] done"
