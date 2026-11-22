#!/usr/bin/env bash
# Composio integration for Hermes Twitter bookmarks.
#
# Two paths (pick one):
#   CLI + ak_ key (recommended here) — composio execute / twitter_bookmark_fetch.sh
#     1. Composio account → Settings → API Keys → copy ak_ project key
#     2. ./scripts/hermes-config.sh → COMPOSIO_API_KEY
#     3. composio login + composio link twitter inside VM (one-time)
#     4. ./scripts/hermes-composio-setup.sh install-cli
#
#   MCP + ck_ key — Hermes chat uses Composio MCP tools directly
#     1. Connect → Clients → Hermes → copy ck_ beside x-consumer-api-key
#        https://dashboard.composio.dev/org/connect/clients/hermes
#     2. ./scripts/hermes-config.sh → COMPOSIO_API_KEY
#     3. ./scripts/hermes-composio-setup.sh install && test && restart
#
# Usage:
#   ./scripts/hermes-composio-setup.sh status       # key type + CLI/MCP state
#   ./scripts/hermes-composio-setup.sh reauth       # logout → browser login → link twitter → test
#   ./scripts/hermes-composio-setup.sh install-cli  # deploy fetch script, drop MCP (ak_)
#   ./scripts/hermes-composio-setup.sh test-cli     # probe composio execute (ak_)
#   ./scripts/hermes-composio-setup.sh disable-mcp  # remove broken MCP block
#   ./scripts/hermes-composio-setup.sh install      # MCP block only (ck_ required)
#   ./scripts/hermes-composio-setup.sh test         # test-cli (ak_) or MCP (ck_)
#   ./scripts/hermes-composio-setup.sh restart      # restart gateway

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

COMPOSIO_MCP_NAME="${COMPOSIO_MCP_NAME:-composio}"
COMPOSIO_MCP_URL="${COMPOSIO_MCP_URL:-https://connect.composio.dev/mcp}"
FETCH_SCRIPT_NAME="twitter_bookmark_fetch.sh"
HOST_FETCH_SCRIPT="$(dirname "$0")/${FETCH_SCRIPT_NAME}"
VM_FETCH_SCRIPT="/srv/hermes/.hermes/scripts/${FETCH_SCRIPT_NAME}"

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

vm_hermes() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -lc '"$HOME/.local/bin/hermes" "$@"' hermes "$@"
}

vm_python() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
    /srv/hermes/.hermes/venv/bin/python3 "$@"
}

has_composio_key() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
    grep -qE '^[[:space:]]*COMPOSIO_API_KEY[[:space:]]*=' /srv/hermes/.hermes/.env 2>/dev/null
}

composio_key_prefix() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS'
set -a
source /srv/hermes/.hermes/.env
set +a
case "${COMPOSIO_API_KEY:-}" in
  ck_*) echo ck ;;
  ak_*) echo ak ;;
  *) echo other ;;
esac
EOS
}

composio_ck_key_help() {
  cat >&2 <<'EOF'
MCP requires a ck_ Connect consumer key — not the ak_ project key.

  1. Open: https://dashboard.composio.dev/org/connect/clients/hermes
  2. Copy the key beside x-consumer-api-key (starts with ck_)
  3. ./scripts/hermes-config.sh → COMPOSIO_API_KEY
  4. ./scripts/hermes-composio-setup.sh install && test && restart

For ak_ keys, use the CLI path instead:
  ./scripts/hermes-composio-setup.sh install-cli && ./scripts/hermes-composio-setup.sh test-cli
EOF
}

require_ck_composio_key() {
  local prefix
  prefix="$(composio_key_prefix)"
  case "${prefix}" in
    ck) return 0 ;;
    ak)
      echo "error: COMPOSIO_API_KEY is ak_ (project API key)." >&2
      echo "       connect.composio.dev/mcp rejects ak_ with 401 Unauthorized." >&2
      echo "       Use: ./scripts/hermes-composio-setup.sh install-cli && test-cli" >&2
      echo >&2
      composio_ck_key_help
      return 1
      ;;
    *)
      echo "error: MCP requires a ck_ Connect consumer key." >&2
      composio_ck_key_help
      return 1
      ;;
  esac
}

