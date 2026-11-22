#!/usr/bin/env bash
# Host-side Inkling 2 Mini (AtomicChat AD-IQ1_M GGUF) for Hermes.
#
# Serves via llama-server (OpenAI-compatible) on LOCAL_LLM_PORT so the existing
# Hermes guest UFW + config path keeps working. Stops host Ollama while active
# (same port). Gemma remains on disk as a fallback via hermes-gemma-local.sh.
#
# Requires: llama.cpp b12600+ with Metal (brew install llama.cpp --HEAD, or a
# local build under HERMES_LLAMA_CPP_DIR).
#
# Usage:
#   ./scripts/hermes-inkling-local.sh setup     # download + build check + serve + enable Hermes
#   ./scripts/hermes-inkling-local.sh download
#   ./scripts/hermes-inkling-local.sh start|stop|status|logs|test
#   ./scripts/hermes-inkling-local.sh enable-hermes

. "$(dirname "$0")/env.sh"
set -eu

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

: "${INKLING_HF_REPO:=AtomicChat/Inkling-2-Mini-GGUF}"
: "${INKLING_GGUF_FILE:=Inkling-2-Mini-AD-IQ1_M.gguf}"
: "${INKLING_MODEL:=inkling-2-mini-adiq1}"
: "${INKLING_MODEL_DIR:=${HERMES_VM_HOME}/models/inkling-2-mini}"
: "${INKLING_CTX:=${LOCAL_LLM_CONTEXT}}"
: "${INKLING_NGL:=99}"
# Metal OOM knobs (16 GB Mac + 8 GiB Lima is tight):
# - ubatch 512 ≈ multi‑GiB Metal buffers at 64K → OOM. Default 128.
# - Always -np 1 so one slot owns the full ctx (Hermes needs ≥64K).
# - q8 KV cuts cache vs f16.
: "${INKLING_BATCH:=512}"
: "${INKLING_UBATCH:=128}"
: "${INKLING_CACHE_TYPE:=q8_0}"
# Refuse start on ≤16 GiB hosts unless explicitly overridden (proven Metal OOM).
: "${INKLING_ALLOW_16GB:=0}"
# Minimum free+inactive pages (16 KiB pages) before load — ~2 GiB headroom.
: "${INKLING_MIN_FREE_PAGES:=131072}"
# Must bind 0.0.0.0: the Lima guest reaches us as host.lima.internal
# (192.168.5.2 on the vz user-mode net), never via host loopback.
: "${INKLING_HOST:=0.0.0.0}"
# Exact HF Content-Length of the AD-IQ1_M GGUF; any other size is truncated/corrupt.
: "${INKLING_GGUF_BYTES:=7263669856}"
: "${LLAMA_CPP_DIR:=${HERMES_VM_HOME}/llama.cpp}"
: "${CURSOR_FALLBACK_MODEL:=auto}"

LOCAL_LLM_BASE_URL="http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/v1"
CURSOR_PROXY_BASE_URL="http://localhost:${CURSOR_PROXY_PORT}/v1"
GGUF_PATH="${INKLING_MODEL_DIR}/${INKLING_GGUF_FILE}"
PID_FILE="${HERMES_VM_HOME}/inkling-llama-server.pid"
LOG_FILE="${HERMES_VM_HOME}/inkling-llama-server.log"
LAUNCHD_LABEL="com.hermes-in-a-box.ollama"
INKLING_LAUNCHD_LABEL="com.hermes-in-a-box.inkling"
INKLING_PLIST="${HOME}/Library/LaunchAgents/${INKLING_LAUNCHD_LABEL}.plist"
LAUNCHD_LOG_DIR="${HOME}/Library/Logs/hermes-in-a-box"

require_cmd limactl
require_cmd curl

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

require_vm() {
  if ! vm_running; then
    echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
    exit 1
  fi
}

find_llama_server() {
  local cand
  for cand in \
    "${LLAMA_CPP_DIR}/build/bin/llama-server" \
    "$(command -v llama-server 2>/dev/null || true)" \
    /opt/homebrew/bin/llama-server \
    /usr/local/bin/llama-server
  do
    if [ -n "${cand}" ] && [ -x "${cand}" ]; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}

require_llama_server() {
  if ! find_llama_server >/dev/null; then
    echo "error: llama-server not found (need llama.cpp b12600+ with Inkling support)" >&2
    echo "       build: ./scripts/hermes-inkling-local.sh build-llama" >&2
    echo "       or:    brew install llama.cpp --HEAD" >&2
    exit 1
  fi
}

