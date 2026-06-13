#!/usr/bin/env bash
# Manage the hermes-gateway.service systemd unit inside the VM.
#
# Usage:
#   ./scripts/hermes-gateway.sh {install-unit|enable|disable|start|stop|restart|status|logs}
#
# install-unit drops the hardened unit (fixes Hermes upstream %U bug). Called
# automatically before enable/start/restart. The unit is disabled by cloud-init;
# enable + start manually after ./scripts/hermes-config.sh has set an API key.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

UNIT_FILE="$(dirname "$0")/hermes-gateway.service"

install_unit() {
  if [ ! -f "${UNIT_FILE}" ]; then
    echo "error: missing ${UNIT_FILE}" >&2
    exit 1
  fi
  limactl shell "${HERMES_VM_NAME}" -- sudo tee /etc/systemd/system/hermes-gateway.service > /dev/null \
    < "${UNIT_FILE}"
  limactl shell "${HERMES_VM_NAME}" -- sudo systemctl daemon-reload
}

case "${1:-status}" in
  install-unit)
    install_unit
    echo "installed hardened hermes-gateway.service"
    ;;
  enable|start|restart)
    install_unit
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl "$1" hermes-gateway.service
    ;;
  disable|stop|status)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl "$1" hermes-gateway.service
    ;;
  logs)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo journalctl -u hermes-gateway.service -f
    ;;
  *)
    echo "usage: $0 {install-unit|enable|disable|start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