install_fetch_script() {
  if [ ! -f "${HOST_FETCH_SCRIPT}" ]; then
    echo "error: missing ${HOST_FETCH_SCRIPT}" >&2
    exit 1
  fi
  limactl copy "${HOST_FETCH_SCRIPT}" "${HERMES_VM_NAME}:/tmp/${FETCH_SCRIPT_NAME}"
  limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<EOS
set -eu
install -d -m 0755 /srv/hermes/.hermes/scripts
install -m 0755 "/tmp/${FETCH_SCRIPT_NAME}" "${VM_FETCH_SCRIPT}"
chown hermes:hermes "${VM_FETCH_SCRIPT}"
rm -f "/tmp/${FETCH_SCRIPT_NAME}"
EOS
  echo "  installed ${VM_FETCH_SCRIPT}"
}

disable_mcp_block() {
  vm_python - "$COMPOSIO_MCP_NAME" <<'PY'
import sys
from pathlib import Path

import yaml

name = sys.argv[1]
config_path = Path("/srv/hermes/.hermes/config.yaml")
config = yaml.safe_load(config_path.read_text()) or {}
servers = config.get("mcp_servers") or {}
if name in servers:
    del servers[name]
    if servers:
        config["mcp_servers"] = servers
    else:
        config.pop("mcp_servers", None)
    config_path.write_text(yaml.safe_dump(config, sort_keys=False, default_flow_style=False))
    print(f"removed mcp_servers.{name} from {config_path}")
else:
    print(f"mcp_servers.{name}: not present (nothing to remove)")
PY
}

install_mcp_block() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
    /srv/hermes/.hermes/venv/bin/python3 - "$COMPOSIO_MCP_NAME" "$COMPOSIO_MCP_URL" <<'PY'
import sys
from pathlib import Path

import yaml

name, url = sys.argv[1], sys.argv[2]
config_path = Path("/srv/hermes/.hermes/config.yaml")
config = yaml.safe_load(config_path.read_text()) or {}

servers = config.setdefault("mcp_servers", {})
servers[name] = {
    "url": url,
    "headers": {
        "x-consumer-api-key": "${COMPOSIO_API_KEY}",
    },
    "connect_timeout": 60,
    "timeout": 180,
    "tools": {
        "include": [
            "TWITTER_BOOKMARKS_BY_USER",
            "TWITTER_USER_LOOKUP_ME",
            "TWITTER_POST_LOOKUP_BY_POST_ID",
            "TWITTER_POST_LOOKUP_BY_POST_IDS",
        ],
    },
}

config_path.write_text(yaml.safe_dump(config, sort_keys=False, default_flow_style=False))
print(f"upserted mcp_servers.{name} in {config_path}")
PY
}

test_cli_bookmarks() {
  local max_results="${1:-5}"
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s -- "${max_results}" <<'EOS'
set -eu
max="$1"
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
set -a; source /srv/hermes/.hermes/.env; set +a
if ! command -v composio >/dev/null 2>&1; then
  echo "error: composio CLI not found — run: curl -fsSL https://composio.dev/install | bash (as hermes)" >&2
  exit 1
fi
out=$(mktemp)
trap 'rm -f "$out"' EXIT
if ! composio execute TWITTER_BOOKMARKS_BY_USER -d "{\"max_results\": $max}" >"$out"; then
  echo "error: composio execute failed" >&2
  exit 1
fi
/srv/hermes/.hermes/venv/bin/python3 - "$out" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if not data.get("successful"):
    print("error: composio returned unsuccessful:", data.get("error"), file=sys.stderr)
    sys.exit(1)
payload = data.get("data") or {}
items = payload.get("data") or []
meta = payload.get("meta") or {}
print(f"  composio execute: ok ({len(items)} bookmarks, max_results requested in probe)")
if meta.get("next_token"):
    print("  pagination: more bookmarks available (use twitter_bookmark_fetch.sh with paging)")
if items:
    first = items[0]
    text = (first.get("text") or "")[:80].replace("\n", " ")
    print(f"  sample: id={first.get('id')} text={text!r}")
PY
EOS
}

