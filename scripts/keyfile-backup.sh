#!/usr/bin/env bash
# Back up the ZFS pool's encryption keyfile to a base64 file outside the VM.
# Run this BEFORE any operation that wipes the rootfs (factory-reset,
# scratch-rebuild, etc.) — losing /etc/zfs/tank.key permanently locks the pool.
#
# The output file is sensitive. Store it somewhere private (e.g., a password
# manager attachment, a hardware key vault). It is the only thing standing
# between you and the encrypted contents of the tank disk.

. "$(dirname "$0")/env.sh"

require_cmd limactl

OUT="${1:-${HERMES_VM_HOME}/tank.key.b64}"

if [ -e "${OUT}" ]; then
  echo "refusing to overwrite existing file: ${OUT}" >&2
  echo "rename the existing file or pass a different path as arg 1" >&2
  exit 1
fi

(umask 077 && limactl shell "${HERMES_VM_NAME}" -- sudo cat /etc/zfs/tank.key | base64 > "${OUT}")
chmod 0400 "${OUT}"
echo "wrote ${OUT}"
echo
echo "Keep this file private. Restore via scripts/keyfile-restore.sh <path>."
