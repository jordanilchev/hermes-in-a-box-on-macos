#!/usr/bin/env bash
# Persist the Hermes stack across Mac login / reboot via launchd.
#
# Installs LaunchAgents that:
#   - keep the host LLM serving on :LOCAL_LLM_PORT (KeepAlive), per LOCAL_LLM_BACKEND:
#       inkling → llama-server + AD-IQ1_M GGUF (com.hermes-in-a-box.inkling)
#       gemma   → ollama serve                 (com.hermes-in-a-box.ollama)
#     Only one is installed; the other is booted out and removed (same port).
#   - run ./scripts/start.sh at login (VM + UFW + gateway)
#
# Re-run `install` after switching backends (llm-backend file / LOCAL_LLM_BACKEND).
#
# Usage:
#   ./scripts/hermes-autostart.sh install
#   ./scripts/hermes-autostart.sh uninstall
#   ./scripts/hermes-autostart.sh status
#   ./scripts/hermes-autostart.sh start-now   # same as ./scripts/start.sh

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
OLLAMA_LABEL="com.hermes-in-a-box.ollama"
STACK_LABEL="com.hermes-in-a-box.stack"
INKLING_LABEL="com.hermes-in-a-box.inkling"
OLLAMA_PLIST="${LAUNCH_AGENTS}/${OLLAMA_LABEL}.plist"
INKLING_PLIST="${LAUNCH_AGENTS}/${INKLING_LABEL}.plist"
STACK_PLIST="${LAUNCH_AGENTS}/${STACK_LABEL}.plist"
# launchd often cannot create/open stdout paths on external volumes (EX_CONFIG).
LOG_DIR="${HOME}/Library/Logs/hermes-in-a-box"

host_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    command -v ollama
  elif [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; then
    echo /Applications/Ollama.app/Contents/Resources/ollama
  else
    return 1
  fi
}

uid_domain() {
  echo "gui/$(id -u)"
}

bootout() {
  local plist="$1"
  launchctl bootout "$(uid_domain)" "${plist}" 2>/dev/null || true
  launchctl unload "${plist}" 2>/dev/null || true
}

bootstrap() {
  local plist="$1"
  bootout "${plist}"
  launchctl bootstrap "$(uid_domain)" "${plist}"
  launchctl enable "$(uid_domain)/$(basename "${plist}" .plist)" 2>/dev/null || true
}

install_ollama_agent() {
  local ollama_bin
  ollama_bin="$(host_ollama)" || {
    echo "error: Ollama not installed — run ./scripts/hermes-gemma-local.sh install-host first" >&2
    exit 1
  }

  mkdir -p "${LAUNCH_AGENTS}" "${LOG_DIR}" "${HERMES_VM_HOME}"

  # Free :LOCAL_LLM_PORT — boot out any prior agent, then stop nohup leftovers.
  bootout "${INKLING_PLIST}"
  rm -f "${INKLING_PLIST}"
  bootout "${OLLAMA_PLIST}"
  "${SCRIPTS}/hermes-inkling-local.sh" stop 2>/dev/null || true
  "${SCRIPTS}/hermes-gemma-local.sh" stop 2>/dev/null || true
  sleep 1

  cat >"${OLLAMA_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${OLLAMA_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${ollama_bin}</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>OLLAMA_HOST</key><string>0.0.0.0:${LOCAL_LLM_PORT}</string>
    <key>OLLAMA_KEEP_ALIVE</key><string>${OLLAMA_KEEP_ALIVE}</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key><string>${OLLAMA_MAX_LOADED_MODELS}</string>
    <key>OLLAMA_NUM_PARALLEL</key><string>${OLLAMA_NUM_PARALLEL}</string>
    <key>OLLAMA_KV_CACHE_TYPE</key><string>${OLLAMA_KV_CACHE_TYPE}</string>
    <key>OLLAMA_FLASH_ATTENTION</key><string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key><string>${HOME}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/ollama-serve.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/ollama-serve.launchd.err</string>
</dict>
</plist>
EOF
  bootstrap "${OLLAMA_PLIST}"
  echo "installed ${OLLAMA_PLIST}"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

install_inkling_agent() {
  local spec bin bin_dir args
  # Validates llama-server + exact GGUF size before anything is stopped.
  spec="$("${SCRIPTS}/hermes-inkling-local.sh" launchd-spec)"
  bin="$(printf '%s\n' "${spec}" | head -1)"
  bin_dir="$(cd "$(dirname "${bin}")" && pwd)"
  args="$(printf '%s\n' "${spec}" | xml_escape | sed 's|.*|    <string>&</string>|')"

  mkdir -p "${LAUNCH_AGENTS}" "${LOG_DIR}" "${HERMES_VM_HOME}"

  # Free :LOCAL_LLM_PORT — Ollama agent must not race llama-server at login.
  bootout "${OLLAMA_PLIST}"
  rm -f "${OLLAMA_PLIST}"
  bootout "${INKLING_PLIST}"
  "${SCRIPTS}/hermes-gemma-local.sh" stop 2>/dev/null || true
  "${SCRIPTS}/hermes-inkling-local.sh" stop 2>/dev/null || true
  sleep 1

  # WorkingDirectory + DYLD_FALLBACK_LIBRARY_PATH: @rpath dylibs live beside
  # llama-server in llama.cpp build/bin.
  cat >"${INKLING_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${INKLING_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>DYLD_FALLBACK_LIBRARY_PATH</key><string>${bin_dir}</string>
    <key>PATH</key>
    <string>${bin_dir}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key><string>${bin_dir}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/inkling-llama-server.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/inkling-llama-server.launchd.err</string>
</dict>
</plist>
EOF
  plutil -lint "${INKLING_PLIST}" >/dev/null
  bootstrap "${INKLING_PLIST}"
  echo "installed ${INKLING_PLIST}"
}

install_llm_agent() {
  case "${LOCAL_LLM_BACKEND}" in
    inkling) install_inkling_agent ;;
    *) install_ollama_agent ;;
  esac
}

