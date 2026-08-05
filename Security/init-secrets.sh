#!/usr/bin/env bash
#
# init-secrets.sh
#
# Creates Docker compose "secret" files under $PATH_TO_SECRETS/<Service>/.
#
# A secret file is a plain text file whose entire content IS the value.
# Compose mounts it into the container at /run/secrets/<name>, and services
# that support the *_FILE convention read the value from the file. This keeps
# secrets out of the environment, so they never leak through `docker inspect`
# or /proc/<pid>/environ.
#
# Only the value is stored in the file: no trailing newline (a newline would
# become part of the value and break consumers that expect the raw string).
#
set -euo pipefail

# usage ----------------------------------------------------------------------
# Prints the help text and exits. Called on --help and on invalid invocation.
usage() {
    cat <<'EOF'
Usage: ./init-secrets.sh [--force] <Service> <secret1> [secret2 ...]

Creates Docker compose secret files at $PATH_TO_SECRETS/<Service>/.
A secret file is a plain text file whose content IS the value.

Secret types:
  <name>           Plain value. You paste it (read silently, asked twice).
  <name>@mysql     MySQL connection URL, built for you. Prompts for user,
                   host, port, database and password, then writes
                   "mysql://user:pass@host:port/db". Defaults derive from the
                   service name: <service>_user, <service>_db, host=mariadb,
                   port=3306. The user and password are percent-encoded, so
                   any characters are accepted (newline and NUL aside). Use
                   the RAW password in the MariaDB statements.
  <name>@db        Raw database password, stored as-is in the file <name>
                   (the value your compose *_FILE variable reads). Prompts
                   for database, user, grants and password (twice). Defaults:
                   <service>_db, <service>_user, ALL PRIVILEGES.

After writing an @mysql or @db secret the script asks whether to create/update
the database and user in MariaDB (y/N, default No). Answering y runs
Database/sync-db-users.sh, which applies the password with
RETAIN CURRENT PASSWORD (dual password): the old and the new password both
work, so the running service is never locked out. After recreating the
container and verifying the app, revoke the old password with:
  Database/sync-db-users.sh --discard-old <Service> <secret_name>

Options:
  --force   Recreate existing secrets without asking (deletes old value).
  -h, --help   Show this help.

Environment:
  PATH_TO_SECRETS  Base directory for secret files. Resolved in this order:
                   1. an already-set environment variable
                   2. ../global.env (repo root, git-ignored) if present
                   3. ~/.secrets (fallback)

Behavior:
  - Secret values are read silently, asked TWICE and compared (3 attempts,
    then the script aborts). They are NEVER printed.
  - Files are written WITHOUT a trailing newline, with mode 600.
  - The service directory is created with mode 700.
  - Existing secrets are skipped after asking "Recreate?" (unless --force).

Examples:
  ./init-secrets.sh Vaultwarden admin_token db_url@mysql domain
  ./init-secrets.sh NginxProxyManager db_mysql_password@db
  ./init-secrets.sh --force Vaultwarden admin_token
EOF
    exit 1
}

# Parse command line ---------------------------------------------------------
# Supports an optional --force flag (in any position), --help, and a literal
# `--` separator. Everything else is collected as positional arguments:
# the first is the service name, the rest are secret targets.
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

