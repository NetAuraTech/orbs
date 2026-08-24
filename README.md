# Orbs

Local, self-hosted equivalent of Amp Code's "orbs": **isolated Docker containers, each running a
full OpenCode agent** on a dedicated clone of your repository, with an interactive terminal tab,
GitHub auth, local databases and dependency installation handled automatically.

Launch a coding task on a branch, watch the agent work live in its own Herdr tab, then retrieve
the results via a regular commit/push from within the orb and a merge on the host.

## How it works

```
 ┌────────────────────────── Windows host ──────────────────────────┐
 │                                                                  │
 │  launch-orb.sh                                                   │
 │    │  gh auth token ──► $ORB_DIR/env (chmod 600)                 │
 │    ▼                                                             │
 │  ┌──────────── WSL2 / Docker ────────────────────────────────┐   │
 │  │  container orb-<id>          volume orb-<id>-ws           │   │
 │  │  ┌──────────────────────┐    ┌──────────────────────┐    │   │
 │  │  │ opencode serve :4096 │───►│ /workspace           │    │   │
 │  │  │ postgres 16          │    │  git clone (origin)  │    │   │
 │  │  │ redis                │    │  branch orb/<id>     │    │   │
 │  │  │ npm/composer install │    │  .env* copied        │    │   │
 │  │  └──────────▲───────────┘    └──────────────────────┘    │   │
 │  └─────────────┼───────────────────────────────────────────┘   │
 │                │ http://127.0.0.1:<port>                       │
 │  Herdr tab ◄───┘  (agent TUI attached, registered agents menu)  │
 └──────────────────────────────────────────────────────────────────┘
```

Each orb gets:

- its own **Docker volume** (`orb-<id>-ws`) holding a fresh `git clone` of the repo, on branch `orb/<id>`;
- the host's **OpenCode config** (JSONC cleaned up, `localhost` rewritten to
  `host.docker.internal`), auth, skills and temp dir mounted inside;
- **git/gh authentication** via the host's GitHub token (`gh auth token`) — push, PRs and issues
  just work;
- **`.env*` files** copied from the host repo at every start (refreshed on restart);
- **dependency installation**: `npm ci`/`npm install` when `package.json` exists,
  `composer install` when `composer.json` exists (failure is non-fatal);
- **PostgreSQL 16 and Redis running inside the container**, provisioned from the `.env*`
  declarations (roles, databases, ports, passwords);
- an interactive **Herdr tab** with the agent TUI attached to the orb's session
  (fallback: Windows Terminal), visible in Herdr's agents menu.

## Repository layout

```
Dockerfile.orb         image: ubuntu 24.04 + node 24 + opencode + php/composer + postgres + redis
orb-entrypoint.sh      container bootstrap: config, auth, clone, env copy, services, installs
orb-db-init.sh         postgres provisioning from .env* (roles + databases, idempotent)
orb-redis-init.sh      redis startup from .env* (port/password, idempotent)
build.sh               builds the opencode-orb:latest image
bin/lib-orb.sh         shared helpers (dockerw, host_ip, wait_health, send_task, open_terminal...)
bin/launch-orb.sh      creates and starts an orb
bin/orb.sh             list / status / kill / remove
bin/attach-orb.sh      reopens a terminal attached to an existing orb
bin/orb-cleanup.sh     stops idle orbs (TTL) and prunes old paused ones
bin/orb-registry.mjs   registry of running/paused orbs (~/.orbs/registry.json)
bin/orb-config.mjs     JSONC cleanup + localhost→host.docker.internal rewrite + permissions
orb-schedule.ps1       registers a scheduled task running the cleanup every 15 minutes
skill/orbs/SKILL.md    agent-facing documentation (also installed in ~/.agents/skills/orbs)
```

The canonical, self-contained copy of everything lives in `~/.agents/skills/orbs/`; this
repository mirrors it for development.

## Requirements

