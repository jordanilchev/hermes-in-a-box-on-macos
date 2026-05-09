#!/usr/bin/env bash
# Open a sudo-able shell inside the VM (or run a one-off command).
#   ./scripts/shell.sh                    # interactive
#   ./scripts/shell.sh -- sudo docker ps  # one-off command

. "$(dirname "$0")/env.sh"

require_cmd limactl

if [ "$#" -eq 0 ]; then
  exec limactl shell "${HERMES_VM_NAME}"
else
  # Strip a leading -- if present (so the call style above works either way).
  [ "${1:-}" = "--" ] && shift
  exec limactl shell "${HERMES_VM_NAME}" -- "$@"
fi
