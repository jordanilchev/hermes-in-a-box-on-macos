#!/usr/bin/env bash
# Optional one-time host setup: resume SSH logins in a persistent tmux session.
#
#   ./scripts/host-shell-setup.sh install    # install snippet (default)
#   ./scripts/host-shell-setup.sh status     # show whether snippet is installed
#   ./scripts/host-shell-setup.sh uninstall  # remove snippet
#
# Requires tmux on the Mac host: brew install tmux
# Session name defaults to hermes-host (override with HERMES_HOST_SHELL_SESSION).

. "$(dirname "$0")/env.sh"
set -eu

MARKER="# hermes-in-a-box: host SSH tmux"
SNIPPET_FILE="${HOME}/.hermes-host-tmux.sh"
RC_LINE="[ -f \"${SNIPPET_FILE}\" ] && . \"${SNIPPET_FILE}\""

detect_rc() {
  case "${SHELL:-}" in
    */zsh) echo "${HOME}/.zshrc"; return ;;
    */bash) echo "${HOME}/.bashrc"; return ;;
  esac
  if [ -n "${ZSH_VERSION:-}" ]; then
    echo "${HOME}/.zshrc"
  elif [ -n "${BASH_VERSION:-}" ]; then
    echo "${HOME}/.bashrc"
  elif [ -f "${HOME}/.zshrc" ]; then
    echo "${HOME}/.zshrc"
  elif [ -f "${HOME}/.bashrc" ]; then
    echo "${HOME}/.bashrc"
  else
    echo "${HOME}/.zshrc"
  fi
}

rc_has_snippet() {
  local rc="$1"
  [ -f "$rc" ] && grep -Fq "${MARKER}" "$rc"
}

write_snippet_file() {
  cat > "${SNIPPET_FILE}" <<'EOF'
# hermes-in-a-box — auto-attach tmux on SSH login (sourced from shell rc)
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" ]] \
    && [[ $- == *i* ]] \
    && command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s "${HERMES_HOST_SHELL_SESSION:-hermes-host}"
fi
EOF
  chmod 644 "${SNIPPET_FILE}"
}

cmd="${1:-install}"
rc="$(detect_rc)"

case "$cmd" in
  status)
    if rc_has_snippet "$rc" && [ -f "${SNIPPET_FILE}" ]; then
      echo "installed: ${SNIPPET_FILE} (sourced from ${rc})"
      exit 0
    fi
    echo "not installed (expected rc: ${rc})"
    exit 1
    ;;
  uninstall)
    if rc_has_snippet "$rc"; then
      tmp="$(mktemp)"
      grep -Fv "${MARKER}" "$rc" | grep -Fv "${SNIPPET_FILE}" > "$tmp" || true
      mv "$tmp" "$rc"
    fi
    rm -f "${SNIPPET_FILE}"
    echo "removed host SSH tmux setup"
    ;;
  install)
    if ! command -v tmux >/dev/null 2>&1; then
      echo "error: tmux not found — install with: brew install tmux" >&2
      exit 127
    fi
    write_snippet_file
    if ! rc_has_snippet "$rc"; then
      touch "$rc"
      {
        echo ""
        echo "${MARKER}"
        echo "${RC_LINE}"
      } >> "$rc"
    fi
    echo "installed host SSH tmux:"
    echo "  snippet: ${SNIPPET_FILE}"
    echo "  shell rc: ${rc}"
    echo "  session: ${HERMES_HOST_SHELL_SESSION:-hermes-host}"
    echo "SSH back in after a drop to resume the same host shell."
    ;;
  *)
    echo "usage: $(basename "$0") [install|status|uninstall]" >&2
    exit 2
    ;;
esac
