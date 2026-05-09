#!/usr/bin/env bash
# Prompt for an API key name and value, store in /srv/hermes/.hermes/.env.
#
# Why .env directly, not `hermes config set`:
# Hermes splits state across two files — config.yaml (non-secret runtime
# config: model, terminal backend, personalities) and .env (secrets:
# OPENROUTER_API_KEY, etc.). `hermes config set` writes everything to
# config.yaml indiscriminately, including obvious secrets, which then
# never get picked up by the runtime (it reads keys from .env per
# `hermes config env-path`). Earlier wrappers used `config set` and
# silently stranded keys in the wrong file.
#
# Value path: host stdin → outer-bash (root, in VM) read → here-string
# → inner-bash (hermes) read → idempotent upsert into .env. Value never
# enters argv at any hop.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

read -rp "API key name [OPENROUTER_API_KEY]: " name
name="${name:-OPENROUTER_API_KEY}"
read -rsp "Value for ${name}: " value
echo
[ -n "${value}" ] || { echo "empty value, aborting" >&2; exit 1; }

# Defense-in-depth: env var names are ASCII identifiers. Reject anything
# weirder before sending it through the heredoc, where weird chars could
# break the regex used to find existing lines.
case "${name}" in
  ''|*[!A-Za-z0-9_]*) echo "invalid env-var name: ${name}" >&2; exit 1 ;;
esac

# Pass the script via `bash -c "$script"` (argv) so stdin stays free
# for the value. Piping the script on stdin would race the value: bash
# block-buffers stdin while parsing (~4 KB on a pipe), and a downstream
# `read` would either grab nothing or execute the value as a command.
quoted_name=$(printf '%q' "$name")
script=$(cat <<EOS
set -eu
read -r v
HERMES_UID=\$(id -u hermes)
runuser -u hermes -- env \\
  HOME=/srv/hermes \\
  XDG_RUNTIME_DIR=/run/user/\$HERMES_UID \\
  HERMES_KEY_NAME=${quoted_name} \\
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
  bash -c '
set -eu
read -r v
ENV_FILE="\$HOME/.hermes/.env"
[ -f "\$ENV_FILE" ] || { echo ".env missing — run hermes-install.sh first" >&2; exit 1; }
# Idempotent upsert: drop any existing (commented or live) line for this
# key, then append a fresh KEY=value. mv is atomic on the same FS, so
# .env is never observed half-written.
tmp=\$(mktemp -p "\$HOME/.hermes" .env.XXXXXX)
chmod 0600 "\$tmp"
grep -vE "^[[:space:]]*#?[[:space:]]*\$HERMES_KEY_NAME[[:space:]]*=" "\$ENV_FILE" > "\$tmp" || true
printf "%s=%s\\n" "\$HERMES_KEY_NAME" "\$v" >> "\$tmp"
mv "\$tmp" "\$ENV_FILE"
' <<<"\$v"
EOS
)

# stderr is preserved; stdout suppressed in case any inner command leaks
# the value. Trust the exit code.
if ! printf '%s\n' "$value" | limactl shell "${HERMES_VM_NAME}" -- sudo bash -c "$script" >/dev/null; then
  echo "failed to store ${name}" >&2
  exit 1
fi

echo "stored ${name} in /srv/hermes/.hermes/.env (mode 0600, hermes-owned, encrypted ZFS)."
