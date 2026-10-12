#!/usr/bin/env bash
# Build the Taskavista container images.
#
# Any extra arguments are passed through to `docker compose build`, e.g.
#   ./build.sh --no-cache
#   ./build.sh postgres
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

docker compose build --pull "$@"
