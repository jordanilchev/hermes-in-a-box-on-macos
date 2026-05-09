#!/usr/bin/env bash
# Idempotent driver: set up rootless dockerd for hermes, then install the
# Hermes Agent binary as the hermes user. Re-runnable.
#
# Order matters: rootless docker must be live before Hermes Agent's first
# tool call, which uses terminal.backend=docker.
#
# Implementation notes:
#  - Multi-line scripts go via stdin heredoc, not argv, because limactl/ssh
#    flatten newlines in argv to spaces.
#  - We run as root inside the VM and `runuser -u hermes` to switch, instead
#    of `sudo -iu hermes`, because `sudo -i` joins argv with spaces and
#    destroys the inner shell quoting. `runuser` does a clean user switch
#    without that quirk.
#  - XDG_RUNTIME_DIR is set explicitly so `systemctl --user` finds the
#    user's systemd manager (linger created it at boot).

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

if ! limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
  exit 1
fi

echo "==> setting up rootless dockerd for hermes"
limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
XDG="/run/user/${HERMES_UID}"
[ -d "$XDG" ] || { echo "$XDG missing — is linger enabled for hermes?" >&2; exit 1; }
runuser -u hermes -- env \
  HOME=/srv/hermes \
  XDG_RUNTIME_DIR="$XDG" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG/bus" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  bash -s <<'INNER_EOS'
set -eu
if ! systemctl --user is-active --quiet docker 2>/dev/null; then
  dockerd-rootless-setuptool.sh install
fi
systemctl --user enable --now docker
docker info >/dev/null
docker info | grep -qi rootless || { echo "rootless mode not active" >&2; exit 1; }
INNER_EOS
OUTER_EOS

echo "==> installing Hermes Agent as hermes"
# SUDO_ASKPASS=/bin/false makes any sudo prompt fail fast. System deps are
# already present from cloud-init, so the upstream installer should never
# need to escalate.
limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  XDG_RUNTIME_DIR="/run/user/${HERMES_UID}" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  SUDO_ASKPASS=/bin/false \
  bash -s <<'INNER_EOS'
set -eu
if [ ! -x "$HOME/.local/bin/hermes" ]; then
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
fi
# Schema is nested: terminal.backend, not terminal_backend. The CLI accepts
# arbitrary keys without validation, so a wrong key writes a dead top-level
# entry the runtime ignores. Verify with `hermes config show` (Backend: docker).
"$HOME/.local/bin/hermes" config set terminal.backend docker

# Upstream installer's `npx playwright install --with-deps chromium` dies
# silently here: --with-deps tries to apt-install system libs and SUDO_ASKPASS
# refuses the prompt. The libs are already present (ubuntu-hermes.yaml pre-
# installs libnss3, libatk1.0-0, libcups2, etc.), so just fetching the browser
# binary without --with-deps is enough. Idempotent — playwright skips browsers
# it has already cached under ~/.cache/ms-playwright/.
HERMES_AGENT_DIR="$HOME/.hermes/hermes-agent"
NODE_BIN="$HOME/.hermes/node/bin"
if [ -d "$HERMES_AGENT_DIR" ] && [ -x "$NODE_BIN/npx" ]; then
  ( cd "$HERMES_AGENT_DIR" && PATH="$NODE_BIN:$PATH" "$NODE_BIN/npx" playwright install chromium )
fi
INNER_EOS
OUTER_EOS

cat <<MSG

Hermes Agent installed. Next steps:
  ./scripts/hermes-config.sh         set an API key
  ./scripts/hermes-gateway.sh start  start the long-running daemon (optional)
  ./scripts/hermes.sh chat           interactive
MSG
