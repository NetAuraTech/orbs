#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-orb.sh"

usage() {
  cat <<EOF
usage: launch-orb.sh [options] "<task>" [repo]

Launch an isolated OpenCode orb (Docker container) with the given task.
The orb clones the repo (origin remote) into its own Docker volume and works
on a dedicated branch orb/<id>. Git and gh inside the orb use the host's
GitHub auth (GH_TOKEN), so push/pull/PRs/issues work without re-login.

arguments:
  <task>          first message sent to the orb agent
  [repo]          git repo path (default: repo containing the current directory)

options:
  --terminal <t>  auto | herdr | wt | none  (default: auto, herdr preferred)
  --no-terminal   same as --terminal none
  --model <m>     model for the orb agent (provider/model, default: opencode's choice)
  --repo-url <u>  repo url to clone (default: origin remote of [repo])
  --base-branch <b>  branch to start from (default: current branch of [repo])
  --no-task       start the orb without sending the initial task
  -h, --help      this help
EOF
  exit "${1:-0}"
}

TERMINAL=auto
SEND_TASK=1
TASK=""
REPO=""
MODEL="${ORB_MODEL:-}"
REPO_URL_OVERRIDE=""
BASE_BRANCH_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --no-terminal) TERMINAL=none ;;
    --terminal) TERMINAL="${2:?}"; shift ;;
    --model) MODEL="${2:?}"; shift ;;
    --repo-url) REPO_URL_OVERRIDE="${2:?}"; shift ;;
    --base-branch) BASE_BRANCH_OVERRIDE="${2:?}"; shift ;;
    --no-task) SEND_TASK=0 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$TASK" ]; then TASK="$1"; else REPO="$1"; fi ;;
  esac
  shift
done

# With --no-task, a leftover positional argument is the repo, not a task
if [ "$SEND_TASK" = 0 ] && [ -n "$TASK" ] && [ -z "$REPO" ]; then
  REPO="$TASK"
  TASK=""
fi

if [ "$SEND_TASK" = 1 ] && [ -z "$TASK" ]; then
  die "missing task argument (or use --no-task)"
fi

REPO_URL="$REPO_URL_OVERRIDE"
BASE_BRANCH="$BASE_BRANCH_OVERRIDE"
if [ -z "$REPO" ] && [ -z "$REPO_URL" ]; then
  REPO="$(resolve_repo "$PWD")" || die "no git repo found in $PWD — pass the repo path or --repo-url"
fi
if [ -n "$REPO" ]; then
  REPO="$(cd "$REPO" && pwd)"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
  [ -n "$REPO_URL" ] || REPO_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
  [ -n "$BASE_BRANCH" ] || BASE_BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD || true)"
fi
case "$REPO_URL" in
  git@github.com:*) REPO_URL="https://github.com/${REPO_URL#git@github.com:}" ;;
esac
[ -n "$REPO_URL" ] || die "no repo url — the repo has no 'origin' remote (use --repo-url)"

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
dockerw info >/dev/null 2>&1 || die "docker daemon not running (via WSL)"
command -v wsl >/dev/null 2>&1 || die "wsl not found (needed to bind-mount host paths)"
docker image inspect "$ORB_IMAGE" >/dev/null 2>&1 || \
  die "image $ORB_IMAGE not found — build it: docker build -f Dockerfile.orb -t $ORB_IMAGE . (in the orbs repo)"

# Concurrent-launch guard (mkdir is atomic)
LOCK_DIR="$ORBS_HOME/.launch.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if { [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; } || [ "$lock_age" -gt 900 ]; then
    log "stale lock (${lock_age}s, pid ${lpid:-?}) — breaking it"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "cannot acquire launch lock"
  else
    die "another orb launch is in progress (lock ${lock_age}s old, pid ${lpid:-?})"
  fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

ID="$(printf '%s-%04x%04x' "$(date +%m%d%H%M%S)" $RANDOM $RANDOM)"
NAME="orb-$ID"
BRANCH="orb/$ID"
WS_VOL="orb-$ID-ws"
ORB_DIR="$ORBS_HOME/orbs/$ID"
SID=""
GH_TOKEN_VAL="$(gh auth token 2>/dev/null || true)"
[ -n "$GH_TOKEN_VAL" ] || log "warning: no gh token found — the orb can only clone public repos and cannot push"

