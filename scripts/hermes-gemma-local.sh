#!/usr/bin/env bash
# Host-side Gemma 4 12B QAT inference for Hermes (single local LLM backend).
#
# Inference runs on the Mac host (Metal GPU via Ollama). The Lima VM reaches
# the host at host.lima.internal:11435. Cloud backends (OpenRouter, Cursor) and
# the in-VM Ollama install are stopped/disabled by `setup`.
#
# Model: gemma4-hermes (local alias over gemma4:12b-it-qat with num_ctx 65536).
# Hermes Agent 0.16+ requires ≥64K context for tool use. Base weights ~7 GB;
# 65K ctx needs ~9 GB VRAM — fits M4 16 GB.
#
# Usage:
#   ./scripts/hermes-gemma-local.sh setup          # install + pull + purge + enable
#   ./scripts/hermes-gemma-local.sh install-host   # brew ollama + pull model (host)
#   ./scripts/hermes-gemma-local.sh start|stop|status|logs
#   ./scripts/hermes-gemma-local.sh purge-vm       # stop VM ollama + cursor-proxy
#   ./scripts/hermes-gemma-local.sh enable-hermes  # point all Hermes LLM routes local
#   ./scripts/hermes-gemma-local.sh test           # smoke test from inside VM

. "$(dirname "$0")/env.sh"
set -eu

: "${GEMMA_BASE_MODEL:=gemma4:12b-it-qat}"
: "${GEMMA_MODEL:=gemma4-hermes}"
: "${LOCAL_LLM_PORT:=11435}"
: "${LOCAL_LLM_HOST:=host.lima.internal}"
: "${LOCAL_LLM_CONTEXT:=65536}"
: "${OLLAMA_KEEP_ALIVE:=24h}"

LOCAL_LLM_BASE_URL="http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/v1"

require_cmd limactl

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

require_vm() {
  if ! vm_running; then
    echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
    exit 1
  fi
}

host_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    command -v ollama
  elif [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; then
    echo /Applications/Ollama.app/Contents/Resources/ollama
  else
    return 1
  fi
}

install_host_ollama() {
  if host_ollama >/dev/null 2>&1; then
    echo "Ollama already installed: $(host_ollama) $(host_ollama --version 2>/dev/null || true)"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: install Homebrew, then: brew install ollama" >&2
    exit 1
  fi
  echo "==> installing Ollama via Homebrew"
  brew install ollama
}

