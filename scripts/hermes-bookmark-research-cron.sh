#!/usr/bin/env bash
# Install/manage the bookmark research loop cron (no-agent, host-side script).
#
# Prerequisites:
#   - twitter_bookmark_fetch.sh deployed (hermes-composio-setup.sh install-cli)
#   - Composio CLI + Twitter linked in VM
#   - Hermes gateway running
#
# Usage:
#   ./scripts/hermes-bookmark-research-cron.sh install
#   ./scripts/hermes-bookmark-research-cron.sh status
#   ./scripts/hermes-bookmark-research-cron.sh test

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

JOB_NAME="${HERMES_BOOKMARK_RESEARCH_NAME:-Bookmark Research Loop}"
SCHEDULE="${HERMES_BOOKMARK_RESEARCH_SCHEDULE:-0 * * * *}"
SCRIPT_NAME="bookmark_research_loop.py"
HOST_SCRIPT="$(dirname "$0")/${SCRIPT_NAME}"
FETCH_SCRIPT="$(dirname "$0")/twitter_bookmark_fetch.sh"

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

vm_hermes() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -lc '"$HOME/.local/bin/hermes" "$@"' hermes "$@"
}

FINISH_SCRIPT="$(dirname "$0")/research_teachable_finisher.py"
FINISH_NAME="research_teachable_finisher.py"
SKILL_SRC="$(dirname "$0")/skills/research-teachable"

install_scripts() {
  for src in "${HOST_SCRIPT}" "${FETCH_SCRIPT}" "${FINISH_SCRIPT}"; do
    base="$(basename "$src")"
    if [ ! -f "$src" ]; then
      echo "error: missing ${src}" >&2
      exit 1
    fi
    limactl copy "$src" "${HERMES_VM_NAME}:/tmp/${base}"
  done
  limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<EOS
set -eu
install -d -m 0755 /srv/hermes/.hermes/scripts
install -d -m 0755 -o hermes -g hermes /srv/hermes/.hermes/research
for f in ${SCRIPT_NAME} twitter_bookmark_fetch.sh ${FINISH_NAME}; do
  install -m 0755 "/tmp/\$f" "/srv/hermes/.hermes/scripts/\$f"
  chown hermes:hermes "/srv/hermes/.hermes/scripts/\$f"
  rm -f "/tmp/\$f"
done
EOS
  install_skill
}

install_skill() {
  if [ ! -f "${SKILL_SRC}/SKILL.md" ]; then
    echo "warn: missing skill at ${SKILL_SRC}/SKILL.md" >&2
    return 0
  fi
  limactl copy "${SKILL_SRC}/SKILL.md" "${HERMES_VM_NAME}:/tmp/research-teachable-SKILL.md"
  limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'EOS'
set -eu
install -d -m 0755 -o hermes -g hermes /srv/hermes/.hermes/skills/productivity/research-teachable
install -m 0644 /tmp/research-teachable-SKILL.md \
  /srv/hermes/.hermes/skills/productivity/research-teachable/SKILL.md
chown -R hermes:hermes /srv/hermes/.hermes/skills/productivity/research-teachable
rm -f /tmp/research-teachable-SKILL.md
# Drop stale prompt snapshot so gateway/agent re-index includes the new skill.
rm -f /srv/hermes/.hermes/.skills_prompt_snapshot.json
EOS
  # Rebuild snapshot as hermes (so list/prompt see research-teachable immediately).
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes env \
    HOME=/srv/hermes \
    PATH=/srv/hermes/.hermes/venv/bin:/usr/bin:/bin \
    python3 - <<'PY'
import os, sys
sys.path.insert(0, "/srv/hermes/.hermes/hermes-agent")
os.chdir("/srv/hermes/.hermes/hermes-agent")
from agent.prompt_builder import clear_skills_system_prompt_cache, build_skills_system_prompt
clear_skills_system_prompt_cache(clear_snapshot=True)
prompt = build_skills_system_prompt()
ok = "research-teachable" in prompt.lower()
print(f"skills prompt rebuilt; research-teachable={'yes' if ok else 'MISSING'}")
raise SystemExit(0 if ok else 1)
PY
}

patch_docker_script_mount() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
    /srv/hermes/.hermes/venv/bin/python3 <<'PY'
from pathlib import Path
import yaml

config_path = Path("/srv/hermes/.hermes/config.yaml")
config = yaml.safe_load(config_path.read_text()) or {}
term = config.setdefault("terminal", {})
mounts = [
    "/srv/hermes/.hermes/scripts:/srv/hermes/.hermes/scripts:ro",
    "/srv/hermes/.hermes/research:/srv/hermes/.hermes/research:ro",
    "/srv/hermes/.hermes/skills:/srv/hermes/.hermes/skills:ro",
]
vols = list(term.get("docker_volumes") or [])
for mount in mounts:
    if mount not in vols:
        vols.append(mount)
term["docker_volumes"] = vols
config_path.write_text(yaml.safe_dump(config, sort_keys=False, default_flow_style=False))
print(f"terminal.docker_volumes: {vols}")
PY
}

job_exists() {
  vm_hermes cron list 2>/dev/null | grep -q "${JOB_NAME}"
}

create_job() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s \
    -- "${SCHEDULE}" "${JOB_NAME}" "${SCRIPT_NAME}" <<'EOS'
set -eu
schedule="$1"
job_name="$2"
script_name="$3"
"$HOME/.local/bin/hermes" cron create "$schedule" \
  --name "$job_name" \
  --deliver local \
  --script "$script_name" \
  --no-agent
EOS
}

case "${1:-status}" in
  install)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    install_scripts
    patch_docker_script_mount
    if job_exists; then
      echo "cron job already exists: ${JOB_NAME}"
      vm_hermes cron list | grep -F "${JOB_NAME}" || true
      exit 0
    fi
    echo "==> creating cron job: ${JOB_NAME} (${SCHEDULE}, no-agent)"
    create_job
    echo "==> restarting gateway (docker volume mount)"
    "$(dirname "$0")/hermes-gateway.sh" restart 2>/dev/null || true
    echo "==> done"
    vm_hermes cron list
    ;;
  status)
    vm_running || { echo "VM not running" >&2; exit 1; }
    vm_hermes cron list | grep -F "${JOB_NAME}" || vm_hermes cron list
    ;;
  test)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running." >&2
      exit 1
    fi
    install_scripts
    echo "==> running ${SCRIPT_NAME} once on VM host..."
    limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
      /srv/hermes/.hermes/venv/bin/python3 "/srv/hermes/.hermes/scripts/${SCRIPT_NAME}"
    ;;
  finish)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running." >&2
      exit 1
    fi
    install_scripts
    shift || true
    # Convenience: `finish 25` → `--limit 25`
    if [ "${1:-}" = "" ]; then
      set -- --limit 10
    elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
      set -- --limit "$1" "${@:2}"
    fi
    echo "==> running ${FINISH_NAME} on VM host..."
    limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- \
      /srv/hermes/.hermes/venv/bin/python3 \
      "/srv/hermes/.hermes/scripts/${FINISH_NAME}" "$@"
    ;;
  *)
    echo "usage: $0 {install|status|test|finish [N|--limit N|--dry-run|--file PATH]}" >&2
    exit 1
    ;;
esac
