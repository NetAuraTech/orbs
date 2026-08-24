#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-orb.sh"

usage() {
  cat <<EOF
usage: attach-orb.sh <orb-id>

Open a new terminal attached to the orb (starts the container if it is stopped).
Multiple terminals can be attached to the same orb in parallel.
EOF
  exit "${1:-0}"
}

ID="${1:-}"
[ -n "$ID" ] || usage 2
ID="${ID#orb-}"
NAME="orb-$ID"
TERMINAL="${TERMINAL:-auto}"

ENTRY="$(node "$ORB_REGISTRY" get "$ID" 2>/dev/null)" || die "orb $ID not in registry (see: orb.sh list)"
PORT="$(jsonget "$ENTRY" .port)"
[ -n "$PORT" ] || die "no port recorded for orb $ID"

STATUS="$(dockerw inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)" || die "container $NAME not found"
if [ "$STATUS" != "running" ]; then
  log "container is $STATUS — starting..."
  dockerw start "$NAME" >/dev/null || die "docker start failed"
  wait_health "$PORT" 240 "orb-$ID" || die "orb server did not become healthy after start"
fi

PATCH="$(node -e 'console.log(JSON.stringify({state:"running",last_active:new Date().toISOString()}))')"
node "$ORB_REGISTRY" update "$ID" "$PATCH" >/dev/null

case "$TERMINAL" in
  none) printf '%s\n' "$(attach_cmd "$ID")" ;;
  *) open_terminal "$ID" "$PORT" "$TERMINAL" ;;
esac
log "attached to $NAME (port $PORT)"
