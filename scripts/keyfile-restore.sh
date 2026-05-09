#!/usr/bin/env bash
# Restore the ZFS keyfile inside the VM from a base64 backup made by
# scripts/keyfile-backup.sh. Run this after factory-reset or after rebuilding
# the rootfs so the pool can be unlocked again.
#
# Usage: ./scripts/keyfile-restore.sh [path-to-tank.key.b64]
#        defaults to ${HERMES_VM_HOME}/tank.key.b64

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

IN="${1:-${HERMES_VM_HOME}/tank.key.b64}"

if [ ! -s "${IN}" ]; then
  echo "keyfile backup not found or empty: ${IN}" >&2
  exit 1
fi

# Hand the base64 to the VM via stdin; never write the raw key to a host file.
limactl shell "${HERMES_VM_NAME}" -- sudo bash -c '
  set -eu
  umask 077
  install -d -m 0700 -o root -g root /etc/zfs
  base64 -d > /etc/zfs/tank.key
  chmod 0400 /etc/zfs/tank.key
  zfs load-key -a
  zfs mount -a
' < "${IN}"

echo "==> keyfile restored, datasets remounted"
limactl shell "${HERMES_VM_NAME}" -- sudo zfs get -H -o value keystatus tank
