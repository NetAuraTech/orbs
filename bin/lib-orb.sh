#!/usr/bin/env bash

ORBS_HOME="${ORBS_HOME:-$HOME/.orbs}"
ORB_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORB_REGISTRY="$ORB_BIN_DIR/orb-registry.mjs"
ORB_IMAGE="${ORB_IMAGE:-opencode-orb:latest}"
ORB_PORT_BASE="${ORB_PORT_BASE:-14100}"

HOST_CONFIG_DIR="$(cygpath -u "$USERPROFILE/.config/opencode")"
HOST_DATA_DIR="$(cygpath -u "$USERPROFILE/.local/share/opencode")"
HOST_TEMP_DIR="$(cygpath -u "$LOCALAPPDATA/Temp/opencode")"
HOST_SKILLS_DIR="$(cygpath -u "$USERPROFILE/.agents/skills")"
HOST_CLAUDE_SKILLS_DIR="$(cygpath -u "$USERPROFILE/.claude/skills")"

log() { printf '[orb] %s\n' "$*"; }
die() { printf '[orb] ERROR: %s\n' "$*" >&2; exit 1; }
winpath() { cygpath -w -m "$1"; }

wslpath() { printf '%s' "$1" | sed -E 's#^/([a-z])/#/mnt/\1/#'; }

# IP of the Windows host as reachable from the Docker network (WSL2).
# host-gateway (172.17.0.1) only serves the WSL2 netns, not the Windows host;
# the WSL2 default gateway (e.g. 192.168.64.1) points to the Windows host.
host_ip() {
  local gw
  gw="$(wsl -e bash -c 'ip route show default | awk "/default/ {print \$3; exit}"' 2>/dev/null | tr -d '[:space:]')"
  printf '%s' "${gw:-host-gateway}"
}

dockerw() {
  wsl -e bash -c "docker $*"
}

jsonget() {
  printf '%s' "$1" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let v;try{v=JSON.parse(d)}catch{process.exit(0)}
      const path=process.argv[1].slice(1).split(".").filter(Boolean);
      let x=v;for(const p of path){if(x==null){x=undefined;break}x=x[p]}
      if(x!==undefined)console.log(typeof x==="object"?JSON.stringify(x):x)
    })' "$2"
}

resolve_repo() {
  git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null
}

alloc_port() {
  node -e '
    const net=require("net");
    const base=parseInt(process.argv[1],10);
    const busy=(p)=>new Promise(r=>{const s=net.createServer();s.once("error",()=>r(true));s.listen(p,"127.0.0.1",()=>s.close(()=>r(false)))});
    (async()=>{for(let i=0;i<500;i++){const p=base+i;if(!await busy(p)){console.log(p);process.exit(0)}}process.exit(1)})();
  ' "$ORB_PORT_BASE"
}

wait_health() {
  local port="$1" tries="${2:-120}" name="${3:-}"
  local i fw_warned=0
  for i in $(seq 1 "$tries"); do
    curl -sf "http://127.0.0.1:${port}/global/health" >/dev/null 2>&1 && return 0
    # tell apart "server down" from a Docker Desktop port-forwarding hiccup
    if [ -n "$name" ] && [ "$i" -ge 30 ] && [ $((i % 20)) -eq 0 ]; then
      if dockerw exec "$name" curl -sf -m 3 http://127.0.0.1:4096/global/health >/dev/null 2>&1; then
        if [ "$fw_warned" -eq 0 ]; then
          log "server OK inside the container but host port not ready yet (Docker Desktop hiccup) — still waiting"
          fw_warned=1
        fi
      fi
    fi
    sleep 0.5
  done
  return 1
}

send_task() {
  local port="$1" title="$2" task="$3" model="${4:-}"
  local sess sid body
  sess=$(curl -sf -X POST "http://127.0.0.1:${port}/session" \
    -H 'Content-Type: application/json' \
    -d "$(node -e 'console.log(JSON.stringify({title:process.argv[1]}))' "$title")") || return 1
  sid=$(jsonget "$sess" .id)
  [ -n "$sid" ] || return 1
  body=$(node -e '
    const m=process.argv[2]||undefined;
    const parts=[{type:"text",text:process.argv[1]}];
    if(m){
      const i=m.indexOf("/");
      const model={providerID:m.slice(0,i),modelID:m.slice(i+1)};
      console.log(JSON.stringify({model,parts}));
    }else{
      console.log(JSON.stringify({parts}));
    }
  ' "$task" "$model")
  curl -sf -X POST "http://127.0.0.1:${port}/session/${sid}/prompt_async" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null || return 1
  printf '%s' "$sid"
}

attach_cmd() {
  local id="$1"
  printf 'wsl -e docker exec -it orb-%s opencode attach --continue http://127.0.0.1:4096 --dir /workspace' "$id"
}

open_terminal_wt() {
  local id="$1" port="$2"
  local cmd
  cmd=$(attach_cmd "$id")
  if command -v wt >/dev/null 2>&1; then
    wt new-tab --title "orb-${id}" $cmd
  elif command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe //c "start orb-${id} $cmd"
  else
    log "no terminal opener found; attach manually with: $cmd"
  fi
}

herdr_available() {
  command -v herdr >/dev/null 2>&1 || return 1
  herdr status 2>/dev/null | grep -q "status: running"
}

open_terminal_herdr() {
  local id="$1" port="$2"
  herdr_available || return 1
  # avoid MSYS path conversion (/workspace -> C:/Program Files/Git/workspace)
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
  local created tab pane pane_id tab_id
  created=$(herdr tab create 2>/dev/null) || return 1
  tab=$(jsonget "$created" ".result.tab")
  pane=$(jsonget "$created" ".result.root_pane")
  [ -n "$pane" ] || return 1
  pane_id="$pane"
  [[ "$pane" == \{* ]] && pane_id=$(jsonget "$pane" .pane_id)
  [ -n "$pane_id" ] || return 1
  if [ -n "$tab" ]; then
    tab_id="$tab"
    [[ "$tab" == \{* ]] && tab_id=$(jsonget "$tab" .tab_id)
    if [ -n "$tab_id" ]; then
      herdr tab rename "$tab_id" "orb-${id}" >/dev/null 2>&1 || true
    fi
  fi
  if herdr agent start "orb-${id}" --kind opencode --pane "$pane_id" \
      --timeout 60000 -- \
      attach --continue "http://127.0.0.1:${port}" --dir /workspace \
      >/dev/null 2>&1; then
    return 0
  fi
  herdr pane run "$pane_id" "$(attach_cmd "$id")" >/dev/null 2>&1
}

open_terminal() {
  local id="$1" port="$2" mode="${3:-auto}"
  case "$mode" in
    none)
      log "no terminal opened (re-attach with: attach-orb.sh $id)"
      ;;
    wt)
      open_terminal_wt "$id" "$port"
      ;;
    herdr)
      open_terminal_herdr "$id" "$port" || die "could not open a herdr tab"
      ;;
    auto)
      if open_terminal_herdr "$id" "$port"; then
        log "orb opened in a new herdr tab"
      else
        open_terminal_wt "$id" "$port"
      fi
      ;;
  esac
}
