#!/usr/bin/env bash
# Seeds node-exporter targets into the Portainer Git clone that backs the
# readonly config bind `./prometheus -> /etc/prometheus`.
#
# Why: on this host Docker cannot create bind-mount destinations that do not
# already exist inside the container image (mkdirat/mknod -> EROFS on the
# overlay rootfs). So personal files cannot be mounted in with their own bind;
# instead they must live inside the source of an already-working config bind.
#
# The durable personal file (real IPs) is kept OUT of the repo and OUT of
# /data, at ${PATH_TO_CONTAINERS}/Monitoring/Prometheus/nodes.yml. After every
# Portainer "Update stack" (re-clone wipes untracked files) run:
#
#   bash sync-config.sh && sudo docker kill -s HUP prometheus
#
# No personal data is committed; this script only cites env vars and
# placeholders. Run without arguments (reads PATH_TO_CONTAINERS) or pass the
# durable path explicitly as $1.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clone_targets="${script_dir}/targets"
example="${script_dir}/targets/nodes.yml.example"

if (($# >= 1)); then
  durable_target="$1"
elif [[ -n "${PATH_TO_CONTAINERS:-}" ]]; then
  durable_target="${PATH_TO_CONTAINERS}/Monitoring/Prometheus/nodes.yml"
else
  durable_target=""
fi

mkdir -p "${clone_targets}"

if [[ -n "${durable_target}" && -f "${durable_target}" ]]; then
  cp "${durable_target}" "${clone_targets}/nodes.yml"
  echo "No hay datos personales expuestos: nodes.yml sembrado desde ${durable_target}"
else
  cp "${example}" "${clone_targets}/nodes.yml"
  echo "No se encontró ${durable_target} (o PATH_TO_CONTAINERS vacío)."
  echo "Creado ${clone_targets}/nodes.yml desde el example:"
  echo "  1) edita la IP real del dispositivo en ese archivo"
  echo "  2) guárdalo como ${durable_target} (fuera del clon, durable)"
  echo "  3) re-ejecuta: bash $(basename "$0")"
fi

chmod 644 "${clone_targets}/nodes.yml"