#!/usr/bin/env bash
# Open a sudo-able shell inside the VM (or run a one-off command).
#   ./scripts/shell.sh                    # interactive (tmux session if available)
#   ./scripts/shell.sh -- sudo docker ps  # one-off command
#
# Interactive mode attaches to a persistent tmux session (default name:
# hermes-vm) so SSH/limactl disconnects do not kill your VM shell. Host tmux
# keeps limactl alive when your SSH session to the Mac drops; VM tmux keeps
# your shell state when limactl reconnects. Install tmux on macOS with:
# brew install tmux. Set HERMES_SHELL_TMUX=0 to skip.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

attach_vm_shell() {
  limactl shell "${HERMES_VM_NAME}" -- env \
    HERMES_SHELL_TMUX="${HERMES_SHELL_TMUX:-1}" \
    HERMES_SHELL_SESSION="${HERMES_SHELL_SESSION}" \
    LANG="${LANG}" LC_CTYPE="${LC_CTYPE}" \
    bash -lc '
if [ "${HERMES_SHELL_TMUX}" != "0" ] \
  && [ -z "${TMUX:-}" ] \
  && command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s "${HERMES_SHELL_SESSION}"
fi
exec bash -l
'
}

if [ "$#" -eq 0 ]; then
  if [ "${HERMES_SHELL_TMUX:-1}" != "0" ] \
    && [ -z "${TMUX:-}" ] \
    && command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s "${HERMES_SHELL_SESSION}" \
      env HERMES_VM_HOME="${HERMES_VM_HOME}" LIMA_HOME="${LIMA_HOME}" \
      HERMES_SHELL_TMUX="${HERMES_SHELL_TMUX:-1}" \
      HERMES_SHELL_SESSION="${HERMES_SHELL_SESSION}" \
      LANG="${LANG}" LC_CTYPE="${LC_CTYPE}" \
      bash "$(dirname "$0")/shell.sh" --attach
  fi
  attach_vm_shell
elif [ "${1:-}" = "--attach" ]; then
  attach_vm_shell
else
  # Strip a leading -- if present (so the call style above works either way).
  [ "${1:-}" = "--" ] && shift
  exec limactl shell "${HERMES_VM_NAME}" -- "$@"
fi