# A service name and at least one secret are required.
if ((${#args[@]} < 2)); then
    usage
fi

service="${args[0]}"
secrets=("${args[@]:1}")

# Resolve PATH_TO_SECRETS ----------------------------------------------------
# 1. If already exported, use it.
# 2. Otherwise source ../global.env (repo root, git-ignored) if present.
# 3. Otherwise fall back to ~/.secrets and warn.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sync_script="${script_dir}/../Database/sync-db-users.sh"

if [[ -z "${PATH_TO_SECRETS:-}" ]]; then
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

# Create the base and service directories and lock them down. Directories are
# 700 so that nothing outside the user can read the secret files inside.
secret_dir="${PATH_TO_SECRETS}/${service}"
mkdir -p "${PATH_TO_SECRETS}" "${secret_dir}"
chmod 700 "${PATH_TO_SECRETS}" "${secret_dir}"

# readline -------------------------------------------------------------------
# Reads one line from stdin into the variable named by $1 (optional prompt in
# $2). `IFS=` preserves leading/trailing whitespace and `-r` disables
# backslash processing, so pasted values arrive byte-for-byte intact.
# Aborts with exit 1 on EOF instead of looping forever.
readline() {
    local var="$1" prompt="${2:-}"
    if ! IFS= read -r -p "${prompt}" "${var}"; then
        echo "Error: unexpected end of input. Aborting." >&2
        exit 1
    fi
}

# readsilent -----------------------------------------------------------------
# Same as readline but with echo disabled (-s): used for passwords and other
# secret values. Also aborts cleanly on EOF.
readsilent() {
    local var="$1" prompt="${2:-}"
    if ! IFS= read -s -r -p "${prompt}" "${var}"; then
        echo "Error: unexpected end of input. Aborting." >&2
        exit 1
    fi
    echo >&2
}

# should_write_file ----------------------------------------------------------
# Decides whether a target file may be written. If the file already exists and
# --force was not given, asks "Recreate?"; answering anything but y/Y keeps the
# existing value. Returns 0 when writing is allowed, 1 when it should be kept.
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

# write_value ----------------------------------------------------------------
# Writes the value to the file WITHOUT a trailing newline and chmods it 600.
write_value() {
    local file="$1" value="$2"

    printf '%s' "${value}" > "${file}"
    chmod 600 "${file}"
    echo "Written: ${file}"
}

# read_password_confirm ------------------------------------------------------
# Reads a secret value twice and requires both reads to match, so a typo in a
# pasted value cannot silently corrupt a secret. Retries up to 3 attempts and
# ABORTS the whole script on a persistent mismatch (it is always called in the
# main shell, never in a subshell, so `exit 1` reaches the caller). A non-empty
# value is required. Stores the value in the variable named by $1.
read_password_confirm() {
    local var="$1" prompt="${2:-Password: }" pw1 pw2 attempt=0
    while :; do
        readsilent pw1 "${prompt}"
        if [[ -z "${pw1}" ]]; then
            echo "A value is required." >&2
            attempt=$((attempt + 1))
            if ((attempt >= 3)); then
                echo "Error: no value given after 3 attempts. Aborting." >&2
                exit 1
            fi
            continue
        fi
        readsilent pw2 "Confirm: "
        if [[ "${pw1}" == "${pw2}" ]]; then
            printf -v "${var}" '%s' "${pw1}"
            return 0
        fi
        attempt=$((attempt + 1))
        if ((attempt >= 3)); then
            echo "Error: values did not match after 3 attempts. Aborting." >&2
            exit 1
        fi
        echo "Values do not match. Try again." >&2
    done
}

# prompt_secret --------------------------------------------------------------
# Reads a plain secret value silently, confirming it twice, and stores it in
# the global PROMPT_VALUE.
prompt_secret() {
    read_password_confirm PROMPT_VALUE "Paste value for ${1}: "
}

# urlencode_userinfo ---------------------------------------------------------
# Percent-encodes a string for use in the userinfo part of a URL
# (the "user:password@" segment). Keeps RFC 3986 unreserved characters
# (A-Z a-z 0-9 - . _ ~) as-is and encodes everything else as %XX, byte by
# byte under LC_ALL=C so multi-byte UTF-8 stays correct. '%' is always encoded
# so that a literal '%XX' sequence in the value cannot be misinterpreted.
# Diesel (Vaultwarden's driver) percent-decodes userinfo back to the original.
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

# build_mysql_url ------------------------------------------------------------
# Interactively builds a MySQL connection URL in the form
# "mysql://user:pass@host:port/db". Defaults derive from the service name:
# <service>_user, <service>_db, host=mariadb, port=3306. The user and password
# are percent-encoded so that any characters work; host, port and database
# name are validated because they sit in parts of the URL that are not decoded.
# The password is the only required input (no default).
# Sets MYSQL_URL (the URL) and MYSQL_URL_USER/DB/PASS (the raw spec, so the
# caller can offer to create/update the database and user in MariaDB).
build_mysql_url() {
    local svc_lower def_user def_db
    local user host port name enc_user enc_pass
    svc_lower="$(printf '%s' "${service}" | tr '[:upper:]' '[:lower:]')"
    def_user="${svc_lower}_user"
    def_db="${svc_lower}_db"

    readline user "DB user [${def_user}]: "
    user="${user:-${def_user}}"

    # Host: allow DNS names, IPv4, and Docker service names (may contain _).
    while :; do
        readline host "DB host [mariadb]: "
        host="${host:-mariadb}"
        [[ "${host}" =~ ^[A-Za-z0-9._-]+$ ]] && break
        echo "Invalid DB host: use only letters, digits, dots, dashes and underscores." >&2
    done
    # Port: numeric only.
    while :; do
        readline port "DB port [3306]: "
        port="${port:-3306}"
        [[ "${port}" =~ ^[0-9]+$ ]] && break
        echo "Invalid DB port: must be numeric." >&2
    done
    # Database name: part of the URL path, which Diesel does NOT decode.
    while :; do
        readline name "DB name [${def_db}]: "
        name="${name:-${def_db}}"
        [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB name: use only letters, digits, _ . -" >&2
    done
    # Password: required, no default, any characters allowed, confirmed twice.
    read_password_confirm MYSQL_URL_PASS "DB password: "

    # Remember what was chosen so the caller can offer to create/update the
    # database and user in MariaDB via sync-db-users.sh.
    MYSQL_URL_USER="${user}"
    MYSQL_URL_DB="${name}"

    enc_user="$(urlencode_userinfo "${user}")"
    enc_pass="$(urlencode_userinfo "${MYSQL_URL_PASS}")"
    echo "Note: the password is percent-encoded in the URL. Use the RAW" >&2
    echo "      password in MariaDB (CREATE USER ... IDENTIFIED BY '...')." >&2
    echo "      Escape ' and \\ in the SQL if the password contains them." >&2
    MYSQL_URL="mysql://${enc_user}:${enc_pass}@${host}:${port}/${name}"
}

# prompt_db_spec -------------------------------------------------------------
# Prompts for the database, user, grants and password of a `<name>@db` secret.
# Defaults derive from the service name: <service>_db, <service>_user and
# ALL PRIVILEGES. Sets DB_SPEC_DB, DB_SPEC_USER, DB_SPEC_GRANTS and
# DB_SPEC_PASS.
prompt_db_spec() {
    local svc_lower def_user def_db
    svc_lower="$(printf '%s' "${service}" | tr '[:upper:]' '[:lower:]')"
    def_user="${svc_lower}_user"
    def_db="${svc_lower}_db"

    while :; do
        readline DB_SPEC_DB "DB name [${def_db}]: "
        DB_SPEC_DB="${DB_SPEC_DB:-${def_db}}"
        [[ "${DB_SPEC_DB}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB name: use only letters, digits, _ . -" >&2
    done
    while :; do
        readline DB_SPEC_USER "DB user [${def_user}]: "
        DB_SPEC_USER="${DB_SPEC_USER:-${def_user}}"
        [[ "${DB_SPEC_USER}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB user: use only letters, digits, _ . -" >&2
    done
    readline DB_SPEC_GRANTS "Grants [ALL PRIVILEGES]: "
    DB_SPEC_GRANTS="${DB_SPEC_GRANTS:-ALL PRIVILEGES}"
    read_password_confirm DB_SPEC_PASS "DB password: "
}

# ask_sync_db ----------------------------------------------------------------
# After writing a database-backed secret, offers to create/update the database
# and user in MariaDB through Database/sync-db-users.sh (default: No, so this
# never runs without an explicit yes). When raw_pass is non-empty (the @mysql
# case, where the secret file holds a URL, not the password) it is forwarded
# through SECRET_PASSWORD so the sync script never sees it on the command line.
ask_sync_db() {
    local secret_name="$1" db="$2" user="$3" raw_pass="${4:-}" grants="${5:-ALL PRIVILEGES}"
    local answer
    readline answer "Create/update database '${db}' and user '${user}' in MariaDB? (y/N) "
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
        echo "Skipped. If needed later:"
        echo "  ${sync_script} ${service} ${secret_name} ${db} ${user} \"${grants}\""
        return 0
    fi
    if [[ ! -x "${sync_script}" ]]; then
        echo "Error: sync script not found: ${sync_script}" >&2
        return 1
    fi
    echo "Running: ${sync_script} ${service} ${secret_name} ${db} ${user}"
    if [[ -n "${raw_pass}" ]]; then
        SECRET_PASSWORD="${raw_pass}" "${sync_script}" "${service}" "${secret_name}" "${db}" "${user}" "${grants}"
    else
        "${sync_script}" "${service}" "${secret_name}" "${db}" "${user}" "${grants}"
    fi
}

# Main loop ------------------------------------------------------------------
# For each secret target:
#   * name@mysql   -> build a MySQL URL, write it to the file `<name>`, and
#                     offer to create/update the database and user in MariaDB.
#   * name@db      -> prompt for the DB spec, write the raw password to the
#                     file `<name>`, and offer to sync it to MariaDB.
#   * name         -> read a plain value and write it to the file `<name>`.
# `unset value` discards the captured secret from the shell as soon as it has
# been written, so it does not linger in the script's memory.
for secret in "${secrets[@]}"; do
    if [[ "${secret}" == *@mysql ]]; then
        name="${secret%@mysql}"
        file="${secret_dir}/${name}"
        if should_write_file "${file}"; then
            build_mysql_url
            value="${MYSQL_URL}"
            write_value "${file}" "${value}"
            unset value
            ask_sync_db "${name}" "${MYSQL_URL_DB}" "${MYSQL_URL_USER}" "${MYSQL_URL_PASS}"
        fi
    elif [[ "${secret}" == *@db ]]; then
        name="${secret%@db}"
        file="${secret_dir}/${name}"
        if should_write_file "${file}"; then
            prompt_db_spec
            value="${DB_SPEC_PASS}"
            write_value "${file}" "${value}"
            unset value DB_SPEC_PASS
            ask_sync_db "${name}" "${DB_SPEC_DB}" "${DB_SPEC_USER}" "" "${DB_SPEC_GRANTS}"
        fi
    else
        file="${secret_dir}/${secret}"
        if should_write_file "${file}"; then
            if prompt_secret "${secret}"; then
                value="${PROMPT_VALUE}"
                write_value "${file}" "${value}"
                unset value PROMPT_VALUE
            fi
        fi
    fi
done
