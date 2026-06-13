#!/usr/bin/env bash
# Idempotent driver: set up rootless dockerd for hermes, then install the
# Hermes Agent binary as the hermes user. Re-runnable.
#
# Installs hermes-agent from PyPI at the pinned HERMES_VERSION (set in env.sh).
# Re-running is safe: uv no-ops if the version is already installed.
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
#  - HERMES_VERSION is passed into the VM via `sudo env` so it stays
#    available inside the single-quoted heredocs.

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

echo "==> installing Hermes Agent ${HERMES_VERSION} as hermes"
# Pass HERMES_VERSION into the VM via `sudo env` so it is available inside
# the single-quoted (no-host-expansion) heredocs below.
limactl shell "${HERMES_VM_NAME}" -- sudo env HERMES_VERSION="${HERMES_VERSION}" bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  HERMES_VERSION="$HERMES_VERSION" \
  XDG_RUNTIME_DIR="/run/user/${HERMES_UID}" \
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  SUDO_ASKPASS=/bin/false \
  UV_NO_CONFIG=1 \
  bash -s <<'INNER_EOS'
set -eu
cd "$HOME"

# ── uv ──
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV="$HOME/.local/bin/uv"
[ -x "$UV" ] || UV="$(command -v uv)"

# ── venv ──
[ -d "$HOME/.hermes/venv" ] || "$UV" venv "$HOME/.hermes/venv" --python 3.11

# ── install / pin ──
VIRTUAL_ENV="$HOME/.hermes/venv" "$UV" pip install "hermes-agent[all]==${HERMES_VERSION}"

# ── launcher shim ──
mkdir -p "$HOME/.local/bin"
# Remove any existing symlink or file so the write doesn't follow it.
rm -f "$HOME/.local/bin/hermes"
cat > "$HOME/.local/bin/hermes" <<'SHIM'
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
exec "/srv/hermes/.hermes/venv/bin/hermes" "$@"
SHIM
chmod +x "$HOME/.local/bin/hermes"

# Schema is nested: terminal.backend, not terminal_backend.
"$HOME/.local/bin/hermes" config set terminal.backend docker
INNER_EOS
OUTER_EOS

echo "==> installing hardened hermes-gateway.service unit"
"$(dirname "$0")/hermes-gateway.sh" install-unit

cat <<MSG

Hermes Agent ${HERMES_VERSION} installed. Next steps:
  ./scripts/hermes-config.sh         set an API key
  ./scripts/hermes-gateway.sh start  start the long-running daemon (optional)
  ./scripts/hermes.sh chat           interactive
MSG
