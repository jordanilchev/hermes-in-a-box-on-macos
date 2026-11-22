#!/usr/bin/env bash
# Update the Hermes Agent inside the VM.
#
# Usage: ./scripts/hermes-update.sh [VERSION_OR_REF]
#
#   VERSION_OR_REF  PyPI version (e.g. 0.19.0) or git ref:
#                   - v2026.8.18
#                   - git:v2026.8.18
#                   - git:main
#                   Default: HERMES_GIT_REF if set, else HERMES_VERSION from env.sh
#
# Upstream no longer allows building wheels from a git URL (`pip install
# git+https://...` fails). Git refs are installed via an editable checkout at
# /srv/hermes/.hermes/hermes-agent (uv pip install -e ".[all]").
#
# Examples:
#   ./scripts/hermes-update.sh                 # default pin
#   ./scripts/hermes-update.sh 0.19.0          # PyPI pin
#   ./scripts/hermes-update.sh v2026.8.18      # GitHub release tag (editable)
#   ./scripts/hermes-update.sh git:main        # bleeding edge
#
# After updating, refreshes the hardened unit and re-enables/restarts the
# gateway when Hermes is configured (survives the update without a manual step).

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TARGET_VERSION="${1:-${HERMES_GIT_REF:-${HERMES_VERSION}}}"

if ! limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
  exit 1
fi

MODE="pypi"
GIT_REF=""
case "${TARGET_VERSION}" in
  git:*)
    MODE="git"
    GIT_REF="${TARGET_VERSION#git:}"
    ;;
  # GitHub release tags / branches (PyPI lags; prefer editable checkout).
  v[0-9]*|v20*|v2026*|main|master|HEAD)
    MODE="git"
    GIT_REF="${TARGET_VERSION}"
    ;;
  *)
    MODE="pypi"
    ;;
esac

if [ "${MODE}" = "git" ]; then
  echo "==> updating Hermes Agent from git:${GIT_REF} (editable checkout)"
  limactl shell "${HERMES_VM_NAME}" -- sudo env GIT_REF="${GIT_REF}" bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  GIT_REF="$GIT_REF" \
  XDG_RUNTIME_DIR="/run/user/${HERMES_UID}" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  UV_NO_CONFIG=1 \
  bash -s <<'INNER_EOS'
set -eu
UV="$HOME/.local/bin/uv"
[ -x "$UV" ] || UV="$(command -v uv)"
REPO="$HOME/.hermes/hermes-agent"
mkdir -p "$HOME/.hermes"
if [ ! -d "$REPO/.git" ]; then
  rm -rf "$REPO"
  git clone --filter=blob:none --branch "$GIT_REF" \
    https://github.com/NousResearch/hermes-agent.git "$REPO" \
    || git clone --filter=blob:none https://github.com/NousResearch/hermes-agent.git "$REPO"
fi
cd "$REPO"
git remote set-url origin https://github.com/NousResearch/hermes-agent.git
git fetch --tags --force origin "$GIT_REF" 2>/dev/null \
  || git fetch --tags --force origin
git checkout -f "$GIT_REF"
VIRTUAL_ENV="$HOME/.hermes/venv" "$UV" pip install -e ".[all]"
echo "hermes-agent editable @ $(git describe --tags --always)"
"$HOME/.hermes/venv/bin/hermes" --version 2>/dev/null | head -3 || true
INNER_EOS
OUTER_EOS
  DISPLAY_TARGET="git:${GIT_REF}"
else
  echo "==> updating Hermes Agent to PyPI ${TARGET_VERSION}"
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
"$HOME/.hermes/venv/bin/hermes" --version 2>/dev/null | head -3 || true
INNER_EOS
OUTER_EOS
  DISPLAY_TARGET="${TARGET_VERSION}"
fi

echo "==> refreshing hardened hermes-gateway.service unit + restarting gateway"
"${SCRIPTS}/hermes-gateway.sh" ensure

cat <<MSG

Hermes Agent updated to ${DISPLAY_TARGET}.
Gateway unit refreshed and ensured (enabled --now when configured).
MSG
