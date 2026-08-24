#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-orb.sh"

usage() {
  cat <<EOF
usage: orb.sh <command>
  list                    list registered orbs
  status <id>             show orb details (container, health, sessions)
  kill <id>               stop the orb container (work kept in its volume)
  remove <id> [--force]   delete container + volume + registry entry
                          (refuses if uncommitted or unpushed work exists, unless --force)
EOF
  exit "${1:-0}"
}

check_unsaved_work() {
  local id="$1"
  local dirty unpushed
  dockerw start "orb-$id" >/dev/null 2>&1 || return 1
  dockerw exec "orb-$id" git -C /workspace fetch --all --prune >/dev/null 2>&1 || true
  dirty="$(dockerw exec "orb-$id" git -C /workspace status --porcelain 2>/dev/null || true)"
  unpushed="$(dockerw exec "orb-$id" git -C /workspace log --oneline --branches --not --remotes 2>/dev/null || true)"
  dockerw stop "orb-$id" >/dev/null 2>&1 || true
  if [ -n "$dirty" ]; then
    printf 'uncommitted changes:\n%s\n' "$dirty" | head -20
    return 0
  fi
  if [ -n "$unpushed" ]; then
    printf 'unpushed commits:\n%s\n' "$unpushed" | head -20
    return 0
  fi
  return 1
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  list)
    node "$ORB_REGISTRY" list | node -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        const orbs=JSON.parse(d);
        if(!orbs.length){console.log("no orbs registered");return}
        const pad=(s,n)=>String(s).slice(0,n).padEnd(n);
        console.log(pad("ID",26)+pad("STATE",9)+pad("PORT",7)+pad("BRANCH",24)+"REPO URL");
        for(const o of orbs)
          console.log(pad(o.id,26)+pad(o.state||"-",9)+pad(o.port||"-",7)+pad(o.branch||"-",24)+(o.repo_url||""));
      });'
    ;;
  status)
    id="${1:-}"
    [ -n "$id" ] || usage 2
    id="${id#orb-}"
    entry="$(node "$ORB_REGISTRY" get "$id" 2>/dev/null)" || die "orb $id not found"
    port="$(jsonget "$entry" .port)"
    printf 'id:         %s\n' "$id"
    printf 'container:  %s\n' "$(jsonget "$entry" .container)"
    printf 'volume:     %s\n' "$(jsonget "$entry" .volume)"
    printf 'branch:     %s\n' "$(jsonget "$entry" .branch)"
    printf 'repo url:   %s\n' "$(jsonget "$entry" .repo_url)"
    printf 'base:       %s\n' "$(jsonget "$entry" .base_branch)"
    printf 'api:        http://127.0.0.1:%s\n' "$port"
    printf 'created:    %s\n' "$(jsonget "$entry" .created)"
    printf 'last:       %s\n' "$(jsonget "$entry" .last_active)"
    dockerw inspect -f 'docker:     {{.State.Status}} (started {{.State.StartedAt}})' "orb-$id" 2>/dev/null || true
    if curl -sf "http://127.0.0.1:${port}/global/health" 2>/dev/null; then
      printf '\n'
    else
      printf 'health:     unreachable\n'
    fi
    sessions="$(curl -sf "http://127.0.0.1:${port}/session/status" 2>/dev/null || true)"
    [ -n "$sessions" ] && printf 'sessions:   %s\n' "$sessions"
    ;;
  kill)
    id="${1:-}"
    [ -n "$id" ] || usage 2
    id="${id#orb-}"
    dockerw stop "orb-$id" >/dev/null 2>&1 || die "container orb-$id not found"
    PATCH="$(node -e 'console.log(JSON.stringify({state:"paused",last_active:new Date().toISOString()}))')"
    node "$ORB_REGISTRY" update "$id" "$PATCH" >/dev/null
    log "orb $id stopped (work kept in its volume)"
    ;;
  remove)
    id="${1:-}"
    [ -n "$id" ] || usage 2
    shift || true
    force=0
    [ "${1:-}" = "--force" ] && force=1
    id="${id#orb-}"
    entry="$(node "$ORB_REGISTRY" get "$id" 2>/dev/null)" || die "orb $id not found"
    vol="$(jsonget "$entry" .volume)"
    dockerw stop "orb-$id" >/dev/null 2>&1 || true
    if [ "$force" = 0 ] && check_unsaved_work "$id"; then
      die "unsaved work found in orb $id — push/commit it, or re-run with --force"
    fi
    dockerw rm "orb-$id" >/dev/null 2>&1 || true
    [ -n "$vol" ] && dockerw volume rm "$vol" >/dev/null 2>&1 || true
    rm -rf "$ORBS_HOME/orbs/$id"
    node "$ORB_REGISTRY" remove "$id" >/dev/null
    log "orb $id removed"
    ;;
  *) usage ;;
esac
