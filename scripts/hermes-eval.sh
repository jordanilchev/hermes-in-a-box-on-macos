#!/usr/bin/env bash
# Complete Hermes runtime eval for hermes-in-a-box-on-macos.
#
# Usage:
#   ./scripts/hermes-eval.sh              # full suite
#   ./scripts/hermes-eval.sh --quick      # skip long LLM + verify.sh
#   ./scripts/hermes-eval.sh --no-llm     # skip chat smoke
#   ./scripts/hermes-eval.sh --with-hardening  # also run scripts/verify.sh
#
# Exit 0 only if every selected check passes. Prints a scoreboard at the end.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl
require_cmd curl
require_cmd python3

QUICK=0
NO_LLM=0
WITH_HARDENING=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1; NO_LLM=1 ;;
    --no-llm) NO_LLM=1 ;;
    --with-hardening) WITH_HARDENING=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

: "${AI_BUBBLE_PORT:=8765}"
: "${EXPECT_VERSION:=${HERMES_VERSION}}"
# If the shell already had an older HERMES_VERSION exported, prefer the pin in env.sh.
_env_pin="$(grep -E '^: "\$\{HERMES_VERSION:=' "${HERMES_VM_REPO}/scripts/env.sh" | sed -E 's/.*HERMES_VERSION:=([^}]+)}.*/\1/' || true)"
if [ -n "${_env_pin}" ]; then
  EXPECT_VERSION="${_env_pin}"
fi
_env_git="$(grep -E '^: "\$\{HERMES_GIT_REF:=' "${HERMES_VM_REPO}/scripts/env.sh" | sed -E 's/.*HERMES_GIT_REF:=([^}]+)}.*/\1/' || true)"
if [ -n "${_env_git}" ]; then
  HERMES_GIT_REF="${_env_git}"
fi

shell() { limactl shell "${HERMES_VM_NAME}" -- "$@"; }
as_hermes() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes env \
    HOME=/srv/hermes \
    PATH=/srv/hermes/.hermes/venv/bin:/srv/hermes/.local/bin:/usr/bin:/bin \
    "$@"
}

fail=0
pass_n=0
fail_n=0
skip_n=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; pass_n=$((pass_n + 1)); }
miss() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; fail=1; fail_n=$((fail_n + 1)); }
skip() { printf "  \033[33mSKIP\033[0m %s\n" "$*"; skip_n=$((skip_n + 1)); }

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

echo "Hermes eval — expect version ~${EXPECT_VERSION} (git ref ${HERMES_GIT_REF:-none})"
echo

echo "== 1. VM lifecycle =="
if vm_running; then
  pass "VM ${HERMES_VM_NAME} Running"
else
  miss "VM ${HERMES_VM_NAME} not Running"
  echo "Cannot continue without VM." >&2
  exit 1
fi

echo "== 2. Hermes package / CLI =="
ver_out="$(as_hermes hermes --version 2>/dev/null || true)"
if [ -z "${ver_out}" ]; then
  miss "hermes --version failed"
