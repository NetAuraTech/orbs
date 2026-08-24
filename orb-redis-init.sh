#!/usr/bin/env bash
# orb-redis-init.sh — starts Redis inside the orb if a .env* file declares a
# local host. Port/password taken from REDIS_* vars (or REDIS_URL). Non-fatal.
set -uo pipefail

log() { echo "[orb-redis] $*"; }

envget() {
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
command -v redis-server >/dev/null 2>&1 || { log "redis missing — skipping"; exit 0; }

HOST="" ; PORT="" ; PASS=""
found=0
for f in /workspace/.env /workspace/.env.test; do
  [ -f "$f" ] || continue
  h="$(envget "$f" REDIS_HOST)"
  [ -z "$h" ] && continue
  found=1
  case "$h" in
    127.0.0.1|localhost|::1) ;;
    *) log "non-local host '$h' — ignored (${f})"; continue ;;
  esac
  HOST="$h"
  p="$(envget "$f" REDIS_PORT)"; case "$p" in *[!0-9]*|"") p="6379" ;; esac
  PORT="$p"
  pw="$(envget "$f" REDIS_PASSWORD)"; [ -n "$pw" ] && PASS="$pw"
  break
done

if [ "$found" -eq 0 ]; then
  # REDIS_URL variant (redis://[:pass@]host:port)
  for f in /workspace/.env /workspace/.env.test; do
    [ -f "$f" ] || continue
    url="$(envget "$f" REDIS_URL)"
    case "$url" in
      redis://*)
        rest="${url#redis://}"
        auth="${rest%%@*}"
        hp="$rest"
        if [ "$auth" != "$rest" ]; then
          hp="${rest#*@}"
          PASS="${auth#:}"
          case "$PASS" in *@*) PASS="" ;; esac
        fi
        h="${hp%%:*}"
        case "$h" in
          127.0.0.1|localhost|::1)
            HOST="$h"
            p="${hp#*:}"; p="${p%%/*}"
            case "$p" in *[!0-9]*|"") p="6379" ;; esac
            PORT="$p"
            found=1
            ;;
          *) log "non-local host '$h' (REDIS_URL) — ignored" ;;
        esac
        ;;
    esac
    [ "$found" -eq 1 ] && break
  done
fi

if [ "$found" -eq 0 ]; then
  log "no local redis declared — skipping"
  exit 0
fi

if redis-cli -h 127.0.0.1 -p "$PORT" ping >/dev/null 2>&1; then
  log "redis already listening on ${PORT}"
  exit 0
fi

log "starting redis on 127.0.0.1:${PORT}..."
ARGS=(--daemonize yes --bind 127.0.0.1 --port "$PORT" --save "" --appendonly no)
[ -n "$PASS" ] && ARGS+=(--requirepass "$PASS")
redis-server "${ARGS[@]}" >/dev/null 2>&1 || { log "FAILED to start redis"; exit 0; }

i=0
until redis-cli -h 127.0.0.1 -p "$PORT" ${PASS:+-a "$PASS" --no-auth-warning} ping >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 15 ] && { log "FAILURE: redis not ready"; exit 0; }
  sleep 1
done
log "redis ready on 127.0.0.1:${PORT}"
exit 0
