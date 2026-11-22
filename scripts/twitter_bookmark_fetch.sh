#!/usr/bin/env bash
# Fetch Twitter bookmarks via Composio CLI (stdout for Hermes cron / one-shot use).
# Uses ak_ COMPOSIO_API_KEY from .env — no MCP / ck_ key required.
set -eu

export PATH="/srv/hermes/.local/bin:/srv/hermes/.composio:${PATH:-/usr/local/bin:/usr/bin:/bin}"

ENV_FILE="${HERMES_ENV_FILE:-/srv/hermes/.hermes/.env}"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

WANT="${1:-${COMPOSIO_BOOKMARK_MAX:-15}}"
PAGE_SIZE="${COMPOSIO_BOOKMARK_PAGE_SIZE:-50}"

if ! command -v composio >/dev/null 2>&1; then
  echo "error: composio CLI not found in PATH" >&2
  exit 1
fi

if [ -z "${COMPOSIO_API_KEY:-}" ]; then
  echo "error: COMPOSIO_API_KEY missing from ${ENV_FILE}" >&2
  exit 1
fi

/srv/hermes/.hermes/venv/bin/python3 - "$WANT" "$PAGE_SIZE" <<'PY'
import json
import subprocess
import sys

want = max(1, int(sys.argv[1]))
page_size = min(50, max(1, int(sys.argv[2])))

all_items = []
token = None

while len(all_items) < want:
    batch = min(page_size, want - len(all_items))
    payload = {
        "max_results": batch,
        "tweet_fields": ["created_at", "text", "author_id"],
    }
    if token:
        payload["pagination_token"] = token

    proc = subprocess.run(
        ["composio", "execute", "TWITTER_BOOKMARKS_BY_USER", "-d", json.dumps(payload)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        print(proc.stderr or proc.stdout, file=sys.stderr)
        sys.exit(proc.returncode or 1)

    data = json.loads(proc.stdout)
    if not data.get("successful"):
        print(json.dumps(data, indent=2))
        sys.exit(1)

    body = data.get("data") or {}
    items = body.get("data") or []
    meta = body.get("meta") or {}
    all_items.extend(items)
    token = meta.get("next_token")

    if not items or not token:
        break

print(json.dumps({
    "successful": True,
    "data": {
        "data": all_items[:want],
        "meta": {
            "result_count": min(len(all_items), want),
            "fetched_pages": None,
            "truncated": len(all_items) >= want and bool(token),
            "next_token": token if len(all_items) >= want else None,
        },
    },
    "error": None,
}, indent=2))
PY
