#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-orb.sh"

usage() {
  cat <<EOF
usage: orb.sh <command>
  list                    list registered orbs
  status <id>             show orb details (container, health, sessions)
  await <id> [--timeout s]   wait for the orb's initial task to finish, then
                             print the agent's final answer (for the launching
                             agent to relay it; default timeout 900s)
  kill <id>               stop the orb container (work kept in its volume)
  remove <id> [--force]   delete container + volume + registry entry
                          (refuses if uncommitted or unpushed work exists, unless --force)
EOF
  exit "${1:-0}"
}

# print "busy" or "idle" for session $SID, reading a /session/status payload on stdin
session_busy_state() {
  SID="$1" node -e '
    let d="";
    process.stdin.on("data",c=>d+=c).on("end",()=>{
      let s={};try{s=JSON.parse(d||"{}")}catch(e){}
      const v=s[process.env.SID];
      const t=String((v&&v.type)||v||"idle").toLowerCase();
      console.log(["busy","active","running","working","streaming","pending","retry"].includes(t)?"busy":"idle");
    });'
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
  await)
    id="${1:-}"
    [ -n "$id" ] || usage 2
    shift || true
    timeout=900
    if [ "${1:-}" = "--timeout" ]; then timeout="${2:-900}"; fi
    id="${id#orb-}"
    entry="$(node "$ORB_REGISTRY" get "$id" 2>/dev/null)" || die "orb $id not found"
    port="$(jsonget "$entry" .port)"
    sid="$(jsonget "$entry" .session)"
    [ -n "$sid" ] || die "orb $id has no recorded session (launched with --no-task?)"
    running="$(dockerw inspect -f '{{.State.Running}}' "orb-$id" 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
      log "container stopped — starting it..."
      dockerw start "orb-$id" >/dev/null 2>&1 || die "cannot start container orb-$id"
      wait_health "$port" 90 "orb-$id"
    fi
    log "waiting for orb $id to finish its task (timeout ${timeout}s)..."
    deadline=$(( $(date +%s) + timeout ))
    while :; do
      st="$(curl -sf -m 5 "http://127.0.0.1:${port}/session/status" 2>/dev/null | session_busy_state "$sid" || echo busy)"
      if [ "$st" = "idle" ]; then
        # double-check once: make sure the final message is fully persisted
        sleep 2
        st2="$(curl -sf -m 5 "http://127.0.0.1:${port}/session/status" 2>/dev/null | session_busy_state "$sid" || echo busy)"
        [ "$st2" = "idle" ] && break
        st="$st2"
      fi
      [ "$st" = "idle" ] && break
      now="$(date +%s)"
      [ "$now" -ge "$deadline" ] && die "timed out after ${timeout}s — the orb may still be working (attach-orb.sh $id to check, or re-run await)"
      sleep 3
    done
    curl -sf -m 15 "http://127.0.0.1:${port}/session/$sid/message" | node -e '
      let d="";
      process.stdin.on("data",c=>d+=c).on("end",()=>{
        const ms=JSON.parse(d||"[]");
        const a=[...ms].reverse().find(m=>m.info.role==="assistant");
        if(!a){console.error("(no assistant message found)");process.exit(1)}
        const text=(a.parts||[]).filter(p=>p.type==="text").map(p=>p.text).join("\n");
        if(!text.trim()){console.error("(assistant produced no text response — attach-orb.sh for details)");process.exit(1)}
        console.log(text);
      });'
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
