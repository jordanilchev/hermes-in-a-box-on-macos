#!/usr/bin/env bash
# Restore a VM from a backup directory created by backup.sh.
# DESTRUCTIVE: overwrites the live disk + datadisk + lima.yaml in place.
#
# Usage: ./scripts/restore.sh <backup-dir-name>
#        e.g. ./scripts/restore.sh 20260509-113000

. "$(dirname "$0")/env.sh"

require_cmd limactl
require_cmd cp

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <backup-dir-name>" >&2
  echo "  available backups under ${HERMES_VM_HOME}/backups/:" >&2
  ls -1 "${HERMES_VM_HOME}/backups/" 2>&1 | sed 's/^/    /' >&2
  exit 2
fi

NAME="$1"
BACKUP="${HERMES_VM_HOME}/backups/${NAME}"
INSTANCE_DIR="${LIMA_HOME}/${HERMES_VM_NAME}"
TANK_DISK_DIR="${LIMA_HOME}/_disks/tank"

if [ ! -d "${BACKUP}" ]; then
  echo "backup not found: ${BACKUP}" >&2
  exit 1
fi
for f in diffdisk datadisk lima.yaml; do
  if [ ! -f "${BACKUP}/${f}" ]; then
    echo "incomplete backup: missing ${BACKUP}/${f}" >&2
    exit 1
  fi
done

cat <<EOF
This will overwrite the live VM with the contents of:
  ${BACKUP}
Target:
  ${INSTANCE_DIR}/diffdisk
  ${INSTANCE_DIR}/lima.yaml
  ${TANK_DISK_DIR}/datadisk

EOF
read -rp "type 'restore' to proceed: " confirm
[ "$confirm" = "restore" ] || { echo "aborted"; exit 1; }

if limactl list 2>/dev/null | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "==> Stopping ${HERMES_VM_NAME}"
  limactl stop "${HERMES_VM_NAME}"
fi

echo "==> Cloning files back"
cp -c "${BACKUP}/diffdisk"  "${INSTANCE_DIR}/diffdisk"
cp -c "${BACKUP}/lima.yaml" "${INSTANCE_DIR}/lima.yaml"
cp -c "${BACKUP}/datadisk"  "${TANK_DISK_DIR}/datadisk"

echo "==> Starting ${HERMES_VM_NAME}"
limactl start "${HERMES_VM_NAME}" || true
echo "==> Restore complete; verify with scripts/verify.sh"
