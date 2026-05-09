#!/usr/bin/env bash
# Manage the hermes-gateway.service systemd unit inside the VM.
#
# Usage:
#   ./scripts/hermes-gateway.sh {enable|disable|start|stop|restart|status|logs}
#
# The unit is dropped (disabled) by cloud-init. Enable + start manually after
# ./scripts/hermes-config.sh has set an API key.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

case "${1:-status}" in
  enable|disable|start|stop|restart|status)
    action="$1"
    ;;
  logs)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo journalctl -u hermes-gateway.service -f
    ;;
  *)
    echo "usage: $0 {enable|disable|start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac

exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl "${action}" hermes-gateway.service
