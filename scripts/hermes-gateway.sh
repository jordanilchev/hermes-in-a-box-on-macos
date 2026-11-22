#!/usr/bin/env bash
# Manage the hermes-gateway.service systemd unit inside the VM.
#
# Usage:
#   ./scripts/hermes-gateway.sh {install-unit|ensure|enable|disable|start|stop|restart|status|logs}
#
# install-unit drops the hardened unit (fixes Hermes upstream %U bug). Called
# automatically before enable/start/restart/ensure.
# ensure = install-unit + enable --now when /srv/hermes/.hermes/.env exists
# (no-op if Hermes is not configured yet). start/enable also enable the unit
# so it survives VM reboots.

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

hermes_configured() {
  # .env is mode 600 as user hermes — probe via sudo, not the lima login user.
  limactl shell "${HERMES_VM_NAME}" -- sudo test -f /srv/hermes/.hermes/.env \
    && limactl shell "${HERMES_VM_NAME}" -- sudo test -x /srv/hermes/.local/bin/hermes
}

ensure_gateway() {
  install_unit
  if ! hermes_configured; then
    echo "hermes-gateway: skipped (no .env / hermes binary yet)"
    return 0
  fi
  # enable so VM reboots keep it; restart so updates pick up the new binary
  limactl shell "${HERMES_VM_NAME}" -- sudo systemctl enable hermes-gateway.service
  limactl shell "${HERMES_VM_NAME}" -- sudo systemctl restart hermes-gateway.service
  limactl shell "${HERMES_VM_NAME}" -- sudo systemctl is-active --quiet hermes-gateway.service
  echo "hermes-gateway: enabled and active"
}

case "${1:-status}" in
  install-unit)
    install_unit
    echo "installed hardened hermes-gateway.service"
    ;;
  ensure)
    ensure_gateway
    ;;
  enable|start)
    install_unit
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl enable --now hermes-gateway.service
    ;;
  restart)
    install_unit
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl restart hermes-gateway.service
    ;;
  disable|stop|status)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl "$1" hermes-gateway.service
    ;;
  logs)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo journalctl -u hermes-gateway.service -f
    ;;
  *)
    echo "usage: $0 {install-unit|ensure|enable|disable|start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