build_llama() {
  require_cmd git
  require_cmd cmake
  echo "==> building llama.cpp (Metal) into ${LLAMA_CPP_DIR}"
  if [ ! -d "${LLAMA_CPP_DIR}/.git" ]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "${LLAMA_CPP_DIR}"
  else
    git -C "${LLAMA_CPP_DIR}" fetch --depth 1 origin master
    git -C "${LLAMA_CPP_DIR}" reset --hard origin/master
  fi
  cmake -S "${LLAMA_CPP_DIR}" -B "${LLAMA_CPP_DIR}/build" \
    -DGGML_METAL=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${LLAMA_CPP_DIR}/build" --config Release -j "$(sysctl -n hw.ncpu)" --target llama-server
  "${LLAMA_CPP_DIR}/build/bin/llama-server" --version 2>&1 | head -3 || true
  echo "llama-server: ${LLAMA_CPP_DIR}/build/bin/llama-server"
}

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

gguf_ok() {
  [ -f "${GGUF_PATH}" ] && [ "$(file_size "${GGUF_PATH}")" -eq "${INKLING_GGUF_BYTES}" ]
}

require_gguf() {
  if ! gguf_ok; then
    echo "error: ${GGUF_PATH} missing or not ${INKLING_GGUF_BYTES} bytes — run: $0 download" >&2
    exit 1
  fi
}

download_gguf() {
  mkdir -p "${INKLING_MODEL_DIR}"
  if gguf_ok; then
    echo "already have ${GGUF_PATH} ($(du -h "${GGUF_PATH}" | awk '{print $1}'))"
    return 0
  fi
  local url partial
  url="https://huggingface.co/${INKLING_HF_REPO}/resolve/main/${INKLING_GGUF_FILE}"
  partial="${GGUF_PATH}.partial"
  echo "==> downloading ${INKLING_GGUF_FILE} (~7.3 GB) → ${INKLING_MODEL_DIR}"
  curl -L --fail --retry 5 -C - -o "${partial}" "${url}"
  if [ "$(file_size "${partial}")" -ne "${INKLING_GGUF_BYTES}" ]; then
    echo "error: ${partial} is $(file_size "${partial}") bytes, expected ${INKLING_GGUF_BYTES}" >&2
    exit 1
  fi
  mv "${partial}" "${GGUF_PATH}"
  ls -lh "${GGUF_PATH}"
}

inkling_managed_by_launchd() {
  launchctl print "gui/$(id -u)/${INKLING_LAUNCHD_LABEL}" >/dev/null 2>&1
}

stop_ollama_on_port() {
  # Free LOCAL_LLM_PORT: launchd Ollama agent and any leftover serve process.
  if launchctl print "gui/$(id -u)/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    echo "==> stopping launchd ${LAUNCHD_LABEL} (port conflict with llama-server)"
    launchctl bootout "gui/$(id -u)" "${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist" 2>/dev/null || true
    launchctl unload "${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist" 2>/dev/null || true
  fi
  "${SCRIPTS}/hermes-gemma-local.sh" stop 2>/dev/null || true
  # The launchd llama-server may still be loading the model; don't kill it.
  if inkling_managed_by_launchd; then
    return 0
  fi
  # Best-effort: anything still bound to the port
  local pids
  pids="$(lsof -nP -iTCP:"${LOCAL_LLM_PORT}" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "${pids}" ]; then
    echo "==> killing listeners on :${LOCAL_LLM_PORT}: ${pids}"
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null || true
    sleep 1
  fi
}

server_running() {
  if [ -f "${PID_FILE}" ]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi
  # Ollama also answers /v1/models on this port; only count our alias.
  curl -fsS --max-time 2 "http://127.0.0.1:${LOCAL_LLM_PORT}/v1/models" 2>/dev/null \
    | grep -Fq "\"${INKLING_MODEL}\""
}

wait_for_server() {
  local i pid
  for i in $(seq 1 90); do
    if [ -f "${PID_FILE}" ]; then
      pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
      if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
        echo "error: llama-server pid ${pid} exited during load — see ${LOG_FILE}" >&2
        return 1
      fi
    fi
    # Must see our alias — Ollama also answers /v1/models on this port.
    if server_running; then
      return 0
    fi
    sleep 2
  done
  echo "error: llama-server did not serve ${INKLING_MODEL} on :${LOCAL_LLM_PORT}" >&2
  echo "       see ${LOG_FILE}" >&2
  return 1
}

