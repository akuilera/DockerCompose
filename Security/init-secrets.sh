#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./init-secrets.sh [--force] <Service> <secret1> [secret2 ...]

Creates Docker compose secret files at $PATH_TO_SECRETS/<Service>/.
A secret file is a plain text file whose content IS the value.

Secret types:
  <name>           Plain value. You paste it (read silently).
  <name>@mysql     MySQL connection URL, built for you. Prompts for user,
                   host, port, database and password, then writes
                   "mysql://user:pass@host:port/db". Defaults derive from the
                   service name: <service>_user, <service>_db, host=mariadb,
                   port=3306. The user and password are percent-encoded, so
                   any characters are accepted (newline and NUL aside). Use
                   the RAW password in the MariaDB CREATE USER statement.

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

readline() {
    local var="$1" prompt="${2:-}"
    if ! IFS= read -r -p "${prompt}" "${var}"; then
        echo "Error: unexpected end of input. Aborting." >&2
        exit 1
    fi
}

readsilent() {
    local var="$1" prompt="${2:-}"
    if ! IFS= read -s -r -p "${prompt}" "${var}"; then
        echo "Error: unexpected end of input. Aborting." >&2
        exit 1
    fi
    echo >&2
}

should_write_file() {
    local file="$1" answer

    if [[ -f "${file}" ]] && ((!force)); then
        echo "exists - not created: ${file}"
        readline answer "Recreate? This will DELETE the existing value. (y/N) "
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
        readsilent value "Paste value for ${1}: "
        if [[ -z "${value}" ]]; then
            echo "Empty value. Skipping ${1}." >&2
            return 1
        fi
        printf '%s' "${value}"
        return
    done
}

urlencode_userinfo() {
    local str="$1" out="" c hex old_lc="${LC_ALL-}"
    LC_ALL=C
    while [[ -n "${str}" ]]; do
        c="${str%"${str#?}"}"
        str="${str#?}"
        case "${c}" in
            [A-Za-z0-9._~-]) out+="${c}" ;;
            *) printf -v hex '%02X' "'${c}" ; out+="%${hex}" ;;
        esac
    done
    LC_ALL="${old_lc}"
    printf '%s' "${out}"
}

build_mysql_url() {
    local svc_lower def_user def_db
    local user host port name pass enc_user enc_pass
    svc_lower="$(printf '%s' "${service}" | tr '[:upper:]' '[:lower:]')"
    def_user="${svc_lower}_user"
    def_db="${svc_lower}_db"

    readline user "DB user [${def_user}]: "
    user="${user:-${def_user}}"

    while :; do
        readline host "DB host [mariadb]: "
        host="${host:-mariadb}"
        [[ "${host}" =~ ^[A-Za-z0-9._-]+$ ]] && break
        echo "Invalid DB host: use only letters, digits, dots, dashes and underscores." >&2
    done
    while :; do
        readline port "DB port [3306]: "
        port="${port:-3306}"
        [[ "${port}" =~ ^[0-9]+$ ]] && break
        echo "Invalid DB port: must be numeric." >&2
    done
    while :; do
        readline name "DB name [${def_db}]: "
        name="${name:-${def_db}}"
        [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB name: use only letters, digits, _ . -" >&2
    done
    while :; do
        readsilent pass "DB password: "
        [[ -n "${pass}" ]] && break
        echo "DB password is required." >&2
    done
    enc_user="$(urlencode_userinfo "${user}")"
    enc_pass="$(urlencode_userinfo "${pass}")"
    echo "Note: the password is percent-encoded in the URL. Use the RAW" >&2
    echo "      password in MariaDB (CREATE USER ... IDENTIFIED BY '...')." >&2
    echo "      Escape ' and \\ in the SQL if the password contains them." >&2
    printf 'mysql://%s:%s@%s:%s/%s' "${enc_user}" "${enc_pass}" "${host}" "${port}" "${name}"
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
