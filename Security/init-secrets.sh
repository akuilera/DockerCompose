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
Usage: ./init-secrets.sh [options] <Service> <secret1> [secret2 ...]
       ./init-secrets.sh --update-database <Service>

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
  @db              Full DB credential set for the service. Prompts for DB
                   name (default <service>_db), DB user (default
                   <service>_user) and DB password (twice), then writes
                   db_mysql_name, db_mysql_user, db_mysql_password and
                   db_mysql_url in $PATH_TO_SECRETS/<Service>/. The raw
                   password is the value of db_mysql_password (what a compose
                   *_FILE variable reads); db_mysql_url is generated for
                   services that consume a connection URL.

Options:
  --force              Recreate existing secrets without asking (deletes old value).
  --update-database    Apply the DB credentials stored by @db to MariaDB,
                       running Database/sync-db-users.sh. Reads db_mysql_name,
                       db_mysql_user and db_mysql_password; grants: ALL
                       PRIVILEGES. Combine with --dry-run to only print the
                       SQL that would be executed.
  --dry-run            With --update-database: print what would be done, do
                       not execute.
  -h, --help           Show this help.

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
  ./init-secrets.sh NginxProxyManager @db
  ./init-secrets.sh --force Vaultwarden admin_token
  ./init-secrets.sh --update-database --dry-run NginxProxyManager
EOF
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

# Parse command line ---------------------------------------------------------
# Supports --force, --update-database and --dry-run flags (in any position),
# --help, and a literal `--` separator. Everything else is collected as
# positional arguments: the first is the service name, the rest are secret
# targets (or, with --update-database, there is exactly one service name).
force=0
update_db=0
dry_run=0
args=()
while (($#)); do
    case "$1" in
        --force) force=1 ;;
        --update-database) update_db=1 ;;
        --dry-run) dry_run=1 ;;
        -h | --help) usage ;;
        --) shift && args+=("$@") && break ;;
        -*) echo "Unknown option: $1" >&2 && usage ;;
        *) args+=("$1") ;;
    esac
    shift
done

if ((update_db)); then
    ((${#args[@]} == 1)) || die "--update-database takes exactly one argument: <Service>"
    service="${args[0]}"
else
    # A service name and at least one secret are required.
    ((${#args[@]} >= 2)) || usage
    service="${args[0]}"
    secrets=("${args[@]:1}")
fi

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

# update_database ------------------------------------------------------------
# --update-database mode: read the db_mysql_* files written by @db and apply
# them to MariaDB through Database/sync-db-users.sh. No prompts, no password
# on the command line (sync-db-users.sh reads the secret file itself).
update_database() {
    local svc="$1"
    local dir="${PATH_TO_SECRETS}/${svc}"
    local name_file="${dir}/db_mysql_name"
    local user_file="${dir}/db_mysql_user"
    local pass_file="${dir}/db_mysql_password"

    [[ -f "${name_file}" ]] || die "Not found: ${name_file}. Run: ./init-secrets.sh ${svc} @db"
    [[ -f "${user_file}" ]] || die "Not found: ${user_file}. Run: ./init-secrets.sh ${svc} @db"
    [[ -f "${pass_file}" ]] || die "Not found: ${pass_file}. Run: ./init-secrets.sh ${svc} @db"
    [[ -x "${sync_script}" ]] || die "sync script not found: ${sync_script}"

    local db user
    db="$(cat "${name_file}")"
    user="$(cat "${user_file}")"
    [[ -n "${db}" ]] || die "Empty value in ${name_file}"
    [[ -n "${user}" ]] || die "Empty value in ${user_file}"

    echo "Applying DB user '${user}' on database '${db}' (grants: ALL PRIVILEGES)..."
    if ((dry_run)); then
        "${sync_script}" --dry-run "${svc}" db_mysql_password "${db}" "${user}" "ALL PRIVILEGES"
    else
        "${sync_script}" "${svc}" db_mysql_password "${db}" "${user}" "ALL PRIVILEGES"
    fi
}

if ((update_db)); then
    update_database "${service}"
    exit 0
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
# Sets MYSQL_URL (the URL) and MYSQL_URL_USER/DB/PASS (the raw spec).
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

    MYSQL_URL_USER="${user}"
    MYSQL_URL_DB="${name}"

    enc_user="$(urlencode_userinfo "${user}")"
    enc_pass="$(urlencode_userinfo "${MYSQL_URL_PASS}")"
    echo "Note: the password is percent-encoded in the URL. Use the RAW" >&2
    echo "      password in MariaDB (CREATE USER ... IDENTIFIED BY '...')." >&2
    echo "      Escape ' and \\ in the SQL if the password contains them." >&2
    MYSQL_URL="mysql://${enc_user}:${enc_pass}@${host}:${port}/${name}"
}

# write_db_set ---------------------------------------------------------------
# Prompts for the DB name (default <service>_db), DB user (default
# <service>_user) and DB password (twice), then writes the four db_mysql_*
# files in the service's secret directory. If any of them already exists and
# --force was not given, asks once whether to recreate all of them. After
# writing, prints how to apply the user to MariaDB later.
write_db_set() {
    local svc_lower def_user def_db db user enc_user enc_pass url
    local files=(db_mysql_name db_mysql_user db_mysql_password db_mysql_url)
    local answer existing=0 f

    svc_lower="$(printf '%s' "${service}" | tr '[:upper:]' '[:lower:]')"
    def_user="${svc_lower}_user"
    def_db="${svc_lower}_db"

    while :; do
        readline db "DB name [${def_db}]: "
        db="${db:-${def_db}}"
        [[ "${db}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB name: use only letters, digits, _ . -" >&2
    done
    while :; do
        readline user "DB user [${def_user}]: "
        user="${user:-${def_user}}"
        [[ "${user}" =~ ^[A-Za-z0-9_.-]+$ ]] && break
        echo "Invalid DB user: use only letters, digits, _ . -" >&2
    done
    read_password_confirm DB_SET_PASS "DB password: "

    for f in "${files[@]}"; do
        [[ -f "${secret_dir}/${f}" ]] && existing=1 && break
    done
    if ((existing)) && ((!force)); then
        readline answer "Database secret files exist in ${secret_dir} - recreate all? (y/N) "
        if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
            echo "Keeping existing files."
            unset DB_SET_PASS
            return 0
        fi
    fi

    write_value "${secret_dir}/db_mysql_name" "${db}"
    write_value "${secret_dir}/db_mysql_user" "${user}"
    write_value "${secret_dir}/db_mysql_password" "${DB_SET_PASS}"
    enc_user="$(urlencode_userinfo "${user}")"
    enc_pass="$(urlencode_userinfo "${DB_SET_PASS}")"
    url="mysql://${enc_user}:${enc_pass}@mariadb:3306/${db}"
    write_value "${secret_dir}/db_mysql_url" "${url}"
    unset DB_SET_PASS

    echo ""
    echo "If needed later, apply the DB user with:"
    echo "  ./Security/init-secrets.sh --update-database ${service}"
}

# Main loop ------------------------------------------------------------------
# For each secret target:
#   * name@mysql   -> build a MySQL URL, write it to the file `<name>`.
#   * @db          -> prompt for DB name/user/password, write the db_mysql_*
#                     file set.
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
            unset value MYSQL_URL MYSQL_URL_PASS
        fi
    elif [[ "${secret}" == *@db ]]; then
        write_db_set
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
