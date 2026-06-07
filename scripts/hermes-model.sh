#!/usr/bin/env bash
# Select the default model and up to 3 ordered fallbacks from OpenRouter.
#
# Display order: FREE tool-capable models first, then PAID grouped by provider.
# Writes model.default and fallback_providers surgically into config.yaml
# (same pattern as hermes-config.sh — direct file edit, not `hermes config set`,
# because the set command can't write list-of-objects values non-interactively
# and `hermes fallback add` has no CLI flags).
#
# Offers to restart hermes-gateway if it is currently active.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

# ── Fetch models from OpenRouter (inside VM where the API key lives) ──────────
echo "Fetching OpenRouter models (tool-capable only)..." >&2

# Tab-separated output: tier<TAB>model_id<TAB>ctx_label
# Sorted: FREE first (by model_id), then PAID by provider then model_id.
# </dev/null keeps limactl from consuming the host stdin that read prompts need.
MODELS_RAW=$(limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- env \
  HOME=/srv/hermes \
  PATH=/srv/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin \
  bash -c '
    API_KEY=$(grep -m1 "^OPENROUTER_API_KEY=" /srv/hermes/.hermes/.env 2>/dev/null | cut -d= -f2-)
    [ -n "$API_KEY" ] || { echo "error: OPENROUTER_API_KEY not set — run hermes-config.sh first" >&2; exit 1; }
    curl -fsSL "https://openrouter.ai/api/v1/models" \
      -H "Authorization: Bearer $API_KEY" \
    | python3 -c "
import sys, json
rows = []
for m in json.load(sys.stdin)[\"data\"]:
    p = m.get(\"pricing\", {}) or {}
    free = str(p.get(\"prompt\",  \"?\")) in (\"0\", \"0.0\") \
        and str(p.get(\"completion\", \"?\")) in (\"0\", \"0.0\")
    if \"tools\" not in (m.get(\"supported_parameters\") or []):
        continue
    mid  = m[\"id\"]
    ctx  = m.get(\"context_length\", 0) or 0
    prov = mid.split(\"/\")[0] if \"/\" in mid else \"unknown\"
    tier = \"FREE\" if free else \"PAID\"
    ctx_k = ctx // 1000
    ctx_label = f\"{ctx_k // 1000}M\" if ctx_k >= 1000 else (f\"{ctx_k}k\" if ctx_k else \"?\")
    rows.append((0 if free else 1, prov, mid, tier, ctx_label))
rows.sort()
for _, _, mid, tier, ctx_label in rows:
    print(f\"{tier}\t{mid}\t{ctx_label}\")
"
' </dev/null) || { echo "error: failed to fetch models from OpenRouter" >&2; exit 1; }

[ -n "$MODELS_RAW" ] || { echo "error: API returned no tool-capable models" >&2; exit 1; }

# ── Display numbered list ─────────────────────────────────────────────────────
declare -a IDS=()
count=0
cur_section=""
cur_provider=""

while IFS=$'\t' read -r tier mid ctx_label; do
    count=$((count + 1))
    IDS[$count]="$mid"
    provider="${mid%%/*}"

    if [ "$tier" != "$cur_section" ]; then
        cur_section="$tier"
        cur_provider=""
        if [ "$tier" = "FREE" ]; then
            printf "\n=== FREE (tool-capable) ===\n"
        else
            printf "\n=== PAID ===\n"
        fi
    fi

    if [ "$tier" = "PAID" ] && [ "$provider" != "$cur_provider" ]; then
        cur_provider="$provider"
        printf "  [%s]\n" "$provider"
    fi

    printf "  %4d. %-55s  %s\n" "$count" "$mid" "$ctx_label"
done <<< "$MODELS_RAW"

printf "\n"

# ── Pick default model ─────────────────────────────────────────────────────────
while true; do
    read -rp "Default model (1-${count}): " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] && break
    printf "  Please enter a number between 1 and %d.\n" "$count" >&2
done
DEFAULT_MODEL="${IDS[$pick]}"
printf "  default → %s\n" "$DEFAULT_MODEL"

# ── Pick up to 3 fallbacks ────────────────────────────────────────────────────
declare -a FALLBACKS=()
for slot in 1 2 3; do
    printf "\n"
    read -rp "Fallback #${slot} (1-${count}, or Enter to finish): " pick
    [ -z "$pick" ] && break
    if ! ([[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ]); then
        printf "  Invalid — stopping fallback selection.\n" >&2
        break
    fi
    fb="${IDS[$pick]}"
    if [ "$fb" = "$DEFAULT_MODEL" ]; then
        printf "  Same as default — skipping.\n" >&2; continue
    fi
    for existing in "${FALLBACKS[@]:-}"; do
        [ "$existing" = "$fb" ] && { printf "  Already selected — skipping.\n" >&2; continue 2; }
    done
    FALLBACKS+=("$fb")
    printf "  fallback #%d → %s\n" "$slot" "$fb"
done

# ── Write to config.yaml (surgical Python replacement, preserves all comments) ─
printf "\nWriting config.yaml..."

FB_STR=""
[ "${#FALLBACKS[@]}" -gt 0 ] && FB_STR=$(IFS='|'; echo "${FALLBACKS[*]}")

# Base64-encode the Python script so it can be passed as an env var and decoded
# inside the VM. This avoids feeding it via stdin, which would race the limactl
# shell's own stdin handling and corrupt the interactive read prompts above.
PY_B64=$(base64 <<'PYEOF'
import os, re

config_path = os.path.expanduser("~/.hermes/config.yaml")
new_default  = os.environ["HERMES_NEW_DEFAULT"]
fb_str       = os.environ.get("HERMES_FALLBACKS", "")
fallbacks    = [f for f in fb_str.split("|") if f]

with open(config_path) as fh:
    content = fh.read()

# Update model.default inside the model: block (count=1 to touch only the first
# occurrence; anchored so it won't match a hypothetical nested "default:" key).
content = re.sub(
    r'^(  default: )\S[^\n]*',
    lambda m: m.group(1) + new_default,
    content, count=1, flags=re.MULTILINE
)

# Replace the entire fallback_providers block. Handles both the compact form
# (fallback_providers: []) and the multi-line list written by this script.
# The lookahead (?=^\S|\Z) stops at the next top-level key or end-of-file,
# so all comments above and below are preserved.
if fallbacks:
    entries = "\n".join(
        f"- provider: openrouter\n  model: {m}" for m in fallbacks
    )
    new_block = f"fallback_providers:\n{entries}"
else:
    new_block = "fallback_providers: []"

content = re.sub(
    r'^fallback_providers:.*?(?=^[a-zA-Z~_]|\Z)',
    new_block + "\n",
    content, flags=re.MULTILINE | re.DOTALL
)

tmp = config_path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(content)
os.rename(tmp, config_path)

nfb = len(fallbacks)
print(f"done  (default={new_default}, {nfb} fallback{'s' if nfb != 1 else ''})")
PYEOF
)

result=$(limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- env \
  HOME=/srv/hermes \
  HERMES_NEW_DEFAULT="$DEFAULT_MODEL" \
  HERMES_FALLBACKS="$FB_STR" \
  HERMES_PY_B64="$PY_B64" \
  bash -c 'echo "$HERMES_PY_B64" | base64 -d | python3 -' </dev/null)

printf " %s\n" "$result"

# ── Offer gateway restart ──────────────────────────────────────────────────────
gw_active=$(limactl shell "${HERMES_VM_NAME}" -- \
  sudo systemctl is-active hermes-gateway.service 2>/dev/null </dev/null || true)
if [ "$gw_active" = "active" ]; then
    printf "\n"
    read -rp "hermes-gateway is running — restart to apply changes? [Y/n] " ans || ans="Y"
    case "${ans:-Y}" in
        [Yy]|"")
            limactl shell "${HERMES_VM_NAME}" -- \
              sudo systemctl restart hermes-gateway.service </dev/null
            echo "hermes-gateway restarted." ;;
        *)
            echo "Skipped. Run:  ./scripts/hermes-gateway.sh restart" ;;
    esac
fi