ensure_llama_server() {
  # Homebrew ollama 0.30.x omits llama-server; the official app bundles it.
  local cellar llama_server
  llama_server="/Applications/Ollama.app/Contents/Resources/llama-server"
  [ -x "${llama_server}" ] || return 0
  cellar="$(brew --prefix ollama 2>/dev/null)/../Cellar/ollama" || return 0
  [ -d "${cellar}" ] || return 0
  for ver_dir in "${cellar}"/*/libexec/lib/ollama; do
    [ -d "${ver_dir}" ] || continue
    if [ ! -x "${ver_dir}/llama-server" ]; then
      ln -sf "${llama_server}" "${ver_dir}/llama-server"
      echo "linked llama-server -> ${ver_dir}/llama-server"
    fi
  done
}

pull_model() {
  local ollama_bin
  ollama_bin="$(host_ollama)"
  echo "==> pulling ${GEMMA_BASE_MODEL} (QAT Q4_0, ~7 GB)"
  OLLAMA_HOST="127.0.0.1:${LOCAL_LLM_PORT}" "${ollama_bin}" pull "${GEMMA_BASE_MODEL}"
  create_hermes_model
}

create_hermes_model() {
  local ollama_bin modelfile
  ollama_bin="$(host_ollama)"
  modelfile="$(mktemp)"
  cat >"${modelfile}" <<EOF
FROM ${GEMMA_BASE_MODEL}
PARAMETER num_ctx ${LOCAL_LLM_CONTEXT}
EOF
  echo "==> creating ${GEMMA_MODEL} (num_ctx=${LOCAL_LLM_CONTEXT})"
  OLLAMA_HOST="127.0.0.1:${LOCAL_LLM_PORT}" "${ollama_bin}" create "${GEMMA_MODEL}" -f "${modelfile}"
  rm -f "${modelfile}"
}

start_host_ollama() {
  local ollama_bin
  ollama_bin="$(host_ollama)" || { echo "error: Ollama not installed — run install-host first" >&2; exit 1; }

  # Lima forwards guest :11434 → host :11434 (in-VM Ollama). Use 11435 for host inference.
  if curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/api/tags" >/dev/null 2>&1; then
    local ver
    ver="$(OLLAMA_HOST="127.0.0.1:${LOCAL_LLM_PORT}" "${ollama_bin}" --version 2>/dev/null | head -1 || true)"
    echo "Ollama already listening on 127.0.0.1:${LOCAL_LLM_PORT} (${ver})"
    return 0
  fi

  # Stop brew service if it grabbed :11434 (conflicts with Lima guest forward).
  brew services stop ollama 2>/dev/null || true

  echo "==> starting Ollama on 0.0.0.0:${LOCAL_LLM_PORT} (OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE})"
  # Bind all interfaces so the Lima guest can reach us via host.lima.internal.
  nohup env \
    OLLAMA_HOST="0.0.0.0:${LOCAL_LLM_PORT}" \
    OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE}" \
    OLLAMA_FLASH_ATTENTION=1 \
    "${ollama_bin}" serve \
    >"${HERMES_VM_HOME}/ollama-serve.log" 2>&1 &
  echo $! >"${HERMES_VM_HOME}/ollama-serve.pid"

  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/api/tags" >/dev/null 2>&1; then
      echo "Ollama ready (pid $(cat "${HERMES_VM_HOME}/ollama-serve.pid"))"
      return 0
    fi
    sleep 1
  done
  echo "error: Ollama did not become ready — see ${HERMES_VM_HOME}/ollama-serve.log" >&2
  exit 1
}

stop_host_ollama() {
  if [ -f "${HERMES_VM_HOME}/ollama-serve.pid" ]; then
    local pid
    pid="$(cat "${HERMES_VM_HOME}/ollama-serve.pid")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" && echo "stopped Ollama (pid ${pid})"
    fi
    rm -f "${HERMES_VM_HOME}/ollama-serve.pid"
  fi
  # Also stop the macOS app daemon if present (best-effort).
  pkill -f 'ollama serve' 2>/dev/null || true
}

host_status() {
  if curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/api/tags" >/dev/null 2>&1; then
    echo "host Ollama: up on :${LOCAL_LLM_PORT}"
    curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/api/tags" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('models:', ', '.join(m['name'] for m in d.get('models',[])) or '(none)')"
  else
    echo "host Ollama: down"
  fi
}

ufw_allow_host_ollama() {
  limactl shell "${HERMES_VM_NAME}" -- sudo env LOCAL_LLM_PORT="${LOCAL_LLM_PORT}" bash -s <<'EOS'
set -eu
HOST_IP=$(getent hosts host.lima.internal | awk '{print $1}')
[ -n "$HOST_IP" ] || { echo "error: cannot resolve host.lima.internal" >&2; exit 1; }
RULE="allow out to ${HOST_IP} port ${LOCAL_LLM_PORT} proto tcp comment host-ollama-gemma"
if ufw status numbered | grep -Fq "host-ollama-gemma"; then
  echo "UFW rule for host Ollama already present"
else
  # Insert before RFC1918 deny rules so guest can reach Lima gateway.
  ufw insert 5 ${RULE}
  echo "added UFW: ${RULE}"
fi
EOS
}

purge_vm_backends() {
  require_vm
  echo "==> stopping cloud/local VM LLM backends"
  limactl shell "${HERMES_VM_NAME}" -- sudo bash -s <<'EOS'
set -eu
for svc in hermes-cursor-proxy ollama; do
  if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q enabled; then
    systemctl disable --now "${svc}.service" 2>/dev/null || true
  else
    systemctl stop "${svc}.service" 2>/dev/null || true
  fi
done
systemctl daemon-reload
echo "disabled: hermes-cursor-proxy, ollama (in-VM)"
EOS
}

enable_hermes() {
  require_vm
  ufw_allow_host_ollama

  echo "==> routing all Hermes LLM calls to ${LOCAL_LLM_BASE_URL} (${GEMMA_MODEL})"
  limactl shell "${HERMES_VM_NAME}" -- sudo env \
    GEMMA_MODEL="${GEMMA_MODEL}" \
    LOCAL_LLM_BASE_URL="${LOCAL_LLM_BASE_URL}" \
    LOCAL_LLM_CONTEXT="${LOCAL_LLM_CONTEXT}" \
    bash -s <<'OUTER_EOS'
set -eu
HERMES_UID=$(id -u hermes)
runuser -u hermes -- env \
  HOME=/srv/hermes \
  GEMMA_MODEL="$GEMMA_MODEL" \
  LOCAL_LLM_BASE_URL="$LOCAL_LLM_BASE_URL" \
  LOCAL_LLM_CONTEXT="$LOCAL_LLM_CONTEXT" \
  PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
  python3 <<'PY'
import os, re, yaml
from pathlib import Path

path = Path("/srv/hermes/.hermes/config.yaml")
cfg = yaml.safe_load(path.read_text())

model = cfg.setdefault("model", {})
model.update({
    "provider": "custom",
    "base_url": os.environ["LOCAL_LLM_BASE_URL"],
    "default": os.environ["GEMMA_MODEL"],
    "api_key": "ollama",
    "context_length": int(os.environ["LOCAL_LLM_CONTEXT"]),
    "ollama_num_ctx": int(os.environ["LOCAL_LLM_CONTEXT"]),
})
model.pop("fallback_providers", None)

aux = cfg.setdefault("auxiliary", {})
for task, task_cfg in list(aux.items()):
    if not isinstance(task_cfg, dict):
        continue
    task_cfg.update({
        "provider": "custom",
        "base_url": os.environ["LOCAL_LLM_BASE_URL"],
        "model": os.environ["GEMMA_MODEL"],
        "api_key": "ollama",
    })

path.write_text(yaml.dump(cfg, default_flow_style=False, allow_unicode=True, sort_keys=False))
print("updated", path)
print("  model.default =", model.get("default"))
print("  model.base_url =", model.get("base_url"))
print("  auxiliary tasks =", len(aux))
PY
OUTER_EOS

  ./scripts/hermes-gateway.sh restart 2>/dev/null || true
  echo "done. Test: ./scripts/hermes-gemma-local.sh test"
}

test_inference() {
  require_vm
  echo "==> VM → host Ollama smoke test"
  limactl shell "${HERMES_VM_NAME}" -- bash -lc "
    set -eu
    curl -fsS http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/api/tags | python3 -c \"import sys,json; d=json.load(sys.stdin); print('tags ok:', [m['name'] for m in d.get('models',[])][:5])\"
    curl -fsS http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"${GEMMA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gemma-ok\"}],\"stream\":false,\"options\":{\"num_predict\":16}}' \
      | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:120])\"
  "
}

cmd="${1:-status}"

case "$cmd" in
  install-host)
    install_host_ollama
    ensure_llama_server
    start_host_ollama
    pull_model
    ;;
  start)
    start_host_ollama
    ;;
  stop)
    stop_host_ollama
    ;;
  status)
    host_status
    if vm_running; then
      limactl shell "${HERMES_VM_NAME}" -- sudo systemctl is-active hermes-gateway hermes-cursor-proxy ollama 2>/dev/null \
        | paste - - - | awk '{print "VM services (gateway/cursor/ollama):", $0}' || true
      limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- \
        python3 -c "import yaml; c=yaml.safe_load(open('/srv/hermes/.hermes/config.yaml')); m=c.get('model',{}); print('hermes model:', m.get('default'), '@', m.get('base_url'))" 2>/dev/null || true
    fi
    ;;
  logs)
    tail -f "${HERMES_VM_HOME}/ollama-serve.log"
    ;;
  purge-vm)
    purge_vm_backends
    ;;
  enable-hermes)
    enable_hermes
    ;;
  test)
    test_inference
    ;;
  setup)
    install_host_ollama
    ensure_llama_server
    purge_vm_backends
    start_host_ollama
    pull_model
    enable_hermes
    test_inference
    cat <<MSG

Gemma 4 12B QAT is now the only LLM backend.
  Host:  Ollama ${GEMMA_MODEL} on 0.0.0.0:${LOCAL_LLM_PORT}
  VM:    ${LOCAL_LLM_BASE_URL} (all model + auxiliary tasks)
  Stopped: hermes-cursor-proxy, in-VM ollama

Logs: ./scripts/hermes-gemma-local.sh logs
MSG
    ;;
  *)
    echo "usage: $0 {setup|install-host|start|stop|status|logs|purge-vm|enable-hermes|test}" >&2
    exit 1
    ;;
esac
