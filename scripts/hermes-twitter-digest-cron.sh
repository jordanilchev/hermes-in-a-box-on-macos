#!/usr/bin/env bash
# Install or manage the daily Twitter bookmark digest cron job in Hermes.
#
# Prerequisites:
#   - Composio CLI logged in inside the VM (composio login)
#   - Twitter linked (composio link twitter)
#   - Hermes gateway running (scheduler lives in gateway)
#   - SLACK_HOME_CHANNEL set in /srv/hermes/.hermes/.env
#
# Usage:
#   ./scripts/hermes-twitter-digest-cron.sh install
#   ./scripts/hermes-twitter-digest-cron.sh status
#   ./scripts/hermes-twitter-digest-cron.sh run      # trigger on next tick
#   ./scripts/hermes-twitter-digest-cron.sh test     # run job now (one-shot)

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

JOB_NAME="${HERMES_TWITTER_DIGEST_NAME:-Twitter Bookmark Digest}"
SCHEDULE="${HERMES_TWITTER_DIGEST_SCHEDULE:-0 8 * * *}"
SCRIPT_NAME="twitter_bookmark_fetch.sh"
HOST_SCRIPT="$(dirname "$0")/${SCRIPT_NAME}"

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

vm_hermes() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -lc '"$HOME/.local/bin/hermes" "$@"' hermes "$@"
}

slack_deliver_target() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s <<'EOS'
set -a
source /srv/hermes/.hermes/.env
set +a
if [ -z "${SLACK_HOME_CHANNEL:-}" ]; then
  echo "error: SLACK_HOME_CHANNEL missing in .env" >&2
  exit 1
fi
echo "slack:${SLACK_HOME_CHANNEL}"
EOS
}

install_script() {
  if [ ! -f "${HOST_SCRIPT}" ]; then
    echo "error: missing ${HOST_SCRIPT}" >&2
    exit 1
  fi
  limactl copy "${HOST_SCRIPT}" "${HERMES_VM_NAME}:/tmp/${SCRIPT_NAME}"
  limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<EOS
set -eu
install -d -m 0755 /srv/hermes/.hermes/scripts
install -m 0755 "/tmp/${SCRIPT_NAME}" "/srv/hermes/.hermes/scripts/${SCRIPT_NAME}"
chown hermes:hermes "/srv/hermes/.hermes/scripts/${SCRIPT_NAME}"
rm -f "/tmp/${SCRIPT_NAME}"
EOS
}

job_exists() {
  vm_hermes cron list 2>/dev/null | grep -q "${JOB_NAME}"
}

create_job() {
  deliver="$(slack_deliver_target)"
  limactl shell "${HERMES_VM_NAME}" -- sudo -iu hermes -- bash -s \
    -- "${SCHEDULE}" "${JOB_NAME}" "${deliver}" "${SCRIPT_NAME}" <<'EOS'
set -eu
schedule="$1"
job_name="$2"
deliver="$3"
script_name="$4"
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' EXIT
cat >"$prompt_file" <<'PROMPT'
You are running the daily Twitter Bookmark Digest cron job.

The script output below contains up to 15 recent Twitter bookmarks (JSON from Composio).

Tasks:
1. Read the bookmark data from the script output.
2. Check Hermes memory for prior bookmark digest runs and topics already covered.
3. Identify bookmarks that are NEW since the last digest (by tweet id or content).
4. For each new bookmark, extract: topic, one-line insight, and why it might matter to Jordan.
5. Save structured summaries to memory grouped by theme (AI agents, hardware, markets, science, culture, etc.).
6. Compose a concise Slack digest:
   - Title line: "Twitter Bookmark Digest — {date}"
   - If no new bookmarks: say so in one line and stop
   - Otherwise: group by theme, one bullet per new bookmark
   - Keep under ~25 lines unless unusually busy
7. Do not ask questions. Do not request approval for read-only terminal/memory work.

Jordan's interests: AI agents, local inference hardware, security/isolation, markets/space, physics demos, engineering curiosities.
PROMPT
"$HOME/.local/bin/hermes" cron create "$schedule" \
  "$(cat "$prompt_file")" \
  --name "$job_name" \
  --deliver "$deliver" \
  --script "$script_name"
EOS
}

case "${1:-status}" in
  install)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
      exit 1
    fi
    install_script
    if job_exists; then
      echo "cron job already exists: ${JOB_NAME}"
      echo "remove it first with: ./scripts/hermes.sh cron remove <id>"
      exit 0
    fi
    echo "==> creating cron job: ${JOB_NAME} (${SCHEDULE})"
    create_job
    echo "==> done"
    vm_hermes cron list
    ;;
  status)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running." >&2
      exit 1
    fi
    vm_hermes cron list
    ;;
  run)
    vm_hermes cron run "${JOB_NAME}" 2>/dev/null || vm_hermes cron list
    ;;
  test)
    if ! vm_running; then
      echo "VM ${HERMES_VM_NAME} is not running." >&2
      exit 1
    fi
    install_script
    id="$(vm_hermes cron list 2>/dev/null | awk -v n="${JOB_NAME}" '$0 ~ n {print $1; exit}')"
    if [ -z "${id}" ]; then
      echo "job not found — run ./scripts/hermes-twitter-digest-cron.sh install first" >&2
      exit 1
    fi
    echo "==> running job ${id} now (may take several minutes)..."
    vm_hermes cron tick 2>&1 || true
    ;;
  *)
    echo "usage: $0 {install|status|run|test}" >&2
    exit 1
    ;;
esac
