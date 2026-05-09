#!/usr/bin/env bash
# Initial setup: storage layout, pre-create tank disk, start VM.
# Idempotent — safe to re-run after a partial failure.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

TANK_SIZE="${TANK_SIZE:-200GiB}"

echo "==> Storage layout under ${HERMES_VM_HOME}"
mkdir -p "${HERMES_VM_HOME}/lima" "${HERMES_VM_HOME}/backups"

echo "==> Pre-create '${HERMES_VM_NAME}-tank' (${TANK_SIZE})"
# additionalDisks does NOT auto-create disks; it references pre-created ones.
# This is the most common first-run failure if skipped.
if ! limactl disk list 2>&1 | awk '{print $1}' | grep -qx "tank"; then
  limactl disk create tank --size "${TANK_SIZE}"
else
  echo "    tank disk already exists; skipping"
fi

echo "==> Start ${HERMES_VM_NAME} (image download + provisioning, ~5-10 min on first run)"
echo "    Note: limactl may exit with 'did not receive an event with the running"
echo "    status' on first start; that's a known cosmetic timeout — VM is up."
echo "    See README.md > Troubleshooting if you hit it."
limactl start --tty=false --name="${HERMES_VM_NAME}" "${HERMES_VM_REPO}/ubuntu-hermes.yaml" || {
  rc=$?
  if limactl list 2>/dev/null | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
    echo "    instance is Running despite the non-zero exit ($rc); continuing"
  else
    echo "    instance failed to come up (exit $rc); inspect ${LIMA_HOME}/${HERMES_VM_NAME}/ha.stderr.log"
    exit "$rc"
  fi
}

echo "==> Done. Verify with: $(dirname "$0")/verify.sh"
