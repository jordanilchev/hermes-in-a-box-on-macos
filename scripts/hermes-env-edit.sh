#!/usr/bin/env bash
# Open /srv/hermes/.hermes/.env in an editor as the hermes user inside
# the VM. Saves preserve hermes ownership and the 0600 mode bit because
# the editor process itself is hermes — there's no host-side rewrite.
#
# Picks $EDITOR from the host if it resolves to vi/vim/nano/emacs (all
# preinstalled in the VM via cloud-init); otherwise falls back to vi.
# A host editor like /Applications/Cursor.app/... wouldn't exist inside
# the VM, so blindly forwarding it would just error.
#
# Note: hermes-gateway and any running CLI sessions read .env at start
# and don't auto-reload. Restart them after editing if the change
# matters: `./scripts/hermes-gateway.sh restart`.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

# Two-step because `:-default` and `##*/` can't combine in one expansion,
# and `set -u` from env.sh would trip on a bare ${EDITOR##*/} when EDITOR
# isn't set in the host shell.
host_editor="${EDITOR:-vi}"
case "${host_editor##*/}" in
  vi|vim|nano|emacs) editor="${host_editor##*/}" ;;
  *) editor=vi ;;
esac

# TERM is forwarded so the editor renders correctly. PATH includes the
# hermes-local bin so the editor can shell out (e.g. nano spell-check)
# without surprises. HOME points the editor at the right rcfile dir.
exec limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- env \
  HOME=/srv/hermes \
  TERM="${TERM:-xterm-256color}" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$editor" /srv/hermes/.hermes/.env
