#!/usr/bin/env bash
# Query OpenRouter for free tool-capable models (requires OPENROUTER_API_KEY in VM .env).

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- env \
  HOME=/srv/hermes \
  PATH=/srv/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin \
  bash -c '
    API_KEY=$(grep -m1 "^OPENROUTER_API_KEY=" /srv/hermes/.hermes/.env 2>/dev/null | cut -d= -f2-)
    [ -n "$API_KEY" ] || { echo "error: OPENROUTER_API_KEY not set — run hermes-config.sh first" >&2; exit 1; }
    curl -fsSL "https://openrouter.ai/api/v1/models" \
      -H "Authorization: Bearer $API_KEY" \
    | python3 -c "
import sys, json
for m in json.load(sys.stdin)[\"data\"]:
    p = m.get(\"pricing\", {}) or {}
    free = str(p.get(\"prompt\", \"?\")) in (\"0\", \"0.0\") \
        and str(p.get(\"completion\", \"?\")) in (\"0\", \"0.0\")
    if \"tools\" not in (m.get(\"supported_parameters\") or []):
        continue
    if free:
        print(m[\"id\"], m.get(\"context_length\", 0))
"
' </dev/null
