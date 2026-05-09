#!/usr/bin/env bash
# Emergency power-down. Frees CPU/RAM on the host immediately. State preserved.
# Resume with scripts/start.sh.

. "$(dirname "$0")/env.sh"

require_cmd limactl

exec limactl stop "${HERMES_VM_NAME}"