oom_preflight() {
  local ram_bytes ram_gb free_pages
  ram_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  ram_gb="$((ram_bytes / 1024 / 1024 / 1024))"
  free_pages="$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3+0}')"
  : "${free_pages:=0}"

  echo "==> OOM preflight: host≈${ram_gb} GiB, free_pages=${free_pages} (need ≥${INKLING_MIN_FREE_PAGES})"
  if [ "${ram_gb}" -le 16 ] && [ "${INKLING_ALLOW_16GB}" != "1" ]; then
    echo "error: refusing Inkling on ≤16 GiB Mac (Metal OOM with 64K ctx + Lima 8 GiB)." >&2
    echo "       Stay on gemma, or retry later with INKLING_ALLOW_16GB=1 after freeing RAM." >&2
    echo "       Safer knobs already defaulted: -np 1 -fa on -ub ${INKLING_UBATCH} -ctk/-ctv ${INKLING_CACHE_TYPE}" >&2
    return 1
  fi
  if [ "${free_pages}" -gt 0 ] && [ "${free_pages}" -lt "${INKLING_MIN_FREE_PAGES}" ]; then
    echo "error: not enough free memory to load Inkling (free_pages=${free_pages} < ${INKLING_MIN_FREE_PAGES})." >&2
    echo "       Quit heavy apps / unload other models, then retry." >&2
    return 1
  fi
  return 0
}

# Tiny completion must succeed; Metal can bind :port and still be poisoned.
smoke_compute() {
  local port="${1:-${LOCAL_LLM_PORT}}" body code
  body="$(curl -sS --max-time 120 -w '\n%{http_code}' "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${INKLING_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: inkling-ok\"}],\"max_tokens\":16,\"chat_template_kwargs\":{\"reasoning_effort\":\"low\"}}" \
    2>/dev/null || true)"
  code="$(printf '%s\n' "${body}" | tail -n1)"
  body="$(printf '%s\n' "${body}" | sed '$d')"
  if [ "${code}" != "200" ]; then
    echo "error: Inkling compute smoke failed (HTTP ${code:-none}) — likely Metal OOM" >&2
    printf '%s\n' "${body}" | tail -c 400 >&2
    return 1
  fi
  if printf '%s' "${body}" | grep -qi 'Compute error\|OutOfMemory\|Insufficient Memory'; then
    echo "error: Inkling compute smoke reports OOM/compute error" >&2
    return 1
  fi
  echo "compute smoke: ok (HTTP 200)"
}

llama_server_args() {
  # Shared argv after the binary path (start_server + launchd_spec).
  printf '%s\n' \
    -m "${GGUF_PATH}" \
    --alias "${INKLING_MODEL}" \
    --host "${INKLING_HOST}" \
    --port "${LOCAL_LLM_PORT}" \
    -c "${INKLING_CTX}" \
    -ngl "${INKLING_NGL}" \
    -np 1 \
    -fa on \
    -b "${INKLING_BATCH}" \
    -ub "${INKLING_UBATCH}" \
    -ctk "${INKLING_CACHE_TYPE}" \
    -ctv "${INKLING_CACHE_TYPE}" \
    --jinja \
    --metrics
}

