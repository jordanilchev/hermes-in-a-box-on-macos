#!/usr/bin/env bash
# Resize an existing Lima instance for host-side Ollama headroom.
#
# Stops the VM, patches cpus/memory in the live lima.yaml, restarts, and
# verifies the encrypted ZFS tank pool and Hermes mountpoints are intact.
# Does NOT delete disks, the tank pool, or instance state.
#
# Usage:
#   ./scripts/hermes-vm-tune.sh            # apply HERMES_VM_CPUS / HERMES_VM_MEMORY
#   ./scripts/hermes-vm-tune.sh --dry-run  # show planned changes only

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

INSTANCE_YAML="${LIMA_HOME}/${HERMES_VM_NAME}/lima.yaml"

if [ ! -f "${INSTANCE_YAML}" ]; then
  echo "error: instance not found at ${INSTANCE_YAML} — run ./scripts/setup.sh first" >&2
  exit 1
fi

if ! limactl disk list 2>/dev/null | awk '{print $1}' | grep -qx tank; then
  echo "error: limactl disk 'tank' not found — refusing to continue" >&2
  exit 1
fi

patch_lima_field() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}:" "${file}"; then
    sed -i '' "s/^${key}:.*/${key}: \"${value}\"/" "${file}"
  else
    echo "error: ${key} not found in ${file}" >&2
    exit 1
  fi
}

# cpus is unquoted in yaml; memory is quoted.
patch_lima_cpus() {
  sed -i '' "s/^cpus:.*/cpus: ${HERMES_VM_CPUS}/" "$1"
}

echo "==> Planned Lima tuning for ${HERMES_VM_NAME}"
echo "    cpus:   -> ${HERMES_VM_CPUS}"
echo "    memory: -> ${HERMES_VM_MEMORY}"
echo "    ZFS arc_max: ${ZFS_ARC_MAX_BYTES} bytes (via cloud-init provision on start)"
echo "    tank disk: preserved (not modified)"

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "dry-run: no changes applied"
  exit 0
fi

if limactl list 2>/dev/null | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "==> Stopping ${HERMES_VM_NAME}"
  limactl stop "${HERMES_VM_NAME}"
fi

echo "==> Patching ${INSTANCE_YAML}"
cp "${INSTANCE_YAML}" "${INSTANCE_YAML}.bak.$(date +%Y%m%d%H%M%S)"
patch_lima_cpus "${INSTANCE_YAML}"
patch_lima_field memory "${HERMES_VM_MEMORY}" "${INSTANCE_YAML}"

echo "==> Starting ${HERMES_VM_NAME}"
"$(dirname "$0")/start.sh"

echo "==> Refreshing hermes-gateway.service unit (UID 999 docker.sock paths)"
"$(dirname "$0")/hermes-gateway.sh" install-unit

echo "==> Capping ZFS ARC + verifying tank / Hermes data"
limactl shell "${HERMES_VM_NAME}" -- sudo env ZFS_ARC_MAX_BYTES="${ZFS_ARC_MAX_BYTES}" bash -s <<'EOS'
set -eu
install -d /etc/modprobe.d
printf 'options zfs zfs_arc_max=%s\n' "${ZFS_ARC_MAX_BYTES}" > /etc/modprobe.d/zfs.conf
if [ -w /sys/module/zfs/parameters/zfs_arc_max ]; then
  echo "${ZFS_ARC_MAX_BYTES}" > /sys/module/zfs/parameters/zfs_arc_max
fi
zpool list tank >/dev/null
for d in /srv/hermes /var/lib/hermes /var/log/hermes; do
  mountpoint -q "$d" || { echo "error: $d not mounted" >&2; exit 1; }
done
ARC_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max)
echo "tank: ok"
echo "hermes mounts: ok"
echo "zfs_arc_max: ${ARC_MAX} bytes"
test -x /srv/hermes/.local/bin/hermes && echo "hermes binary: ok" || echo "hermes binary: missing (run hermes-install.sh)"
EOS

echo "==> Done. Host should have more headroom for Ollama."
limactl list "${HERMES_VM_NAME}"