print_mcp_status() {
  vm_python - <<'PY'
import yaml
from pathlib import Path

cfg = yaml.safe_load(Path("/srv/hermes/.hermes/config.yaml").read_text()) or {}
servers = cfg.get("mcp_servers") or {}
if "composio" in servers:
    tools = (servers["composio"].get("tools") or {}).get("include") or []
    print(f"  mcp_servers.composio: configured ({len(tools)} tools) — needs ck_ key")
else:
    print("  mcp_servers.composio: disabled (CLI path)")
PY
}

print_cli_status() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS'
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
set -a
# shellcheck disable=SC1091
source /srv/hermes/.hermes/.env
set +a
script="/srv/hermes/.hermes/scripts/twitter_bookmark_fetch.sh"
if [ -x "$script" ]; then
  echo "  fetch script: installed ($script)"
else
  echo "  fetch script: missing — run ./scripts/hermes-composio-setup.sh install-cli"
fi
if command -v composio >/dev/null 2>&1; then
  echo "  composio CLI: installed ($(command -v composio))"
else
  echo "  composio CLI: missing"
fi

# CLI session key (~/.composio/user_data.json) is separate from COMPOSIO_API_KEY in .env.
cli_out="$(composio connections list 2>&1 || true)"
if printf '%s' "$cli_out" | grep -q 'HTTP 401'; then
  echo "  composio CLI auth: HTTP 401 — ~/.composio/user_data.json key is stale"
  echo "                     fix: composio login (or login --user-api-key) inside VM"
elif printf '%s' "$cli_out" | grep -q '"status": "ACTIVE"'; then
  echo "  twitter link (CLI): ACTIVE"
elif printf '%s' "$cli_out" | grep -q '"status": "EXPIRED"'; then
  echo "  twitter link (CLI): EXPIRED — run composio link twitter inside VM"
else
  echo "  twitter link (CLI): not linked / unknown — run composio link twitter inside VM"
fi

# REST probe with .env key (often still readable when CLI session is dead).
if [ -n "${COMPOSIO_API_KEY:-}" ]; then
  /srv/hermes/.hermes/venv/bin/python3 - <<'PY'
import json, os, urllib.error, urllib.request
key = os.environ.get("COMPOSIO_API_KEY", "")
req = urllib.request.Request(
    "https://backend.composio.dev/api/v3/connected_accounts",
    headers={"x-api-key": key, "Accept": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as e:
    print(f"  twitter link (REST/.env): HTTP {e.code} with COMPOSIO_API_KEY")
except Exception as e:
    print(f"  twitter link (REST/.env): probe failed ({e})")
else:
    tw = [
        i for i in (data.get("items") or [])
        if (i.get("toolkit") or {}).get("slug") == "twitter"
    ]
    if not tw:
        print("  twitter link (REST/.env): none")
    else:
        for i in tw:
            status = i.get("status") or "?"
            reason = i.get("status_reason") or ""
            extra = f" — {reason}" if reason and status != "ACTIVE" else ""
            print(f"  twitter link (REST/.env): {status}{extra}")
PY
fi
EOS
}

# Composio CLI prints some URLs one character per line inside a box. Unwrap that.
unwrap_composio_url() {
  python3 -c '
import re, sys
text = sys.stdin.read()
# strip ANSI
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
urls = re.findall(r"https://[^\s\"'\''<>]+", text)
if urls:
    print(urls[0].rstrip(").,]"))
    raise SystemExit(0)
chars = []
for ln in text.splitlines():
    m = re.search(r"[│|]\s+(\S)\s*$", ln)
    if m:
        chars.append(m.group(1))
s = "".join(chars)
m = re.search(r"https://[^\s]+", s)
if m:
    print(m.group(0))
    raise SystemExit(0)
raise SystemExit(1)
'
}

open_url_on_host() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url"
    echo "==> opened in browser: $url"
  else
    echo "==> open this URL in a browser: $url"
  fi
}