start_server() {
  local bin
  require_llama_server
  require_gguf
  oom_preflight || exit 1
  if server_running; then
    echo "llama-server already up on :${LOCAL_LLM_PORT}"
    smoke_compute "${LOCAL_LLM_PORT}" || {
      echo "==> existing server is poisoned — restarting" >&2
      stop_server
    }
    if server_running; then
      return 0
    fi
  fi
  # Autostart installed (hermes-autostart.sh): launchd owns the process.
  if [ -f "${INKLING_PLIST}" ]; then
    rm -f "${PID_FILE}"
    stop_ollama_on_port
    if inkling_managed_by_launchd; then
      echo "==> waiting on launchd ${INKLING_LAUNCHD_LABEL}"
      launchctl kickstart "gui/$(id -u)/${INKLING_LAUNCHD_LABEL}" 2>/dev/null || true
    else
      echo "==> bootstrapping launchd ${INKLING_LAUNCHD_LABEL}"
      launchctl bootstrap "gui/$(id -u)" "${INKLING_PLIST}"
    fi
    if wait_for_server && smoke_compute; then
      echo "llama-server: ready (launchd ${INKLING_LAUNCHD_LABEL})"
      return 0
    fi
    echo "       see ${LAUNCHD_LOG_DIR}/inkling-llama-server.launchd.err" >&2
    stop_server || true
    exit 1
  fi
  stop_ollama_on_port
  bin="$(find_llama_server)"
  mkdir -p "${HERMES_VM_HOME}"
  echo "==> starting ${bin}"
  echo "    model=${GGUF_PATH}"
  echo "    alias=${INKLING_MODEL} ctx=${INKLING_CTX} ngl=${INKLING_NGL} port=${LOCAL_LLM_PORT} np=1 ub=${INKLING_UBATCH} ctk=${INKLING_CACHE_TYPE}"
  # Run from build/bin so @rpath dylibs resolve.
  (
    cd "$(dirname "${bin}")"
    # shellcheck disable=SC2046,SC2207
    args=()
    while IFS= read -r line; do args+=("${line}"); done < <(llama_server_args)
    nohup ./$(basename "${bin}") "${args[@]}" >"${LOG_FILE}" 2>&1 &
    echo $! >"${PID_FILE}"
  )
  wait_for_server "${LOCAL_LLM_PORT}"
  if ! smoke_compute "${LOCAL_LLM_PORT}"; then
    echo "==> stopping server after compute failure (avoid poisoned Metal backend)" >&2
    stop_server || true
    exit 1
  fi
  echo "llama-server: ready (pid $(cat "${PID_FILE}"))"
  curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/v1/models" | head -c 400; echo
}

launchd_spec() {
  # One line per argv element for hermes-autostart.sh; keep in sync with start_server.
  local bin
  require_llama_server
  require_gguf
  oom_preflight
  bin="$(find_llama_server)"
  printf '%s\n' "${bin}"
  llama_server_args
}

stop_server() {
  # KeepAlive would respawn a plain kill; bootout keeps the plist for the next start.
  if inkling_managed_by_launchd; then
    echo "==> booting out launchd ${INKLING_LAUNCHD_LABEL} (re-enable: $0 start)"
    launchctl bootout "gui/$(id -u)" "${INKLING_PLIST}" 2>/dev/null || true
  fi
  if [ -f "${PID_FILE}" ]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "==> stopping llama-server pid ${pid}"
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
  fi
  local pids
  pids="$(lsof -nP -iTCP:"${LOCAL_LLM_PORT}" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "${pids}" ]; then
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null || true
  fi
  echo "inkling llama-server: stopped"
}

ufw_allow_host_llm() {
  require_vm
  # Reuse the same UFW allow pattern as Gemma (host.lima.internal:LOCAL_LLM_PORT).
  "${SCRIPTS}/hermes-gemma-local.sh" ensure-guest
}

enable_hermes() {
  require_vm
  ufw_allow_host_llm

  echo "==> routing Hermes primary to ${LOCAL_LLM_BASE_URL} (${INKLING_MODEL})"
  limactl shell "${HERMES_VM_NAME}" -- sudo env \
    INKLING_MODEL="${INKLING_MODEL}" \
    LOCAL_LLM_BASE_URL="${LOCAL_LLM_BASE_URL}" \
    LOCAL_LLM_CONTEXT="${INKLING_CTX}" \
    CURSOR_PROXY_BASE_URL="${CURSOR_PROXY_BASE_URL}" \
    CURSOR_FALLBACK_MODEL="${CURSOR_FALLBACK_MODEL}" \
    bash -s <<'OUTER_EOS'
set -eu
runuser -u hermes -- env \
  HOME=/srv/hermes \
  INKLING_MODEL="$INKLING_MODEL" \
  LOCAL_LLM_BASE_URL="$LOCAL_LLM_BASE_URL" \
  LOCAL_LLM_CONTEXT="$LOCAL_LLM_CONTEXT" \
  CURSOR_PROXY_BASE_URL="$CURSOR_PROXY_BASE_URL" \
  CURSOR_FALLBACK_MODEL="$CURSOR_FALLBACK_MODEL" \
  PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
  python3 <<'PY'
import os, yaml
from pathlib import Path

path = Path("/srv/hermes/.hermes/config.yaml")
cfg = yaml.safe_load(path.read_text())

model = cfg.setdefault("model", {})
model.update({
    "provider": "custom",
    "base_url": os.environ["LOCAL_LLM_BASE_URL"],
    "default": os.environ["INKLING_MODEL"],
    "api_key": "llama.cpp",
    "context_length": int(os.environ["LOCAL_LLM_CONTEXT"]),
})
model.pop("ollama_num_ctx", None)
model.pop("fallback_providers", None)
cfg.pop("fallback_model", None)
cfg["fallback_providers"] = [{
    "provider": "custom",
    "model": os.environ["CURSOR_FALLBACK_MODEL"],
    "base_url": os.environ["CURSOR_PROXY_BASE_URL"],
    "api_key": "not-needed",
}]

aux = cfg.setdefault("auxiliary", {})
for task, task_cfg in list(aux.items()):
    if not isinstance(task_cfg, dict):
        continue
    task_cfg.update({
        "provider": "custom",
        "base_url": os.environ["LOCAL_LLM_BASE_URL"],
        "model": os.environ["INKLING_MODEL"],
        "api_key": "llama.cpp",
    })

path.write_text(yaml.dump(cfg, default_flow_style=False, allow_unicode=True, sort_keys=False))
print("updated", path)
print("  model.default =", model.get("default"))
print("  model.base_url =", model.get("base_url"))
print("  context_length =", model.get("context_length"))
PY
OUTER_EOS

  "${SCRIPTS}/hermes-gateway.sh" ensure
}

