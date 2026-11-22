#!/usr/bin/env bash
# Resume the full Hermes stack after stop or host reboot:
#   1. Lima VM
#   2. host Ollama (Gemma backend)
#   3. guest UFW egress to host Ollama + hermes-gateway (if configured)
#
# For login/reboot persistence: ./scripts/hermes-autostart.sh install

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# Lima may exit with a 10-minute timeout on legacy instances whose cached
# cidata still has the older `cloud-init status --wait` probe (see README.md
# > Troubleshooting). The VM itself is up well before then.
limactl start "${HERMES_VM_NAME}" || {
  rc=$?
  if limactl list 2>/dev/null | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
    echo "instance is Running despite limactl exit ($rc) — likely the cosmetic probe timeout."
  else
    echo "instance not running (exit $rc); inspect ${LIMA_HOME}/${HERMES_VM_NAME}/ha.stderr.log" >&2
    exit "$rc"
  fi
}

echo "==> host LLM (${LOCAL_LLM_BACKEND})"
case "${LOCAL_LLM_BACKEND}" in
  inkling)
    if ! "${SCRIPTS}/hermes-inkling-local.sh" start; then
      echo "inkling start failed — falling back to gemma" >&2
      echo gemma > "${LLM_BACKEND_FILE:-${HERMES_VM_HOME}/llm-backend}"
      LOCAL_LLM_BACKEND=gemma
      "${SCRIPTS}/hermes-gemma-local.sh" start
      "${SCRIPTS}/hermes-gemma-local.sh" enable-hermes || true
    fi
    echo "==> guest LLM egress + gateway"
    "${SCRIPTS}/hermes-gemma-local.sh" ensure-guest
    ;;
  gemma)
    "${SCRIPTS}/hermes-gemma-local.sh" start
    echo "==> guest LLM egress + gateway"
    "${SCRIPTS}/hermes-gemma-local.sh" ensure-guest
    ;;
  *)
    echo "error: unknown LOCAL_LLM_BACKEND=${LOCAL_LLM_BACKEND} (expected gemma|inkling)" >&2
    exit 1
    ;;
esac
"${SCRIPTS}/hermes-gateway.sh" ensure