reauth_cli_and_twitter() {
  local login_timeout="${COMPOSIO_REAUTH_LOGIN_TIMEOUT:-600}"
  local link_timeout="${COMPOSIO_REAUTH_LINK_TIMEOUT:-600}"

  echo "==> clearing stale Composio CLI session"
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS'
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
composio logout >/dev/null 2>&1 || true
EOS

  echo "==> starting Composio CLI login (approve in the browser that opens)"
  local login_out login_url login_key
  login_out="$(
    limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS' 2>&1 || true
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
cd /tmp
python3 - <<'PY'
import os, pty, select, time, sys
cmd = "composio login --no-browser --no-wait --no-skill-install -y"
pid, fd = pty.fork()
if pid == 0:
    os.environ["PATH"] = "/srv/hermes/.local/bin:/srv/hermes/.composio:" + os.environ.get("PATH", "")
    os.chdir("/tmp")
    os.execvp("bash", ["bash", "-lc", cmd])
end = time.time() + 30
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
os.waitpid(pid, 0)
PY
EOS
  )"
  login_url="$(printf '%s\n' "$login_out" | unwrap_composio_url || true)"
  if [ -z "$login_url" ]; then
    echo "error: could not extract Composio login URL" >&2
    printf '%s\n' "$login_out" >&2
    return 1
  fi
  login_key="$(python3 -c 'import sys,urllib.parse as u; q=u.urlparse(sys.argv[1]).query; print(dict(u.parse_qsl(q)).get("cliKey",""))' "$login_url")"
  if [ -z "$login_key" ]; then
    echo "error: login URL missing cliKey: $login_url" >&2
    return 1
  fi
  open_url_on_host "$login_url"

  echo "==> waiting up to ${login_timeout}s for dashboard approval…"
  if ! limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s -- "$login_key" "$login_timeout" <<'EOS'
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
key="$1"
timeout_s="$2"
cd /tmp
timeout "$timeout_s" composio login --key "$key" --no-skill-install -y
composio whoami >/dev/null
EOS
  then
    echo "error: Composio login timed out or failed — re-run: $0 reauth" >&2
    return 1
  fi
  echo "==> Composio CLI login OK"

  echo "==> linking Twitter (approve X OAuth in the browser that opens)"
  local link_out link_url
  link_out="$(
    limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS' 2>&1 || true
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
cd /tmp
python3 - <<'PY'
import os, pty, select, time, sys
cmd = "composio link twitter --no-wait"
pid, fd = pty.fork()
if pid == 0:
    os.environ["PATH"] = "/srv/hermes/.local/bin:/srv/hermes/.composio:" + os.environ.get("PATH", "")
    os.chdir("/tmp")
    os.execvp("bash", ["bash", "-lc", cmd])
end = time.time() + 45
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
os.waitpid(pid, 0)
PY
EOS
  )"
  link_url="$(printf '%s\n' "$link_out" | unwrap_composio_url || true)"
  if [ -n "$link_url" ]; then
    open_url_on_host "$link_url"
  else
    echo "==> could not extract link URL automatically; raw output follows"
    printf '%s\n' "$link_out"
    echo "==> if a URL is above, open it, then wait — polling for ACTIVE twitter…"
  fi

  echo "==> waiting up to ${link_timeout}s for Twitter ACTIVE…"
  if ! limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s -- "$link_timeout" <<'EOS'