test_inference() {
  require_vm
  echo "==> host smoke"
  curl -fsS --max-time 120 "http://127.0.0.1:${LOCAL_LLM_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${INKLING_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: inkling-ok\"}],\"max_tokens\":32,\"chat_template_kwargs\":{\"reasoning_effort\":\"low\"}}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message'].get('content') or d['choices'][0]['message'])"

  echo "==> VM → host smoke"
  limactl shell "${HERMES_VM_NAME}" -- bash -lc "
    set -eu
    curl -fsS --max-time 120 http://${LOCAL_LLM_HOST}:${LOCAL_LLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"${INKLING_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: inkling-ok\"}],\"max_tokens\":32,\"chat_template_kwargs\":{\"reasoning_effort\":\"low\"}}' \
      | python3 -c \"import sys,json; d=json.load(sys.stdin); print((d['choices'][0]['message'].get('content') or '')[:200])\"
  "
}

show_status() {
  echo "gguf: ${GGUF_PATH}"
  if [ -f "${GGUF_PATH}" ]; then
    ls -lh "${GGUF_PATH}"
  else
    echo "  (not downloaded)"
  fi
  if find_llama_server >/dev/null; then
    echo "llama-server: $(find_llama_server)"
  else
    echo "llama-server: (missing)"
  fi
  if server_running; then
    echo "server: up on :${LOCAL_LLM_PORT}"
    curl -fsS "http://127.0.0.1:${LOCAL_LLM_PORT}/v1/models" 2>/dev/null | head -c 500; echo
  else
    echo "server: down"
  fi
  if vm_running; then
    limactl shell "${HERMES_VM_NAME}" -- sudo runuser -u hermes -- \
      python3 -c "import yaml; c=yaml.safe_load(open('/srv/hermes/.hermes/config.yaml')); m=c.get('model',{}); print('hermes model:', m.get('default'), '@', m.get('base_url'), 'ctx', m.get('context_length'))" 2>/dev/null || true
  fi
}

cmd="${1:-status}"
case "${cmd}" in
  build-llama) build_llama ;;
  download) download_gguf ;;
  start) start_server ;;
  stop) stop_server ;;
  status) show_status ;;
  logs) tail -f "${LOG_FILE}" ;;
  enable-hermes) enable_hermes ;;
  test) test_inference ;;
  launchd-spec) launchd_spec ;;
  setup)
    download_gguf
    if ! find_llama_server >/dev/null; then
      build_llama
    fi
    start_server
    enable_hermes
    test_inference
    cat <<MSG

Inkling 2 Mini AD-IQ1_M is primary; Cursor auto is fallback.
  Host:     llama-server ${INKLING_MODEL} on 0.0.0.0:${LOCAL_LLM_PORT}
  GGUF:     ${GGUF_PATH}
  Primary:  ${LOCAL_LLM_BASE_URL}
  Logs:     ./scripts/hermes-inkling-local.sh logs
  Revert:   ./scripts/hermes-gemma-local.sh start && ./scripts/hermes-gemma-local.sh enable-hermes
MSG
    ;;
  *)
    echo "usage: $0 {setup|build-llama|download|start|stop|status|logs|enable-hermes|test|launchd-spec}" >&2
    exit 1
    ;;
esac