else
  pass "hermes CLI responds"
  printf "       %s\n" "$(echo "${ver_out}" | head -1)"
  if echo "${ver_out}" | grep -qE "v?${EXPECT_VERSION}|${EXPECT_VERSION}"; then
    pass "version matches expect ${EXPECT_VERSION}"
  else
    # Allow git installs that report calendar stamp but still show package version nearby
    pkg_ver="$(as_hermes bash -lc 'python3 -c "import importlib.metadata as m; print(m.version(\"hermes-agent\"))" 2>/dev/null' || true)"
    if [ "${pkg_ver}" = "${EXPECT_VERSION}" ]; then
      pass "package hermes-agent==${pkg_ver}"
    else
      miss "version mismatch (cli/package='${pkg_ver:-unknown}', expect ${EXPECT_VERSION})"
      printf "       cli:\n%s\n" "${ver_out}" | sed 's/^/       /'
    fi
  fi
fi

echo "== 3. Gateway =="
gw="$(as_hermes bash -lc 'systemctl --user is-active hermes-gateway.service 2>/dev/null || true')"
# gateway is system unit, not user
gw_sys="$(shell systemctl is-active hermes-gateway.service 2>/dev/null || true)"
if [ "${gw_sys}" = "active" ]; then
  pass "hermes-gateway.service active"
else
  miss "hermes-gateway.service not active (${gw_sys:-unknown})"
fi
unit="$(shell cat /etc/systemd/system/hermes-gateway.service 2>/dev/null || true)"
if printf '%s\n' "${unit}" | grep -q 'XDG_RUNTIME_DIR=/run/user/999' && ! printf '%s\n' "${unit}" | grep -q '%U'; then
  pass "gateway unit hardened (UID 999, no %U)"
else
  miss "gateway unit missing hardened XDG_RUNTIME_DIR / still has %U"
fi

echo "== 4. Config: Docker skill mounts =="
cfg_check="$(as_hermes bash -lc 'python3 - <<PY
from pathlib import Path
import yaml
c=yaml.safe_load(Path("/srv/hermes/.hermes/config.yaml").read_text()) or {}
vols=list((c.get("terminal") or {}).get("docker_volumes") or [])
need="/srv/hermes/.hermes/skills:/srv/hermes/.hermes/skills:ro"
print("OK" if need in vols else "MISSING")
print("backend="+str((c.get("terminal") or {}).get("backend")))
for v in vols:
    print("vol:"+v)
PY')"
if echo "${cfg_check}" | grep -qx "OK"; then
  pass "terminal.docker_volumes mounts skills at /srv/hermes/.hermes/skills"
else
  miss "skills not in terminal.docker_volumes"
  echo "${cfg_check}" | sed 's/^/       /'
fi
if echo "${cfg_check}" | grep -q 'backend=docker'; then
  pass "terminal.backend=docker"
else
  miss "terminal.backend is not docker"
fi

echo "== 5. Skills present =="
for skill in \
  /srv/hermes/.hermes/skills/media/youtube-content/SKILL.md \
  /srv/hermes/.hermes/skills/media/youtube-content/scripts/fetch_transcript.py \
  /srv/hermes/.hermes/skills/productivity/dreamer/SKILL.md \
  /srv/hermes/.hermes/skills/productivity/research-teachable/SKILL.md \
  /srv/hermes/.hermes/scripts/research_teachable_finisher.py
do
  if as_hermes test -f "${skill}"; then
    pass "exists ${skill#/srv/hermes/.hermes/}"
  else
    miss "missing ${skill}"
  fi
done
if as_hermes hermes skills list 2>/dev/null | grep -qi 'youtube-content'; then
  pass "skills list includes youtube-content"
else
  miss "skills list missing youtube-content"
fi
if as_hermes hermes skills list 2>/dev/null | grep -qi 'dreamer'; then
  pass "skills list includes dreamer"
else
  miss "skills list missing dreamer"
fi
if as_hermes hermes skills list 2>/dev/null | grep -qi 'research-teachable'; then
  pass "skills list includes research-teachable"
else
  miss "skills list missing research-teachable"
fi
if as_hermes bash -lc 'python3 - <<"PY"
import json
from pathlib import Path
p = Path("/srv/hermes/.hermes/.skills_prompt_snapshot.json")
if not p.is_file():
    raise SystemExit(2)
d = json.loads(p.read_text())
names = [s.get("skill_name","") for s in (d.get("skills") or [])]
raise SystemExit(0 if "research-teachable" in names else 1)
PY'; then
  pass "skills prompt snapshot includes research-teachable"
else
  miss "skills prompt snapshot missing research-teachable (redeploy finish skill / restart gateway)"
fi
if as_hermes bash -lc 'python3 /srv/hermes/.hermes/scripts/research_teachable_finisher.py --help >/dev/null'; then
  pass "research_teachable_finisher.py --help"
else
  miss "research_teachable_finisher.py not runnable"
fi
if as_hermes bash -lc 'rg -q "research-teachable|research_teachable_finisher" /srv/hermes/.hermes/AGENTS.md'; then
  pass "AGENTS.md documents research-teachable"
else
  miss "AGENTS.md missing research-teachable docs"
fi

echo "== 6. YouTube helper runnable (host venv) =="
if as_hermes bash -lc 'python3 -c "from youtube_transcript_api import YouTubeTranscriptApi"'; then
  pass "youtube_transcript_api importable in hermes env"
else
  miss "youtube_transcript_api missing (pip install in hermes venv)"
fi
if as_hermes bash -lc 'python3 /srv/hermes/.hermes/skills/media/youtube-content/scripts/fetch_transcript.py --help >/dev/null'; then
  pass "fetch_transcript.py --help"
else
  miss "fetch_transcript.py failed"
fi

echo "== 7. Research / bubble brief artifacts =="
for f in \
  /srv/hermes/.hermes/research/ai-bubble-early-warning-system.md \
  /srv/hermes/.hermes/research/ai-bubble-early-warning-siazPdsZHuI.txt
do
  if as_hermes test -s "${f}"; then
    pass "artifact $(basename "${f}")"
  else
    miss "missing/empty ${f}"
  fi
done

echo "== 8. AI bubble dashboard (Mac localhost) =="
if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${AI_BUBBLE_PORT}/"; then
  pass "dashboard HTTP 200 on :${AI_BUBBLE_PORT}"
  title="$(curl -fsS --max-time 3 "http://127.0.0.1:${AI_BUBBLE_PORT}/" | python3 -c 'import sys,re; m=re.search(r"<title>([^<]+)</title>", sys.stdin.read()); print(m.group(1) if m else "")')"
  if echo "${title}" | grep -qiE 'AI Bubble Early Warning'; then
    pass "dashboard title ok (${title})"
  else
    miss "unexpected dashboard title '${title}'"
  fi
else
  miss "dashboard not reachable at http://127.0.0.1:${AI_BUBBLE_PORT}/ (run ./scripts/ai-bubble-dashboard.sh start)"
fi
if [ -f "${HERMES_VM_REPO}/scripts/ai-bubble-dashboard/index.html" ]; then
  pass "dashboard index.html in repo"
else
  miss "dashboard index.html missing from repo"
fi

echo "== 9. LLM smoke =="
if [ "${NO_LLM}" -eq 1 ]; then
  skip "LLM chat (--quick/--no-llm)"
else
  # Non-interactive one-shot with hard timeout (local Gemma can be slow to load).
  set +e
  out="$(as_hermes bash -lc 'timeout 120 hermes chat -Q -q "Reply with exactly: EVAL_OK" 2>/dev/null' 2>/dev/null)"
  chat_rc=$?
  set -e
  if [ "${chat_rc}" -eq 0 ] && echo "${out}" | grep -qiE 'EVAL_OK|ok|hello|hermes|ready'; then
    pass "hermes chat -Q smoke responded"
  elif shell curl -fsS --max-time 5 "http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/api/tags" >/dev/null 2>&1; then
    if [ "${chat_rc}" -eq 124 ]; then
      miss "hermes chat smoke timed out after 120s (Ollama reachable — check model load/routing)"
    else
      miss "hermes chat smoke weak/empty, but Ollama reachable — check model routing"
    fi
    printf "       out: %s\n" "$(echo "${out}" | tr '\n' ' ' | head -c 200)"
  else
    miss "hermes chat smoke failed and Ollama unreachable at ${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}"
  fi
fi

echo "== 10. Rootless Docker =="
if shell sudo -iu hermes docker info >/dev/null 2>&1; then
  if shell sudo -iu hermes docker info 2>/dev/null | grep -qi rootless; then
    pass "rootless dockerd for hermes"
  else
    miss "dockerd reachable but not rootless"
  fi
else
  miss "hermes rootless dockerd not reachable"
fi

echo "== 11. AGENTS.md skill-path guidance =="
if as_hermes grep -q 'Skill helper scripts in Docker' /srv/hermes/AGENTS.md 2>/dev/null; then
  pass "AGENTS.md documents Docker skill paths"
else
  miss "AGENTS.md missing Docker skill-path guidance"
fi

if [ "${WITH_HARDENING}" -eq 1 ]; then
  echo "== 12. Hardening suite (verify.sh) =="
  if "$(dirname "$0")/verify.sh"; then
    pass "verify.sh all checks passed"
  else
    miss "verify.sh reported failures"
  fi
elif [ "${QUICK}" -eq 1 ]; then
  skip "hardening verify.sh (--quick)"
else
  skip "hardening verify.sh (pass --with-hardening to include)"
fi

echo
echo "Scoreboard: ${pass_n} pass / ${fail_n} fail / ${skip_n} skip"
if [ "${fail}" -eq 0 ]; then
  echo "all selected eval checks passed"
  exit 0
fi
echo "FAILED eval checks above" >&2
exit 1
