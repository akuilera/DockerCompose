#!/usr/bin/env bash
#
# sync-db.sh
#
# Applies (or rotates) a MariaDB user's password for a homelab service, using
# the value already stored in the service's Docker secret file. The script is
# purely additive and idempotent: it only ever runs CREATE DATABASE IF NOT
# EXISTS, CREATE USER IF NOT EXISTS, ALTER USER, GRANT and FLUSH PRIVILEGES.
# It NEVER drops databases, users or grants.
#
# Primary use case - password rotation (user already exists):
#   ALTER USER 'app'@'%' IDENTIFIED BY '<new>';
# MariaDB (unlike MySQL 8) has no dual-password: the OLD password stops
# working the moment this runs, so first move the service to the new secret
# file value, apply, then recreate the container and verify the app.
#
# Passwords are read from files or from the docker CLI environment, never from
# the command line (so they do not show up in `ps` or in shell history).
#
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./sync-db.sh [options] <Service> <secret_name> [<db> <user> [<grants>]]

Applies (or rotates) the MariaDB user for a service, using the password stored
in $PATH_TO_SECRETS/<Service>/<secret_name>.

Rotate the password of an existing user:
  ALTER USER ... IDENTIFIED BY '<new>';
MariaDB has no dual-password, so the change is immediate. Keep the rotation
short: apply, recreate the container, verify the app.

Options:
  --db <name>            Database name.        Default: <service>_db.
  --user <name[@host]>   User (and optional host). Default: <service>_user.
  --host <host>          User host (used when --user has no @host). Default: %.
  --grants "<grants>"    Grant to apply on <db>.* Default: ALL PRIVILEGES.
  --password-file <f>    Read the password from <f> instead of the secret file.
  --dry-run              Print the SQL that would be executed; do nothing.
  -v, --verbose          Print the SQL as it is executed.
  -h, --help             Show this help.

Environment:
  PATH_TO_SECRETS              Base directory for secret files (same resolution
                               order as init-secrets.sh).
  MARIADB_CONTAINER            Container name (default: mariadb).
  DOCKER_CMD                   Docker command (default: docker or sudo docker).
  MARIADB_ROOT_PASSWORD_FILE   Root password file override
                               (default: $PATH_TO_SECRETS/MariaDB/mysql_root_password).
  SECRET_PASSWORD              Inline raw password (used by init-secrets.sh
                               for the @mysql/@db secret types).

Safety:
  - Never drops anything: only CREATE ... IF NOT EXISTS / ALTER / GRANT.
  - Passwords travel via stdin into `docker exec` (value never on the
    command line or environment, so `sudo` cannot strip it).
  - Re-running is safe (idempotent).
EOF
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

# ---- parse arguments ---------------------------------------------------------
dry_run=0
verbose=0
db=""
user_arg=""
host_arg=""
grants=""
password_file=""
positional=()
while (($#)); do
    case "$1" in
        --db) shift; db="${1:-}" ;;
        --user) shift; user_arg="${1:-}" ;;
        --host) shift; host_arg="${1:-}" ;;
        --grants) shift; grants="${1:-}" ;;
        --password-file) shift; password_file="${1:-}" ;;
        --dry-run) dry_run=1 ;;
        -v | --verbose) verbose=1 ;;
        -h | --help) usage ;;
        -*) die "Unknown option: $1" ;;
        *) positional+=("$1") ;;
    esac
    shift
done

