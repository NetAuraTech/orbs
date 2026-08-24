#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-orb.sh"

TTL=60
PRUNE=0
PRUNE_TTL=1440
YES=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl) TTL="${2:?}"; shift ;;
    --prune) PRUNE=1 ;;
    --prune-ttl) PRUNE_TTL="${2:?}"; shift ;;
    --yes|-y) YES=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help)
      cat <<EOF
usage: orb-cleanup.sh [--ttl min] [--prune] [--prune-ttl min] [--yes] [--dry-run]

Stops orbs that have been idle for more than TTL minutes (default 60).
With --prune, also removes orbs that have been paused for more than
PRUNE_TTL minutes (default 1440). Orbs with uncommitted changes in
their volume are never removed automatically.
EOF
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

orb_busy() {
  curl -sf "http://127.0.0.1:${1}/session/status" 2>/dev/null | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      const s=JSON.parse(d||"{}");
      const busy=Object.values(s).some(v=>["busy","active","running","working","streaming","pending","retry"].includes(String(v&&v.type||v||"").toLowerCase()));
      process.exit(busy?0:1);
    });'
}

ms_since() {
  node -e 'const a=Date.parse(process.argv[1]);console.log(a?Math.max(0,Date.now()-a):0)' "$1"
}

orbs="$(node "$ORB_REGISTRY" list)"

while IFS= read -r id; do
  [ -n "$id" ] || continue
  entry="$(node "$ORB_REGISTRY" get "$id")"
  port="$(jsonget "$entry" .port)"
  last="$(jsonget "$entry" .last_active)"
  cstate="$(dockerw inspect -f '{{.State.Status}}' "orb-$id" 2>/dev/null || echo missing)"

  if [ "$cstate" = "running" ]; then
    if orb_busy "$port" 2>/dev/null; then
      PATCH="$(node -e 'console.log(JSON.stringify({last_active:new Date().toISOString()}))')"
      node "$ORB_REGISTRY" update "$id" "$PATCH" >/dev/null
      log "$id: busy — activity refreshed"
      continue
    fi
    idle_min=$(( $(ms_since "$last") / 60000 ))
    if [ "$idle_min" -ge "$TTL" ]; then
      if [ "$DRY" = 1 ]; then
        log "$id: would stop (idle ${idle_min} min)"
        continue
      fi
      dockerw stop "orb-$id" >/dev/null
      PATCH="$(node -e 'console.log(JSON.stringify({state:"paused",last_active:new Date().toISOString()}))')"
      node "$ORB_REGISTRY" update "$id" "$PATCH" >/dev/null
      log "$id: stopped (idle ${idle_min} min)"
    fi
    continue
  fi

  if [ "$PRUNE" = 1 ] && [ "$cstate" != "missing" ]; then
    idle_min=$(( $(ms_since "$last") / 60000 ))
    if [ "$idle_min" -ge "$PRUNE_TTL" ]; then
      log "$id: prune candidate (paused ${idle_min} min)"
      if [ "$DRY" = 1 ]; then
        log "$id: would remove"
        continue
      fi
      if [ "$YES" = 0 ]; then
        printf 'Remove orb %s (paused %s min)? [y/N] ' "$id" "$idle_min"
        read -r ans || ans=""
        if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
          log "$id: kept"
          continue
        fi
      fi
      vol="$(jsonget "$entry" .volume)"
      dockerw start "orb-$id" >/dev/null 2>&1 || true
      dirty="$(dockerw exec "orb-$id" git -C /workspace status --porcelain 2>/dev/null || true)"
      dockerw stop "orb-$id" >/dev/null 2>&1 || true
      if [ -n "$dirty" ]; then
        log "$id: KEPT — volume has uncommitted changes"
        continue
      fi
      dockerw rm "orb-$id" >/dev/null 2>&1 || true
      [ -n "$vol" ] && dockerw volume rm "$vol" >/dev/null 2>&1 || true
      rm -rf "$ORBS_HOME/orbs/$id"
      node "$ORB_REGISTRY" remove "$id" >/dev/null
      log "$id: removed"
    fi
  fi
done < <(printf '%s' "$orbs" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{for(const o of JSON.parse(d))console.log(o.id)})')
