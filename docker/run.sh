#!/usr/bin/env bash
# Run the Taskavista stack.
#
# Runs in the foreground; Ctrl+C stops the stack. Any extra arguments are
# passed through to `docker compose up`, e.g.
#   ./run.sh -d        # detached
#   ./run.sh --build   # rebuild images first
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

docker compose up "$@"