docker ps -a --format '{{.Names}}' | grep -qx "$NAME" && die "container $NAME already exists"
mkdir -p "$ORB_DIR"

log "repo:     ${REPO:-<none>} ($REPO_URL, base ${BASE_BRANCH:-default})"
log "orb:      $NAME (branch $BRANCH)"
log "volume:   $WS_VOL"

PORT="$(alloc_port)" || die "no free port found (base $ORB_PORT_BASE)"

MOUNTS=(
  "$(wslpath "$HOST_CONFIG_DIR"):/host-config:ro"
)
[ -f "$HOST_DATA_DIR/auth.json" ] && MOUNTS+=("$(wslpath "$HOST_DATA_DIR/auth.json"):/root/.local/share/opencode/auth.json:ro")
[ -d "$HOST_TEMP_DIR" ] && MOUNTS+=("$(wslpath "$HOST_TEMP_DIR"):/host-temp")
[ -d "$HOST_SKILLS_DIR" ] && MOUNTS+=("$(wslpath "$HOST_SKILLS_DIR"):/root/.agents/skills:ro")
[ -d "$HOST_CLAUDE_SKILLS_DIR" ] && MOUNTS+=("$(wslpath "$HOST_CLAUDE_SKILLS_DIR"):/root/.claude/skills:ro")
if [ -n "${REPO:-}" ] && [ -d "$REPO" ]; then
  MOUNTS+=("$(wslpath "$REPO"):/host-repo:ro")
fi

ENV_FILE=""
if [ -n "$GH_TOKEN_VAL" ]; then
  ENV_FILE="$ORB_DIR/env"
  printf 'GH_TOKEN=%s\n' "$GH_TOKEN_VAL" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

RUN_CMD="run -d --name $NAME --label orbs.id=$ID -e ORB_ID=$ID -e ORB_REPO_URL=$REPO_URL -e ORB_BRANCH=$BRANCH -v $WS_VOL:/workspace"
[ -n "$BASE_BRANCH" ] && RUN_CMD+=" -e ORB_BASE_BRANCH=$BASE_BRANCH"
[ -n "$ENV_FILE" ] && RUN_CMD+=" --env-file $(wslpath "$ENV_FILE")"
 for m in "${MOUNTS[@]}"; do RUN_CMD+=" -v $m"; done
RUN_CMD+=" --add-host=host.docker.internal:$(host_ip) -p 127.0.0.1:$PORT:4096 $ORB_IMAGE"

log "starting container (port $PORT)..."
if ! dockerw $RUN_CMD >/dev/null; then
  dockerw rm -f "$NAME" >/dev/null 2>&1 || true
  die "docker run failed"
fi

log "waiting for the orb (clone + server) to be healthy..."
if ! wait_health "$PORT" 1800 "$NAME"; then
  dockerw logs --tail 50 "$NAME" 2>&1 || true
  die "orb did not become healthy — see logs above (container $NAME kept for debugging)"
fi

if [ "$SEND_TASK" = 1 ]; then
  SID="$(send_task "$PORT" "orb-$ID" "$TASK" "$MODEL")" || die "failed to send the initial task"
  log "task sent (session $SID)"
fi

ENTRY="$(node -e 'console.log(JSON.stringify({repo:process.argv[1]||null,repo_url:process.argv[2],base_branch:process.argv[3]||null,branch:process.argv[4],container:process.argv[5],volume:process.argv[6],port:Number(process.argv[7]),task:process.argv[8]||null,session:process.argv[9]||null,model:process.argv[10]||null,image:process.argv[11],state:"running"}))' "$REPO" "$REPO_URL" "$BASE_BRANCH" "$BRANCH" "$NAME" "$WS_VOL" "$PORT" "${TASK:-}" "$SID" "$MODEL" "$ORB_IMAGE")"
node "$ORB_REGISTRY" add "$ID" "$ENTRY" >/dev/null

open_terminal "$ID" "$PORT" "$TERMINAL"
log "orb $ID ready — http://127.0.0.1:${PORT} (branch $BRANCH)"