install_stack_agent() {
  mkdir -p "${LAUNCH_AGENTS}" "${LOG_DIR}"
  cat >"${STACK_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${STACK_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPTS}/start.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>${HERMES_VM_REPO}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HERMES_VM_HOME</key><string>${HERMES_VM_HOME}</string>
    <key>LIMA_HOME</key><string>${LIMA_HOME}</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG_DIR}/stack.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/stack.launchd.err</string>
</dict>
</plist>
EOF
  bootstrap "${STACK_PLIST}"
  echo "installed ${STACK_PLIST}"
}

uninstall_agents() {
  bootout "${STACK_PLIST}"
  bootout "${OLLAMA_PLIST}"
  bootout "${INKLING_PLIST}"
  rm -f "${STACK_PLIST}" "${OLLAMA_PLIST}" "${INKLING_PLIST}"
  echo "removed LaunchAgents ${OLLAMA_LABEL} ${INKLING_LABEL} ${STACK_LABEL}"
}

agent_status() {
  local label="$1" plist="$2"
  if [ -f "${plist}" ]; then
    echo "${label}: plist present (${plist})"
  else
    echo "${label}: plist missing"
  fi
  launchctl print "$(uid_domain)/${label}" 2>/dev/null \
    | awk '/state =|pid =|path =/{print "  "$0}' \
    || echo "  (not loaded)"
}

case "${1:-status}" in
  install)
    install_llm_agent
    install_stack_agent
    echo "==> bringing stack up now"
    "${SCRIPTS}/start.sh"
    echo
    echo "Autostart installed. On Mac login/reboot: ${LOCAL_LLM_BACKEND} KeepAlive + start.sh (VM + gateway)."
    echo "Logs: ${LOG_DIR}/"
    ;;
  uninstall)
    uninstall_agents
    ;;
  start-now)
    exec "${SCRIPTS}/start.sh"
    ;;
  status)
    echo "backend: ${LOCAL_LLM_BACKEND}"
    agent_status "${OLLAMA_LABEL}" "${OLLAMA_PLIST}"
    agent_status "${INKLING_LABEL}" "${INKLING_PLIST}"
    agent_status "${STACK_LABEL}" "${STACK_PLIST}"
    echo "---"
    case "${LOCAL_LLM_BACKEND}" in
      inkling) "${SCRIPTS}/hermes-inkling-local.sh" status || true ;;
      *) "${SCRIPTS}/hermes-gemma-local.sh" status || true ;;
    esac
    ;;
  *)
    echo "usage: $0 {install|uninstall|status|start-now}" >&2
    exit 1
    ;;
esac
