---
name: orbs
description: "Launch and manage local OpenCode orbs: isolated Docker containers, each running a full OpenCode agent on a dedicated git clone (Docker volume) with an interactive Herdr tab. Use when the user wants to run a task in an orb, reopen an orb, list, inspect, stop or clean up orbs."
---

# Orbs

An orb is a Docker container (`opencode-orb` image) running a full OpenCode agent
(headless `opencode serve`) on a **clone of the repo in a dedicated Docker volume**, with the
host's OpenCode config (`~/.config/opencode`), auth (`auth.json`), skills
(`~/.agents/skills`, `~/.claude/skills`) and temp dir (`%LOCALAPPDATA%\Temp\opencode`)
mounted inside. The orb gets git/gh access using the host's GitHub token (`GH_TOKEN`), so
push/pull/PRs/issues work without re-login. Host services (OmniRoute, LM Studio, etc.)
are reachable via `host.docker.internal` (already rewritten in the orb config).

Standalone skill: everything lives in this directory (`~/.agents/skills/orbs`). Scripts
can be overridden via `ORBS_BIN`:

```bash
ORBS_BIN="${ORBS_BIN:-$HOME/.agents/skills/orbs/bin}"
```

## Launching an orb

```bash
bash "$ORBS_BIN/launch-orb.sh" "<task>" [path/to/repo]
```

- Without the 2nd argument: the git repo of the **current directory** (the project OpenCode is running in).
- Clones the repo (origin remote) into a Docker volume `orb-<id>-ws`, creates branch
  `orb/<id>`, starts container `orb-<id>`, copies the host's `.env*` files, installs
  dependencies (npm/composer), sends the task as the first message, then **opens a new
  Herdr tab** with the agent TUI attached (fallback: new Windows terminal if Herdr is absent).
- The script is short and non-interactive (the tab opens detached): it does not block the session.
  Startup includes installs: allow several minutes before the `ready` line.
- Options: `--no-terminal` (no tab), `--terminal wt|herdr|none`, `--no-task`.
- The orb ID is printed at the end (`orb <id> ready`). Report it back to the user.
- **To relay the agent's answer into your own conversation**, wait for completion and
  print it:
  ```bash
  bash "$ORBS_BIN/orb.sh" await <id>
  ```
  It blocks until the orb's initial task is finished (`--timeout s`, default 900) then
  prints the agent's final text answer. Use it whenever the user asks the orb something
  whose result must come back to you (e.g. "launch an orb and list the files").

## Reopening / observing an orb

```bash
bash "$ORBS_BIN/attach-orb.sh" <id>
```

- Restarts the container if stopped, opens a **new Herdr tab** attached.
- Can be called multiple times: several terminals can be attached in parallel.

## Listing / inspecting

```bash
bash "$ORBS_BIN/orb.sh" list
bash "$ORBS_BIN/orb.sh" status <id>
bash "$ORBS_BIN/orb.sh" await <id> [--timeout s]
```

`status` shows: container, branch, volume, API port (`http://127.0.0.1:<port>`), health,
active sessions.

## Stopping / deleting

```bash
bash "$ORBS_BIN/orb.sh" kill <id>       # stop the container, work kept in its volume
bash "$ORBS_BIN/orb.sh" remove <id>     # delete container + volume (refuses uncommitted work, --force to override)
```

## TTL cleanup

```bash
bash "$ORBS_BIN/orb-cleanup.sh" --ttl 60 --prune
```

- Stops orbs idle for more than 60 minutes (idle = no busy session reported by the API).
- `--prune` also removes orbs paused for more than 24 hours (`--prune-ttl`).
- Orbs with uncommitted changes in their volume are **never** removed automatically.
- Scheduling (task every 15 min):
  `powershell -File "$HOME\.agents\skills\orbs\orb-schedule.ps1"`.

## Rules

- Never recreate a volume manually: always go through `launch-orb.sh`.
- If the image is missing: `wsl -e bash "$HOME/.agents/skills/orbs/build.sh"`
  (or `docker build -f <skill>/Dockerfile.orb -t opencode-orb:latest <skill>`).
- An orb works in its own clone (branch `orb/<id>`); results are retrieved by
  commit + push from within the orb, then merged from the host.
- The registry is `~/.orbs/registry.json` (do not edit by hand).
- On every start (and every restart), the entrypoint copies the host repo's `.env*`
  files (mounted RO at `/host-repo`) into `/workspace`, then runs `npm install`
  (`npm ci` when a lockfile exists) and/or `composer install`. A failed install
  does not prevent the orb from starting (visible in `docker logs orb-<id>`).
- **Postgres and Redis run inside the orb**: if a `.env*` file declares a local host
  (`127.0.0.1`/`localhost`) via `PG_*`/`DB_*` or `DATABASE_URL` (postgres), the cluster
  is started and roles/databases are created automatically (idempotent, port taken from
  `PG_PORT`). Same for Redis via `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD` (or
  `REDIS_URL`). Remote hosts are never touched.
- The host repo is visible read-only inside the container at `/host-repo`.

## Troubleshooting

- **Empty herdr tab / agent missing from the agents menu**: herdr launches `opencode`
  via `Start-Process`, which fails when the PATH holds no valid Win32 executable.
  Fix applied on this machine: npm shims neutralized
  (`%APPDATA%\npm\opencode` → `opencode.sh-disabled`, `opencode.ps1` → `opencode.ps1-disabled`)
  and the native binary copied to `%APPDATA%\npm\opencode.exe`. After `npm update -g
  opencode-ai`, re-copy the exe:
  `Copy-Item "$env:APPDATA\npm\node_modules\opencode-ai\node_modules\opencode-windows-x64\bin\opencode.exe" "$env:APPDATA\npm\"`.
- **Container `Exited (255)` with no error in the logs**: WSL2/Docker hiccup (unrelated
  to orbs). `docker start orb-<id>` is enough; `attach-orb.sh` does it automatically.
