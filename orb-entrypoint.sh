#!/usr/bin/env bash
set -euo pipefail

if [ -d /host-config ]; then
  mkdir -p /root/.config/opencode
  cp -r /host-config/. /root/.config/opencode/ 2>/dev/null || true
  if [ -f /root/.config/opencode/opencode.json ]; then
    node /usr/local/bin/orb-config.mjs \
      /root/.config/opencode/opencode.json \
      /root/.config/opencode/opencode.json >/dev/null 2>&1 || true
  fi
fi

if [ -n "${GH_TOKEN:-}" ]; then
  printf '%s' "$GH_TOKEN" | gh auth login --with-token >/dev/null 2>&1 || true
  git config --global --add url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
  git config --global --add url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:"
fi

if [ ! -d /workspace/.git ] && [ -n "${ORB_REPO_URL:-}" ]; then
  if [ -n "${ORB_BASE_BRANCH:-}" ]; then
    git clone --branch "$ORB_BASE_BRANCH" "$ORB_REPO_URL" /workspace \
      || git clone "$ORB_REPO_URL" /workspace
  else
    git clone "$ORB_REPO_URL" /workspace
  fi
  cd /workspace
  git config user.name "${GIT_AUTHOR_NAME:-orb}"
  git config user.email "${GIT_AUTHOR_EMAIL:-orb@localhost}"
  if [ -n "${ORB_BRANCH:-}" ]; then
    git checkout -b "$ORB_BRANCH" 2>/dev/null || true
  fi
else
  cd /workspace
fi

# .env* from the host repo -> workspace (copied on every start = refreshed on restart)
if [ -d /host-repo ] && [ -d /workspace/.git ]; then
  shopt -s nullglob
  for f in /host-repo/.env /host-repo/.env.*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *.example) continue ;; esac
    cp -f "$f" "/workspace/$(basename "$f")"
    echo "[orb-entrypoint] env copied: $(basename "$f")"
  done
fi

# local services declared in the .env* files: postgres (roles+databases) and redis
/usr/local/bin/orb-db-init.sh || true
/usr/local/bin/orb-redis-init.sh || true

# install dependencies before the server answers (failure is non-fatal)
if [ -d /workspace/.git ]; then
  cd /workspace
  if [ -f package.json ]; then
    echo "[orb-entrypoint] installing npm dependencies..."
    if [ -f package-lock.json ]; then
      npm ci --no-audit --no-fund 2>&1 | tail -5 \
        || npm install --no-audit --no-fund 2>&1 | tail -5 \
        || echo "[orb-entrypoint] npm install FAILED (non-fatal)"
    else
      npm install --no-audit --no-fund 2>&1 | tail -5 \
        || echo "[orb-entrypoint] npm install FAILED (non-fatal)"
    fi
    echo "[orb-entrypoint] npm done"
  fi
  if [ -f composer.json ]; then
    echo "[orb-entrypoint] installing composer dependencies..."
    composer install --no-interaction --no-progress 2>&1 | tail -8 \
      || echo "[orb-entrypoint] composer install FAILED (non-fatal)"
    echo "[orb-entrypoint] composer done"
  fi
fi

exec opencode serve --port "${ORB_SERVER_PORT:-4096}" --hostname 0.0.0.0
