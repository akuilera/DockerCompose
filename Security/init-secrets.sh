#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./init-secrets.sh [--force] <Service> <secret1> [secret2 ...]

Creates Docker compose secret files at $PATH_TO_SECRETS/<Service>/.
A secret file is a plain text file whose content IS the value.

Options:
  --force   Recreate existing secrets without asking (deletes old value).
  -h, --help   Show this help.

Environment:
  PATH_TO_SECRETS  Base directory for secret files. Resolved in this order:
                   1. an already-set environment variable
                   2. ../global.env (repo root, git-ignored) if present
                   3. ~/.secrets (fallback)

Behavior:
  - Values are read silently and NEVER printed.
  - Files are written WITHOUT a trailing newline, with mode 600.
  - The service directory is created with mode 700.
  - Existing secrets are skipped after asking "Recreate?" (unless --force).

Examples:
  ./init-secrets.sh Vaultwarden admin_token db_url
  ./init-secrets.sh --force Vaultwarden admin_token
EOF
    exit 1
}

force=0
args=()
while (($#)); do
    case "$1" in
        --force) force=1 ;;
        -h | --help) usage ;;
        --) shift && args+=("$@") && break ;;
        -*) echo "Unknown option: $1" >&2 && usage ;;
        *) args+=("$1") ;;
    esac
    shift
done

if ((${#args[@]} < 2)); then
    usage
fi

service="${args[0]}"
secrets=("${args[@]:1}")

if [[ -z "${PATH_TO_SECRETS:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    global_env="${script_dir}/../global.env"
    if [[ -f "${global_env}" ]]; then
        # shellcheck disable=SC1090
        source "${global_env}"
    fi
fi

if [[ -z "${PATH_TO_SECRETS:-}" ]]; then
    echo "Warning: PATH_TO_SECRETS is not set and global.env was not found. Falling back to ~/.secrets" >&2
    PATH_TO_SECRETS="${HOME}/.secrets"
fi

secret_dir="${PATH_TO_SECRETS}/${service}"
mkdir -p "${PATH_TO_SECRETS}" "${secret_dir}"
chmod 700 "${PATH_TO_SECRETS}" "${secret_dir}"

for secret in "${secrets[@]}"; do
    file="${secret_dir}/${secret}"

    if [[ -f "${file}" ]] && ((!force)); then
        echo "exists - not created: ${file}"
        read -r -p "Recreate? This will DELETE the existing value. (y/N) " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            echo "Keeping: ${file}"
            continue
        fi
    fi

    read -s -p "Paste value for ${secret}: " value
    echo
    if [[ -z "${value}" ]]; then
        echo "Empty value. Skipping ${secret}." >&2
        continue
    fi

    printf '%s' "${value}" > "${file}"
    chmod 600 "${file}"
    unset value
    echo "Written: ${file}"
done
