#!/usr/bin/env bash
# Build and activate a slim Hermes terminal image (Node 24 + Python 3.12).
#
# Usage:
#   ./scripts/hermes-terminal-image.sh build    # build in-VM (rootless Docker)
#   ./scripts/hermes-terminal-image.sh activate # set terminal.docker_image + prune old
#   ./scripts/hermes-terminal-image.sh setup    # build + activate + restart gateway
#   ./scripts/hermes-terminal-image.sh status

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${HERMES_VM_REPO}/docker/hermes-terminal/Dockerfile"
: "${HERMES_TERMINAL_IMAGE:=hermes-terminal:node24-py312}"
GUEST_DIR="/srv/hermes/.hermes/docker/hermes-terminal"

vm_running() {
  limactl list | awk -v n="${HERMES_VM_NAME}" '$1==n{print $2}' | grep -q Running
}

require_vm() {
  if ! vm_running; then
    echo "VM ${HERMES_VM_NAME} is not running. Run ./scripts/start.sh first." >&2
    exit 1
  fi
}

as_hermes_docker() {
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes \
    env XDG_RUNTIME_DIR=/run/user/999 DOCKER_HOST=unix:///run/user/999/docker.sock \
      HOME=/srv/hermes PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
    bash -c "$1"
}

sync_dockerfile() {
  if [ ! -f "${DOCKERFILE}" ]; then
    echo "error: missing ${DOCKERFILE}" >&2
    exit 1
  fi
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes mkdir -p "${GUEST_DIR}"
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes tee "${GUEST_DIR}/Dockerfile" > /dev/null \
    < "${DOCKERFILE}"
}

build_image() {
  require_vm
  sync_dockerfile
  echo "==> building ${HERMES_TERMINAL_IMAGE} (rootless Docker)"
  as_hermes_docker "cd '${GUEST_DIR}' && docker build -t '${HERMES_TERMINAL_IMAGE}' ."
  as_hermes_docker "docker image inspect '${HERMES_TERMINAL_IMAGE}' --format 'built: {{.Id}} ({{.Size}} bytes)'"
}

activate_image() {
  require_vm
  echo "==> pinning terminal.docker_image=${HERMES_TERMINAL_IMAGE}"
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes \
    env HOME=/srv/hermes PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
    hermes config set terminal.docker_image "${HERMES_TERMINAL_IMAGE}"

  # Drop stopped sandboxes so the next tool call recreates on the new image.
  # Running containers are left alone (gateway may hold one briefly).
  echo "==> removing stopped hermes-* containers"
  as_hermes_docker '
    ids=$(docker ps -aq -f name=hermes- -f status=exited -f status=dead -f status=created 2>/dev/null || true)
    if [ -n "$ids" ]; then
      docker rm -f $ids >/dev/null
      echo "removed $(echo "$ids" | wc -w | tr -d " ") stopped container(s)"
    else
      echo "no stopped hermes-* containers"
    fi
  '
}

show_status() {
  require_vm
  echo "configured image: ${HERMES_TERMINAL_IMAGE}"
  limactl shell "${HERMES_VM_NAME}" -- sudo -u hermes \
    env HOME=/srv/hermes PATH=/srv/hermes/.local/bin:/usr/bin:/bin \
    hermes config get terminal.docker_image 2>/dev/null || true
  as_hermes_docker "
    docker images '${HERMES_TERMINAL_IMAGE}' || true
    echo '---'
    docker ps -a --filter name=hermes- --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | head -20
  "
  as_hermes_docker "
    if docker image inspect '${HERMES_TERMINAL_IMAGE}' >/dev/null 2>&1; then
      docker run --rm '${HERMES_TERMINAL_IMAGE}' bash -lc 'echo node=\$(node -v); echo npm=\$(npm -v); echo python=\$(python3 -V); echo pip=\$(pip3 -V)'
    fi
  "
}

case "${1:-status}" in
  build)
    build_image
    ;;
  activate)
    activate_image
    ;;
  setup)
    build_image
    activate_image
    "${SCRIPTS}/hermes-gateway.sh" ensure
    echo
    echo "Terminal image ready: ${HERMES_TERMINAL_IMAGE}"
    echo "Verify: ./scripts/hermes-terminal-image.sh status"
    ;;
  status)
    show_status
    ;;
  *)
    echo "usage: $0 {build|activate|setup|status}" >&2
    exit 1
    ;;
esac
