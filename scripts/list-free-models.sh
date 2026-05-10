#!/usr/bin/env bash
set -euo pipefail

export HERMES_VM_HOME=/Volumes/DATA/hermes-vm
export LIMA_HOME=/Volumes/DATA/hermes-vm/lima

limactl shell ubuntu-hermes -- sudo runuser -u hermes -- env \
  HOME=/srv/hermes \
  PATH=/srv/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin \
  bash -c '
    curl -fsSL "https://openrouter.ai/api/v1/models" \
      -H "Authorization: Bearer $(grep -m1 OPENROUTER_API_KEY /srv/hermes/.hermes/.env | cut -d= -f2-)" \
    | python3 -c "
import sys, json
for m in json.load(sys.stdin)[\"data\"]:
    p = m.get(\"pricing\", {}) or {}
    free = p.get(\"prompt\") in (\"0\", 0, \"0.0\") and p.get(\"completion\") in (\"0\", 0, \"0.0\")
    has_tools = \"tools\" in (m.get(\"supported_parameters\") or [])
    if free and has_tools:
        print(m[\"id\"], m.get(\"context_length\", 0))
"
  '
