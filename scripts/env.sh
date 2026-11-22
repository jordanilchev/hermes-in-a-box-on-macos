#!/usr/bin/env bash
# Source this from any other script in scripts/ to load common environment.
#
#   . "$(dirname "$0")/env.sh"
#
# Variables:
#   HERMES_VM_HOME   root directory where the VM bundle, disks, and backups live.
#                    Default: $HOME/hermes-vm-data
#                    Override: export HERMES_VM_HOME=/path/to/your/apfs/volume/hermes-vm
#   LIMA_HOME        Lima's instance directory.
#                    Default: $HERMES_VM_HOME/lima
#   HERMES_VM_REPO   directory containing this repo (computed from script path).
#   HERMES_VM_NAME   Lima instance name. Default: ubuntu-hermes
#
# Hard fails if a required CLI is missing.
#
# Note: this file does NOT enable `set -eu` when sourced — that flag would
# persist in the caller's shell, killing interactive sessions on the next
# unset-variable reference (tab completion, prompts, etc.). Caller scripts
# enable strict mode themselves immediately after sourcing this file.
# When run directly (`bash env.sh`), the conditional below still applies it.

(return 0 2>/dev/null) || set -eu

# Cursor/minimal shells often leave LANG/LC_CTYPE empty; bash then warns on
# every invocation: "setlocale: LC_CTYPE: cannot change locale ()".
if [ -z "${LANG:-}" ] || [ -z "${LC_CTYPE:-}" ]; then
  if locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    : "${LANG:=en_US.UTF-8}"
  elif locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    : "${LANG:=C.UTF-8}"
  else
    : "${LANG:=C}"
  fi
  : "${LC_CTYPE:=${LANG}}"
  export LANG LC_CTYPE
fi

: "${HERMES_VM_HOME:=${HOME}/hermes-vm-data}"
: "${LIMA_HOME:=${HERMES_VM_HOME}/lima}"
: "${HERMES_VM_NAME:=ubuntu-hermes}"
: "${HERMES_VM_CPUS:=6}"
: "${HERMES_VM_MEMORY:=8GiB}"
: "${ZFS_ARC_MAX_BYTES:=2147483648}"
: "${HERMES_VERSION:=0.23.1}"
# When PyPI lags GitHub, hermes-update.sh prefers this release tag / git ref.
: "${HERMES_GIT_REF:=v0.23.1}"
: "${GEMMA_BASE_MODEL:=gemma4:12b-it-qat}"
: "${GEMMA_MODEL:=gemma4-hermes}"
# Local LLM backend: "inkling" (llama-server GGUF) or "gemma" (host Ollama).
# Persist choice in ${HERMES_VM_HOME}/llm-backend; default gemma until Inkling cutover is proven.
: "${INKLING_HF_REPO:=AtomicChat/Inkling-2-Mini-GGUF}"
: "${INKLING_GGUF_FILE:=Inkling-2-Mini-AD-IQ1_M.gguf}"
: "${INKLING_MODEL:=inkling-2-mini-adiq1}"
: "${INKLING_SHADOW_PORT:=11436}"
: "${LOCAL_LLM_PORT:=11435}"
: "${LOCAL_LLM_HOST:=host.lima.internal}"
: "${LOCAL_LLM_CONTEXT:=65536}"
: "${OLLAMA_KEEP_ALIVE:=30m}"
: "${OLLAMA_MAX_LOADED_MODELS:=1}"
: "${OLLAMA_NUM_PARALLEL:=1}"
: "${OLLAMA_KV_CACHE_TYPE:=q8_0}"
: "${CURSOR_PROXY_PORT:=4646}"
: "${CURSOR_FALLBACK_MODEL:=auto}"
: "${HERMES_SHELL_SESSION:=hermes-vm}"
: "${HERMES_HOST_SHELL_SESSION:=hermes-host}"
: "${HERMES_TERMINAL_IMAGE:=hermes-terminal:node24-py312}"

# Resolve the repo root from this script's location: scripts/env.sh -> ..
HERMES_VM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Backend state file wins over shell default; missing/invalid → gemma (safe reboot).
LLM_BACKEND_FILE="${HERMES_VM_HOME}/llm-backend"
if [ -z "${LOCAL_LLM_BACKEND:-}" ]; then
  if [ -f "${LLM_BACKEND_FILE}" ]; then
    LOCAL_LLM_BACKEND="$(tr -d '[:space:]' < "${LLM_BACKEND_FILE}" || true)"
  fi
fi
case "${LOCAL_LLM_BACKEND:-}" in
  inkling|gemma) ;;
  *) LOCAL_LLM_BACKEND=gemma ;;
esac

export HERMES_VM_HOME LIMA_HOME HERMES_VM_NAME HERMES_VM_CPUS HERMES_VM_MEMORY \
  ZFS_ARC_MAX_BYTES HERMES_VM_REPO HERMES_VERSION HERMES_GIT_REF \
  GEMMA_BASE_MODEL GEMMA_MODEL LOCAL_LLM_BACKEND LLM_BACKEND_FILE \
  INKLING_HF_REPO INKLING_GGUF_FILE INKLING_MODEL INKLING_SHADOW_PORT \
  LOCAL_LLM_PORT LOCAL_LLM_HOST LOCAL_LLM_CONTEXT \
  OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_NUM_PARALLEL OLLAMA_KV_CACHE_TYPE \
  CURSOR_PROXY_PORT CURSOR_FALLBACK_MODEL \
  HERMES_SHELL_SESSION HERMES_HOST_SHELL_SESSION HERMES_TERMINAL_IMAGE

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' not found in PATH" >&2
    echo "       see README.md > Appendix E for install instructions" >&2
    exit 127
  fi
}
