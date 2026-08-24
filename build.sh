#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker build -f Dockerfile.orb -t "${ORB_IMAGE:-opencode-orb:latest}" .