set -eu
export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:$PATH"
deadline=$(( $(date +%s) + $1 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  out="$(composio connections list --toolkit twitter 2>&1 || true)"
  if printf '%s' "$out" | grep -q '"status": "ACTIVE"'; then
    echo "$out" | head -c 500
    echo
    exit 0
  fi
  sleep 3
done
echo "error: Twitter still not ACTIVE" >&2
composio connections list --toolkit twitter 2>&1 || true
exit 1
EOS
  then
    echo "error: Twitter re-link timed out — re-run: $0 reauth" >&2
    return 1
  fi

  echo "==> probing bookmarks"
  test_cli_bookmarks "${COMPOSIO_CLI_TEST_MAX:-5}"
  echo "==> X bookmarks path restored"
}

case "${1:-status}" in
  status)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    echo "==> Composio setup status"
    if has_composio_key; then
      prefix="$(composio_key_prefix)"
      echo "  COMPOSIO_API_KEY: configured (prefix: ${prefix}_)"
      case "${prefix}" in
        ak)
          echo "  recommended path: CLI (ak_ works; MCP will 401)"
          ;;
        ck)
          echo "  recommended path: MCP or CLI"
          ;;
        *)
          echo "  recommended path: set ak_ (CLI) or ck_ (MCP) key via hermes-config.sh"
          ;;
      esac
    else
      echo "  COMPOSIO_API_KEY: missing — run ./scripts/hermes-config.sh"
    fi
    print_cli_status
    print_mcp_status
    ;;
  install-cli)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    if ! has_composio_key; then
      echo "error: COMPOSIO_API_KEY missing — run ./scripts/hermes-config.sh first" >&2
      exit 1
    fi
    prefix="$(composio_key_prefix)"
    echo "==> installing Composio CLI path (key: ${prefix}_)"
    install_fetch_script
    echo "==> disabling MCP block (ak_ keys cannot use connect.composio.dev/mcp)"
    disable_mcp_block
    echo "==> done. Run: ./scripts/hermes-composio-setup.sh test-cli"
    if [ "${prefix}" = "ak" ]; then
      echo "     then: ./scripts/hermes-composio-setup.sh restart  (clears MCP 401 noise in gateway logs)"
    fi
    ;;
  test-cli)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    if ! has_composio_key; then
      echo "error: COMPOSIO_API_KEY missing — run ./scripts/hermes-config.sh first" >&2
      exit 1
    fi
    echo "==> probing Composio CLI (TWITTER_BOOKMARKS_BY_USER)"
    test_cli_bookmarks "${COMPOSIO_CLI_TEST_MAX:-5}"
    ;;
  disable-mcp)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    echo "==> removing Composio MCP block"
    disable_mcp_block
    ;;
  install)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    if ! has_composio_key; then
      echo "error: COMPOSIO_API_KEY not in /srv/hermes/.hermes/.env" >&2
      exit 1
    fi
    require_ck_composio_key || exit 1
    echo "==> installing Composio MCP block"
    install_mcp_block
    echo "==> done. Run ./scripts/hermes-composio-setup.sh restart && test"
    ;;
  test)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    if ! has_composio_key; then
      echo "error: COMPOSIO_API_KEY missing — run ./scripts/hermes-config.sh first" >&2
      exit 1
    fi
    prefix="$(composio_key_prefix)"
    if [ "${prefix}" = "ak" ]; then
      echo "==> ak_ key detected — running CLI test (use install-cli for full setup)"
      test_cli_bookmarks "${COMPOSIO_CLI_TEST_MAX:-5}"
      exit 0
    fi
    require_ck_composio_key || exit 1
    echo "==> probing Composio MCP"
    if ! vm_hermes mcp test "${COMPOSIO_MCP_NAME}"; then
      composio_ck_key_help
      exit 1
    fi
    ;;
  restart)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    echo "==> restarting hermes-gateway"
    "$(dirname "$0")/hermes-gateway.sh" restart
    ;;
  reauth)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    reauth_cli_and_twitter
    ;;
  *)
    echo "usage: $0 {status|reauth|install-cli|test-cli|disable-mcp|install|test|restart}" >&2
    exit 1
    ;;
esac