- Windows with **WSL2** and a working `docker` CLI inside WSL (Docker Desktop or native)
- Git Bash (`bash.exe`) to run the scripts
- [`gh`](https://cli.github.com/) authenticated (`gh auth token`) for private repos and push
- [Herdr](https://herdr.dev) for the integrated tab experience (optional: falls back to
  Windows Terminal)
- Node.js available from Git Bash (used by helper one-liners)

## Build the image

```bash
wsl -e bash "$HOME/.agents/skills/orbs/build.sh"
# equivalent to: docker build -f Dockerfile.orb -t opencode-orb:latest .
```

## Usage

```bash
ORBS_BIN="$HOME/.agents/skills/orbs/bin"

# launch an orb on the current repo with a task
bash "$ORBS_BIN/launch-orb.sh" "Fix the failing tests in src/auth" .

# explicit repo, no terminal, custom model
bash "$ORBS_BIN/launch-orb.sh" --no-terminal --model provider/model --repo-url https://github.com/me/repo.git "Refactor X"

# start without sending a task (interact manually later)
bash "$ORBS_BIN/launch-orb.sh" --no-task ~/dev/myproject

# reopen a terminal attached to an orb (restarts it if stopped)
bash "$ORBS_BIN/attach-orb.sh" <id>

# inspect / manage
bash "$ORBS_BIN/orb.sh" list
bash "$ORBS_BIN/orb.sh" status <id>
bash "$ORBS_BIN/orb.sh" kill <id>            # stop, keep the volume
bash "$ORBS_BIN/orb.sh" remove <id>          # refuses if uncommitted/unpushed work (--force overrides)

# cleanup: stop orbs idle > 60 min, prune paused > 24 h
bash "$ORBS_BIN/orb-cleanup.sh" --ttl 60 --prune

# schedule the cleanup every 15 minutes
powershell -File "$HOME\.agents\skills\orbs\orb-schedule.ps1"
```

The API of a running orb is reachable at `http://127.0.0.1:<port>` (base port 14100,
auto-allocated). Useful endpoints: `/global/health`, `/session`, `/session/:id/prompt_async`.

### Retrieving results

Work happens on branch `orb/<id>` inside the orb's volume. From a terminal attached to the orb:

```bash
git add -A && git commit -m "..." && git push -u origin orb/<id>
```

then merge `orb/<id>` from your host checkout (or open a PR with `gh pr create` from inside the orb).

## Environment files and databases

At every start (and restart) the entrypoint:

1. copies the host repo's top-level `.env`, `.env.*` (except `*.example`) into `/workspace`;
2. parses them and provisions **local** services only:
   - **Postgres** — vars `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, `PG_DB_NAME`
     (or `DB_*`, or a `DATABASE_URL` starting with `postgres://`): starts the cluster,
     creates the role (with password) and each distinct database, idempotently;
   - **Redis** — vars `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` or `REDIS_URL`: starts the
     daemon on the declared port, with `requirepass` when a password is set;
3. runs `npm ci`/`npm install` and `composer install` when manifests exist.

Hosts pointing anywhere other than `127.0.0.1`/`localhost` are deliberately left untouched.
Failures are logged to `docker logs orb-<id>` and never block startup.

## Safety model

- Orbs are isolated: their filesystem is their own volume; host mounts are read-only except temp.
- `remove` refuses to delete an orb whose volume holds uncommitted changes or unpushed commits
  (`--force` overrides); automatic cleanup never deletes such orbs either.
- A concurrent-launch lock (PID-checked, with stale-lock recovery) prevents two launches colliding.
- The GitHub token is written to `$ORB_DIR/env` with mode 600 and passed to the container only.

## Known limitations / troubleshooting

- **Docker Desktop port-forwarding hiccups**: occasionally `127.0.0.1:<port>` is not routable
  for a few minutes while the container itself is healthy. `wait_health` detects this
  ("server OK inside the container…") and keeps waiting instead of failing blindly.
- **Container exits with code 255, empty logs**: a WSL2 hiccup — `docker start orb-<id>` (or
  `attach-orb.sh`) brings it back.
- **Empty Herdr tab / agent missing from the agents menu**: herdr resolves `opencode` through
  `Start-Process`, which fails if only non-Win32 shims exist on PATH. Neutralize the shims
  (`opencode`, `opencode.ps1` in `%APPDATA%\npm`) and place the real binary as
  `%APPDATA%\npm\opencode.exe` (see SKILL.md troubleshooting).
