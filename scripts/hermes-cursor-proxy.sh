#!/usr/bin/env bash
# Manage the Cursor Agent API proxy inside the VM.
#
# The proxy exposes an OpenAI-compatible endpoint at http://localhost:4646/v1
# backed by your Cursor subscription. All LLM inference goes to Cursor's cloud
# via the official `agent` CLI binary (arm64 native, authenticated with
# CURSOR_API_KEY from .env).
#
# One-time setup:
#   1. ./scripts/hermes-config.sh        # enter CURSOR_API_KEY when prompted
#   2. ./scripts/hermes-cursor-proxy.sh install
#   3. ./scripts/hermes-cursor-proxy.sh enable-hermes
#
# To revert hermes back to OpenRouter:
#   ./scripts/hermes-cursor-proxy.sh disable-hermes
#
# Usage:
#   ./scripts/hermes-cursor-proxy.sh {install|start|stop|restart|status|logs|enable-hermes|disable-hermes}

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

if ! limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running; then
  echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
  exit 1
fi

cmd="${1:-status}"

case "$cmd" in

  install)
    echo "==> installing Cursor agent CLI and cursor-agent-api-proxy"
    limactl shell "${HERMES_VM_NAME}" -- sudo env UV_NO_CONFIG=1 bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  XDG_RUNTIME_DIR="/run/user/${HERMES_UID}" \
  PATH=/srv/hermes/.local/bin:/srv/hermes/.hermes/node/bin:/usr/local/bin:/usr/bin:/bin \
  bash -s <<'INNER_EOS'
set -eu
cd "$HOME"

# ── Cursor agent CLI ──
if [ ! -x "$HOME/.local/bin/agent" ]; then
  curl -LsSf https://cursor.com/install | bash
else
  echo "agent CLI already installed: $("$HOME/.local/bin/agent" --version)"
fi

# ── cursor-agent-api-proxy via hermes bundled npm ──
if [ ! -x "$HOME/.local/bin/cursor-agent-api" ]; then
  npm install -g --prefix "$HOME/.local" cursor-agent-api-proxy
  echo "cursor-agent-api installed: $HOME/.local/bin/cursor-agent-api"
else
  echo "cursor-agent-api already installed"
fi
INNER_EOS
OUTER_EOS

    echo "==> writing systemd unit"
    limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'UNIT_EOS'
set -eu
# Extract CURSOR_API_KEY from .env into a dedicated small env file so the
# proxy service does not get the full .env exposed in its environment.
CURSOR_API_KEY=$(grep '^CURSOR_API_KEY=' /srv/hermes/.hermes/.env | cut -d= -f2-)
if [ -z "$CURSOR_API_KEY" ]; then
  echo "CURSOR_API_KEY not found in .env — run ./scripts/hermes-config.sh first" >&2
  exit 1
fi
cat > /srv/hermes/.hermes/.env.cursor <<EOF
CURSOR_API_KEY=${CURSOR_API_KEY}
EOF
chmod 600 /srv/hermes/.hermes/.env.cursor
chown hermes:hermes /srv/hermes/.hermes/.env.cursor

cat > /etc/systemd/system/hermes-cursor-proxy.service <<'EOF'
[Unit]
Description=Cursor Agent API Proxy (OpenAI-compatible, port 4646)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
EnvironmentFile=/srv/hermes/.hermes/.env.cursor
Environment=HOME=/srv/hermes
Environment=PATH=/srv/hermes/.local/bin:/srv/hermes/.hermes/node/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/srv/hermes/.local/bin/cursor-agent-api run 4646
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/srv/hermes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "unit written and daemon reloaded"
UNIT_EOS

    cat <<MSG

Cursor proxy installed. Next steps:
  ./scripts/hermes-cursor-proxy.sh start          start the proxy service
  ./scripts/hermes-cursor-proxy.sh enable-hermes  switch hermes to use Cursor
MSG
    ;;

  enable-hermes)
    echo "==> switching hermes to Cursor backend (localhost:4646)"
    limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'EOS'
set -eu
runuser -u hermes -- env HOME=/srv/hermes PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
  bash -c '
    hermes config set model.base_url http://localhost:4646/v1
    hermes config set model.default sonnet-4.5
    hermes config set model.api_key not-needed
  '
EOS
    echo "done. hermes will now route LLM calls through the Cursor proxy."
    echo "To verify: ./scripts/hermes.sh -z 'what model are you?'"
    ;;

  disable-hermes)
    echo "==> reverting hermes to OpenRouter"
    limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'EOS'
set -eu
runuser -u hermes -- env HOME=/srv/hermes PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
  bash -c '
    hermes config set model.base_url https://openrouter.ai/api/v1
    hermes config set model.default openrouter/owl-alpha
  '
# Remove model.api_key so OpenRouter uses OPENROUTER_API_KEY from .env normally.
# hermes config has no "unset" command, so edit the yaml directly.
CONFIG=/srv/hermes/.hermes/config.yaml
runuser -u hermes -- python3 - "$CONFIG" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f)
cfg.get('model', {}).pop('api_key', None)
with open(path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print("removed model.api_key from", path)
PYEOF
EOS
    echo "done. hermes is back on OpenRouter/owl-alpha."
    ;;

  start|stop|restart|status)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo systemctl "${cmd}" hermes-cursor-proxy.service
    ;;

  logs)
    exec limactl shell "${HERMES_VM_NAME}" -- sudo journalctl -u hermes-cursor-proxy.service -f
    ;;

  *)
    echo "usage: $0 {install|start|stop|restart|status|logs|enable-hermes|disable-hermes}" >&2
    exit 1
    ;;
esac
