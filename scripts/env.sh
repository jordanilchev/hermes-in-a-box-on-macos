#!/usr/bin/env bash
# Source this from any other script in scripts/ to load common environment.
#
#   . "$(dirname "$0")/env.sh"
#
# Variables:
#   HERMES_VM_HOME   root directory where the VM bundle, disks, and backups live.
#                    Default: $HOME/hermes-vm-data
#                    Override: export HERMES_VM_HOME=/path/to/your/apfs/volume/hermes-vm
#   LIMA_HOME        Lima's instance directory.
#                    Default: $HERMES_VM_HOME/lima
#   HERMES_VM_REPO   directory containing this repo (computed from script path).
#   HERMES_VM_NAME   Lima instance name. Default: ubuntu-hermes
#
# Hard fails if a required CLI is missing.

set -eu

: "${HERMES_VM_HOME:=${HOME}/hermes-vm-data}"
: "${LIMA_HOME:=${HERMES_VM_HOME}/lima}"
: "${HERMES_VM_NAME:=ubuntu-hermes}"

# Resolve the repo root from this script's location: scripts/env.sh -> ..
HERMES_VM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

export HERMES_VM_HOME LIMA_HOME HERMES_VM_NAME HERMES_VM_REPO

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' not found in PATH" >&2
    echo "       see README.md > Appendix E for install instructions" >&2
    exit 127
  fi
}
