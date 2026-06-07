#!/usr/bin/env bash
# Update the Hermes Agent inside the VM to a pinned PyPI version.
#
# Usage: ./scripts/hermes-update.sh [VERSION]
#
#   VERSION  PyPI version to install (default: HERMES_VERSION from env.sh)
#
# Examples:
#   ./scripts/hermes-update.sh            # install default pinned version
#   ./scripts/hermes-update.sh 0.15.0     # upgrade to a specific version
#
# To change the default pin for everyone, update HERMES_VERSION in env.sh.
#
# After updating, restart the gateway if it is running:
#   ./scripts/hermes-gateway.sh restart

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

TARGET_VERSION="${1:-${HERMES_VERSION}}"

if ! limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
  exit 1
fi

echo "==> updating Hermes Agent to ${TARGET_VERSION}"
limactl shell "${HERMES_VM_NAME}" -- sudo env TARGET_VERSION="${TARGET_VERSION}" bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  TARGET_VERSION="$TARGET_VERSION" \
  XDG_RUNTIME_DIR="/run/user/${HERMES_UID}" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  UV_NO_CONFIG=1 \
  bash -s <<'INNER_EOS'
set -eu
cd "$HOME"
UV="$HOME/.local/bin/uv"
[ -x "$UV" ] || UV="$(command -v uv)"
VIRTUAL_ENV="$HOME/.hermes/venv" "$UV" pip install "hermes-agent[all]==${TARGET_VERSION}"
echo "hermes-agent updated to ${TARGET_VERSION}"
INNER_EOS
OUTER_EOS

cat <<MSG

Hermes Agent updated to ${TARGET_VERSION}.
If the gateway is running, restart it:  ./scripts/hermes-gateway.sh restart
MSG
