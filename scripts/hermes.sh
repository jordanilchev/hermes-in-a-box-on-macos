#!/usr/bin/env bash
# Interactive wrapper: run the hermes binary as the hermes user inside the VM.
#
# Usage:
#   ./scripts/hermes.sh chat
#   ./scripts/hermes.sh config show
#   ./scripts/hermes.sh --version

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

# Quote $HOME so it expands inside the VM under `sudo -iu hermes`, not on the host.
exec limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -lc '"$HOME/.local/bin/hermes" "$@"' hermes "$@"
