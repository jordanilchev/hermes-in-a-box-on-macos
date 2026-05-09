#!/usr/bin/env bash
# Prompt for an API key name and value, store via `hermes config set`.
# Value path: host stdin → outer-bash (root, in VM) read → here-string
# → inner-bash (hermes) read → hermes config set argv. Argv exposure
# ends inside the VM, where hermes is the only non-root user.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

read -rp "API key name [OPENROUTER_API_KEY]: " name
name="${name:-OPENROUTER_API_KEY}"
read -rsp "Value for ${name}: " value
echo
[ -n "${value}" ] || { echo "empty value, aborting" >&2; exit 1; }

# The outer bash in the VM gets its script via -c (argv), not stdin.
# Piping the script on stdin would race with the value: bash block-buffers
# stdin while parsing (~4 KB on a pipe), so a downstream `read -r v` ends up
# either grabbing nothing or executing the value as a command — the bug
# this rewrite fixes. With -c, stdin stays untouched until our explicit
# `read -r v` pulls the value off the pipe.
quoted_name=$(printf '%q' "$name")
script=$(cat <<EOS
set -eu
read -r v
HERMES_UID=\$(id -u hermes)
runuser -u hermes -- env \\
  HOME=/srv/hermes \\
  XDG_RUNTIME_DIR=/run/user/\$HERMES_UID \\
  PATH=/srv/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
  bash -c 'set -eu; read -r v; "\$HOME/.local/bin/hermes" config set "\$0" "\$v"' ${quoted_name} <<<"\$v"
EOS
)

# stdout goes to /dev/null because hermes' success line echoes the value
# verbatim ("✓ Set OPENROUTER_API_KEY = sk-or-v1-…"), which would defeat
# the silent `read -rsp` we just used. stderr is left intact so genuine
# errors still surface; the exit code is what we trust.
if ! printf '%s\n' "$value" | limactl shell "${HERMES_VM_NAME}" -- sudo bash -c "$script" >/dev/null; then
  echo "failed to store ${name}" >&2
  exit 1
fi

echo "stored ${name} in /srv/hermes/.hermes/config.yaml (hermes-owned, encrypted ZFS)."
