#!/usr/bin/env bash
# Full VM cold-copy backup via APFS clonefile (cp -c).
# Stops the VM, copies disk + datadisk + lima.yaml + repo YAML, then starts it.
# On APFS the copy is essentially instant until the file diverges.
#
# Backups land in ${HERMES_VM_HOME}/backups/<timestamp>/.

. "$(dirname "$0")/env.sh"

require_cmd limactl
require_cmd cp

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${HERMES_VM_HOME}/backups/${TS}"
INSTANCE_DIR="${LIMA_HOME}/${HERMES_VM_NAME}"
TANK_DISK_DIR="${LIMA_HOME}/_disks/tank"

if [ ! -d "${INSTANCE_DIR}" ]; then
  echo "instance dir not found: ${INSTANCE_DIR}" >&2
  exit 1
fi

was_running=0
if limactl list 2>/dev/null | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  was_running=1
  echo "==> Stopping ${HERMES_VM_NAME} for consistent copy"
  limactl stop "${HERMES_VM_NAME}"
fi

echo "==> Cloning files into ${BACKUP}"
mkdir -p "${BACKUP}"
# diffdisk = the qcow2 overlay above the cached image (Lima 2.x layout).
# datadisk = the raw block device for the encrypted ZFS pool.
cp -c "${INSTANCE_DIR}/diffdisk"               "${BACKUP}/diffdisk"
cp -c "${INSTANCE_DIR}/lima.yaml"              "${BACKUP}/lima.yaml"
cp -c "${TANK_DISK_DIR}/datadisk"              "${BACKUP}/datadisk"
cp -c "${HERMES_VM_REPO}/ubuntu-hermes.yaml"   "${BACKUP}/ubuntu-hermes.yaml"

echo "==> Backup written: ${BACKUP}"
ls -lah "${BACKUP}"

if [ "$was_running" -eq 1 ]; then
  echo "==> Starting ${HERMES_VM_NAME} again"
  limactl start "${HERMES_VM_NAME}" || true
fi
