#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./init-secrets.sh [--force] <Service> <secret1> [secret2 ...]

Creates Docker compose secret files at $PATH_TO_SECRETS/<Service>/.
A secret file is a plain text file whose content IS the value.

Secret types:
  <name>           Plain value. You paste it (read silently).
  <name>@mysql     MySQL connection URL, built for you. Asks for user,
                   host (default: mariadb), port (default: 3306), database
                   and password, then writes "mysql://user:pass@host:port/db".
                   The password is validated: only URL-safe characters
                   (A-Z a-z 0-9 _ . ~ -) are accepted.

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
  ./init-secrets.sh Vaultwarden admin_token db_url@mysql domain
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

should_write_file() {
    local file="$1"

    if [[ -f "${file}" ]] && ((!force)); then
        echo "exists - not created: ${file}"
        read -r -p "Recreate? This will DELETE the existing value. (y/N) " answer
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            echo "Keeping: ${file}"
            return 1
        fi
    fi
    return 0
}

write_value() {
    local file="$1" value="$2"

    printf '%s' "${value}" > "${file}"
    chmod 600 "${file}"
    echo "Written: ${file}"
}

prompt_secret() {
    local value
    while :; do
        read -s -p "Paste value for ${1}: " value
        echo >&2
        if [[ -z "${value}" ]]; then
            echo "Empty value. Skipping ${1}." >&2
            return 1
        fi
        printf '%s' "${value}"
        return
    done
}

prompt_nonempty() {
    local value
    while :; do
        read -r -p "${1}" value
        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return
        fi
        echo "${2}" >&2
    done
}

build_mysql_url() {
    local user host port name pass
    user="$(prompt_nonempty "DB user: " "DB user is required.")"
    read -r -p "DB host [mariadb]: " host
    host="${host:-mariadb}"
    read -r -p "DB port [3306]: " port
    port="${port:-3306}"
    name="$(prompt_nonempty "DB name: " "DB name is required.")"
    while :; do
        read -s -p "DB password: " pass
        echo >&2
        if [[ -z "${pass}" ]]; then
            echo "DB password is required." >&2
        elif [[ "${pass}" =~ [^A-Za-z0-9._~-] ]]; then
            echo "Unsafe character: password must only contain A-Z a-z 0-9 _ . ~ -" >&2
        else
            break
        fi
    done
    printf 'mysql://%s:%s@%s:%s/%s' "${user}" "${pass}" "${host}" "${port}" "${name}"
}

for secret in "${secrets[@]}"; do
    if [[ "${secret}" == *@mysql ]]; then
        name="${secret%@mysql}"
        file="${secret_dir}/${name}"
        if should_write_file "${file}"; then
            value="$(build_mysql_url)"
            write_value "${file}" "${value}"
            unset value
        fi
    else
        file="${secret_dir}/${secret}"
        if should_write_file "${file}"; then
            if value="$(prompt_secret "${secret}")"; then
                write_value "${file}" "${value}"
                unset value
            fi
        fi
    fi
done
