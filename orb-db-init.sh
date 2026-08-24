#!/usr/bin/env bash
# orb-db-init.sh — starts a local Postgres cluster inside the orb and creates
# the roles/databases declared in the workspace .env* files (PG_* vars or
# DATABASE_URL). Non-fatal: a failure never prevents the orb from starting.
set -uo pipefail

log() { echo "[orb-db] $*"; }

envget() { # $1=file $2=key -> value without quotes
  awk -F= -v k="$2" '
    $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' "$1"
}

[ -d /workspace/.git ] || exit 0
command -v psql >/dev/null 2>&1 || { log "psql missing — skipping"; exit 0; }
command -v sudo >/dev/null 2>&1 || { log "sudo missing — skipping"; exit 0; }

# ---- collect (host,port,user,password,db) tuples from .env and .env.test
TUPLES_FILE="$(mktemp)"
trap 'rm -f "$TUPLES_FILE"' EXIT

collect() {
  local f="$1"
  [ -f "$f" ] || return 0
  local host="" port="" user="" pass="" db="" url=""
  url="$(envget "$f" DATABASE_URL)"
  case "$url" in
    postgres://*|postgresql://*)
      local rest auth hostport
      rest="${url#*://}"
      auth="${rest%%@*}"
      if [ "$auth" != "$rest" ]; then
        hostport="${rest#*@}"
        user="${auth%%:*}"
        pass="${auth#*:}"
        case "$pass" in *@*) pass="" ;; esac
      else
        hostport="$rest"
      fi
      host="${hostport%%:*}"
      local hp
      hp="${hostport#*:}"
      port="${hp%%/*}"
      case "$port" in *[!0-9]*|"") port="5432" ;; esac
      db="${hp#*/}"
      db="${db%%\?*}"
      ;;
    *)
      host="$(envget "$f" PG_HOST)"
      [ -z "$host" ] && host="$(envget "$f" DB_HOST)"
      [ -z "$host" ] && return 0
      user="$(envget "$f" PG_USER)";  [ -z "$user" ] && user="$(envget "$f" DB_USER)"
      pass="$(envget "$f" PG_PASSWORD)"; [ -z "$pass" ] && pass="$(envget "$f" DB_PASSWORD)"
      db="$(envget "$f" PG_DB_NAME)"; [ -z "$db" ] && db="$(envget "$f" DB_DATABASE)"
      port="$(envget "$f" PG_PORT)"; [ -z "$port" ] && port="$(envget "$f" DB_PORT)"
      case "$port" in *[!0-9]*|"") port="5432" ;; esac
      ;;
  esac
  [ -n "$db" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "$user" "$pass" "$db" >> "$TUPLES_FILE"
}

collect /workspace/.env
collect /workspace/.env.test
[ -s "$TUPLES_FILE" ] || { log "no postgres database declared — skipping"; exit 0; }

# ---- filtering: only local hosts get provisioned
LOCAL_ONLY="$(mktemp)"
while IFS=$'\t' read -r h p u pw d; do
  case "$h" in
    127.0.0.1|localhost|::1) printf '%s\t%s\t%s\t%s\t%s\n' "$h" "$p" "$u" "$pw" "$d" >> "$LOCAL_ONLY" ;;
    *) log "non-local host '$h' (database '$d') — ignored" ;;
  esac
done < "$TUPLES_FILE"

if [ ! -s "$LOCAL_ONLY" ]; then
  log "no local database to provision"
  rm -f "$TUPLES_FILE" "$LOCAL_ONLY"
  trap - EXIT
  exit 0
fi
mv "$LOCAL_ONLY" "$TUPLES_FILE"

# ---- cluster port: only one distinct port is supported (the first one)
PORT="$(awk -F'\t' '{print $2; exit}' "$TUPLES_FILE")"
PG_MAJOR="$(ls /etc/postgresql 2>/dev/null | head -1)"
[ -n "$PG_MAJOR" ] || { log "postgres cluster not found — skipping"; exit 0; }

if [ "$PORT" != "5432" ]; then
  sed -i -E "s/^#?[[:space:]]*port[[:space:]]*=.*$/port = ${PORT}/" \
    "/etc/postgresql/${PG_MAJOR}/main/postgresql.conf" 2>/dev/null
fi

if ! pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
  log "starting postgres ${PG_MAJOR} cluster (port ${PORT})..."
  pg_ctlcluster "${PG_MAJOR}" main start >/dev/null 2>&1 \
    || service postgresql start >/dev/null 2>&1 || true
  ready_try=0
  until pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; do
    ready_try=$((ready_try + 1))
    [ "$ready_try" -ge 30 ] && { log "FAILURE: cluster not ready — databases not created"; exit 0; }
    sleep 1
  done
fi

psql_admin() {
  sudo -u postgres psql -p "$PORT" -v ON_ERROR_STOP=1 -qAt "$@"
}

# SQL literal quoting (doubles single quotes) and identifier quoting (doubles ")
lit() { local s="$1"; s="${s//\'/\'\'}"; printf "'%s'" "$s"; }
ident() { local s="$1"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }

ensure_role() { # $1=user $2=password
  local u="$1" pw="$2"
  [ -n "$u" ] || u="postgres"
  local exists
  exists="$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname=$(lit "$u");")"
  if [ "$exists" != "1" ]; then
    if psql_admin -c "CREATE ROLE $(ident "$u") LOGIN PASSWORD $(lit "${pw:-}");" >/dev/null; then
      log "role created: ${u}"
    else
      log "FAILED to create role ${u}"
      return 1
    fi
  elif [ -n "$pw" ]; then
    psql_admin -c "ALTER ROLE $(ident "$u") WITH LOGIN PASSWORD $(lit "$pw");" >/dev/null || true
  fi
}

ensure_db() { # $1=db $2=owner
  local d="$1" o="${2:-postgres}"
  local exists
  exists="$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname=$(lit "$d");")"
  if [ "$exists" = "1" ]; then
    log "database already present: ${d}"
    return 0
  fi
  sudo -u postgres createdb -p "$PORT" -O "$o" "$d" >/dev/null 2>&1 \
    && log "database created: ${d} (owner ${o})" \
    || log "FAILED to create database ${d}"
}

# dedupe by database name, create role then database
SEEN="$(mktemp)"
while IFS=$'\t' read -r _ _ u pw d; do
  grep -qx "$d" "$SEEN" 2>/dev/null && continue
  echo "$d" >> "$SEEN"
  if ensure_role "$u" "$pw"; then
    ensure_db "$d" "${u:-postgres}"
  fi
done < "$TUPLES_FILE"
rm -f "$SEEN"

log "postgres ready on 127.0.0.1:${PORT}"
exit 0
