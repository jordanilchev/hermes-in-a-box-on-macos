#!/usr/bin/env bash
# DESTRUCTIVE: tear down the VM and its data disk, leaving backups intact.
# Requires explicit confirmation. Will NOT touch ${HERMES_VM_HOME}/backups/.

. "$(dirname "$0")/env.sh"

require_cmd limactl

cat <<EOF
This will permanently destroy:
  - VM instance: ${HERMES_VM_NAME}     (${LIMA_HOME}/${HERMES_VM_NAME})
  - data disk:   tank (200 GiB)        (${LIMA_HOME}/_disks/tank)

It will NOT touch:
  - ${HERMES_VM_HOME}/backups/
  - ${HERMES_VM_REPO}/ubuntu-hermes.yaml

Make sure you have run scripts/keyfile-backup.sh if you ever plan to mount
data from a snapshot of the data disk again.
EOF
read -rp "type 'destroy' to proceed: " confirm
[ "$confirm" = "destroy" ] || { echo "aborted"; exit 1; }

limactl delete --force "${HERMES_VM_NAME}" || true
limactl disk delete tank || true
rm -rf "${LIMA_HOME}/_disks/tank"
echo "==> teardown complete"