((${#positional[@]} >= 2)) || usage
service="${positional[0]}"
secret_name="${positional[1]}"
((${#positional[@]} >= 3)) && db="${positional[2]}"
((${#positional[@]} >= 4)) && user_arg="${positional[3]}"
((${#positional[@]} >= 5)) && grants="${positional[4]}"

# ---- resolve PATH_TO_SECRETS (same order as init-secrets.sh) -----------------
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

# ---- derive identifiers and defaults ------------------------------------------
svc_lower="$(printf '%s' "${service}" | tr '[:upper:]' '[:lower:]')"
db="${db:-${svc_lower}_db}"
grants="${grants:-ALL PRIVILEGES}"

# Split an optional @host out of the user argument.
user="${user_arg%@*}"
if [[ "${user_arg}" == *@* ]]; then
    host="${user_arg#*@}"
else
    host="${host_arg:-%}"
fi
host="${host:-%}"

ident_re='^[A-Za-z0-9_.-]+$'
host_re='^[A-Za-z0-9_.%-]+$'
grants_re='^[A-Za-z0-9_ ,*()]+$'
[[ "${db}" =~ $ident_re ]] || die "Invalid database name: '${db}'"
[[ "${user}" =~ $ident_re ]] || die "Invalid user name: '${user}'"
[[ "${host}" =~ $host_re ]] || die "Invalid host: '${host}'"
[[ "${grants}" =~ $grants_re ]] || die "Invalid grants: '${grants}'"

# ---- password resolution ------------------------------------------------------
if [[ -n "${SECRET_PASSWORD:-}" ]]; then
    password="${SECRET_PASSWORD}"
elif [[ -n "${password_file}" ]]; then
    [[ -f "${password_file}" ]] || die "Password file not found: ${password_file}"
    password="$(cat "${password_file}")"
else
    secret_file="${PATH_TO_SECRETS}/${service}/${secret_name}"
    [[ -f "${secret_file}" ]] || die "Secret file not found: ${secret_file}. Run: ./init-secrets.sh ${service} ${secret_name}"
    password="$(cat "${secret_file}")"
    [[ -n "${password}" ]] || die "Secret file is empty: ${secret_file}"
fi

# ---- docker command detection ---------------------------------------------------
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
if [[ -z "${DOCKER_CMD:-}" ]]; then
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    elif sudo -n docker info >/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        DOCKER_CMD="sudo docker"
    fi
fi

# ---- helpers --------------------------------------------------------------------
# Escape a value for use inside a single-quoted SQL string.
escape_sql() {
    local s="$1" q="'"
    s="${s//\\/\\\\}"
    s="${s//$q/$q$q}"
    printf '%s' "${s}"
}

# Detect how we can reach MariaDB as root.
#   socket : `docker exec` root over the local socket (no password needed).
#   file   : password from the MariaDB root secret file (passed via stdin).
#   none   : no access (only acceptable in --dry-run).
ROOT_MODE="none"
ROOT_PW=""
detect_root() {
    if printf '%s\n' "SELECT 1" | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" mariadb -uroot >/dev/null 2>&1; then
        ROOT_MODE="socket"
        return 0
    fi
    local root_file="${MARIADB_ROOT_PASSWORD_FILE:-${PATH_TO_SECRETS}/MariaDB/mysql_root_password}"
    if [[ -f "${root_file}" ]]; then
        ROOT_PW="$(cat "${root_file}")"
        ROOT_MODE="file"
        return 0
    fi
    ROOT_MODE="none"
    return 1
}

# Run an SQL script as root through the container's mariadb client.
run_root_sql() {
    local sql="$1"
    if [[ "${dry_run}" == "1" ]]; then
        printf '%s\n' "${sql_print:-${sql}}"
        return 0
    fi
    case "${ROOT_MODE}" in
        socket)
            printf '%s\n' "${sql}" | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" mariadb -uroot
            ;;
        file)
            { printf '%s\n' "${ROOT_PW}"; printf '%s\n' "${sql}"; } | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" bash -c 'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -uroot'
            ;;
        *)
            die "No root access to MariaDB (no socket auth and no ${PATH_TO_SECRETS}/MariaDB/mysql_root_password). Run: ./init-secrets.sh MariaDB mysql_root_password"
            ;;
    esac
}

# Returns 0 when the user@host exists in mysql.user (1 otherwise). When no root
# access is available (dry-run only) it assumes the user exists.
user_exists() {
    local count=""
    case "${ROOT_MODE}" in
        socket)
            count="$(printf '%s\n' "SELECT COUNT(*) FROM mysql.user WHERE User='${user}' AND Host='${host}';" | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" mariadb -uroot -N -B)"
            ;;
        file)
            count="$(printf '%s\n' "${ROOT_PW}" "SELECT COUNT(*) FROM mysql.user WHERE User='${user}' AND Host='${host}';" | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" bash -c 'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -uroot -N -B')"
            ;;
        *) return 0 ;;
    esac
    [[ "${count}" != "0" ]]
}

# ---- connect --------------------------------------------------------------------
detect_root || true
if [[ "${ROOT_MODE}" == "none" && "${dry_run}" != "1" ]]; then
    die "No root access to MariaDB. Run: ./init-secrets.sh MariaDB mysql_root_password"
fi

exists=1
if [[ "${ROOT_MODE}" != "none" ]]; then
    if user_exists; then
        exists=1
    else
        exists=0
    fi
fi

# ---- build SQL --------------------------------------------------------------------
pw_sql="$(escape_sql "${password}")"
sql="CREATE DATABASE IF NOT EXISTS \`${db}\`;"
if ((exists == 1)); then
    sql+=" ALTER USER '${user}'@'${host}' IDENTIFIED BY '${pw_sql}';"
else
    sql+=" CREATE USER IF NOT EXISTS '${user}'@'${host}' IDENTIFIED BY '${pw_sql}';"
fi
sql+=" GRANT ${grants} ON \`${db}\`.* TO '${user}'@'${host}';"
sql+=" FLUSH PRIVILEGES;"

if ((dry_run)) || ((verbose)); then
    sql_print="${sql}"
    if [[ -n "${pw_sql}" ]]; then
        sql_print="${sql//"${pw_sql}"/"${pw_sql//?/*}"}"
    fi
fi

if [[ "${dry_run}" == "1" ]]; then
    printf '%s\n' "${sql_print}"
    echo "# dry-run: nothing was executed"
    exit 0
fi

if [[ "${verbose}" == "1" ]]; then
    printf '%s\n' "${sql_print}"
fi

run_root_sql "${sql}"

# ---- verify the new password actually works ---------------------------------------
if printf '%s\n' "${password}" | $DOCKER_CMD exec -i "${MARIADB_CONTAINER}" bash -c 'IFS= read -r pw; MYSQL_PWD="$pw" mariadb -u"$1" -h127.0.0.1 -e "SELECT 1"' bash "${user}" >/dev/null 2>&1; then
    echo "OK: '${user}'@'${host}' logs in with the new password."
else
    echo "WARNING: login with the new password failed for '${user}'@'${host}'." >&2
    echo "  - The container still holds the OLD password; verify it matches the secret file." >&2
    echo "  - If the user was just created, the host may not match mysql.user." >&2
    exit 1
fi

cat <<EOF

Rotation applied for '${user}'@'${host}' (database '${db}').
The OLD password no longer works from this point on.
1) Recreate the container so it reads the new secret:
     $DOCKER_CMD compose up -d --force-recreate   (or Update in Portainer)
2) Verify the application works with the new value.
EOF
