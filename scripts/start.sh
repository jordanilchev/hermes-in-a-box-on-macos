#!/usr/bin/env bash
# Resume the VM after stop.

. "$(dirname "$0")/env.sh"

require_cmd limactl

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
