# hermes-in-a-box-on-macos — Project Context

## What this is
A hardened, security-isolated Ubuntu 24.04 LTS Server VM for running [Nous Research's Hermes Agent](https://github.com/NousResearch/hermes-agent) on macOS Apple Silicon. The host stays clean; all untrusted AI agent container workloads run inside the VM.

## Tech Stack
- **Hypervisor:** Lima 2.1.1+ with Apple Virtualization Framework (`vmType: vz`), native ARM64
- **Guest OS:** Ubuntu 24.04 LTS Server (cloud image, arm64)
- **Storage:** AES-256-GCM ZFS pool (`tank`) on a separate 200 GiB virtual disk
- **Containers:** Rootless Docker (`docker-ce-rootless-extras`), owned by unprivileged `hermes` user — no system dockerd
- **LLM backend:** Host Ollama `gemma4-hermes` (Gemma 4 12B QAT, 64K ctx); VM reaches via `host.lima.internal:11435`. Managed by `hermes-gemma-local.sh`. Optional Slack bot (Socket Mode).
- **Language:** Pure Bash — no package.json, no build system, no compiled code

## Repo Structure
```
ubuntu-hermes.yaml        # Lima VM spec + all cloud-init provisioning (single source of truth)
scripts/                  # operational Bash scripts
  env.sh                  # Shared env vars; sourced by all scripts
  setup.sh                # First-time provisioning entry point
  start.sh / stop.sh      # VM lifecycle
  shell.sh                # Interactive VM shell (host tmux session for SSH resume)
  host-shell-setup.sh     # One-time: tmux on Mac SSH login
  verify.sh               # Full hardening test suite
  backup.sh / restore.sh  # APFS clonefile VM snapshots
  destroy.sh              # Destructive teardown
  keyfile-backup.sh / keyfile-restore.sh  # ZFS encryption key management
  hermes-install.sh       # One-time: rootless Docker + Hermes Agent (PyPI/uv)
  hermes-update.sh        # Pin or upgrade Hermes Agent PyPI version
  hermes-config.sh        # Upsert secrets into VM .env (never touches host disk)
  hermes-env-edit.sh      # Open .env in $EDITOR inside the VM
  hermes-gateway.sh       # Manage hermes-gateway.service
  hermes-gemma-local.sh   # Host Ollama + Gemma 4 12B QAT backend (default)
  hermes-cursor-proxy.sh  # Legacy Cursor Agent API proxy
  hermes-model.sh         # OpenRouter model picker (legacy)
  hermes.sh               # Run any hermes subcommand as the hermes user
  list-free-models.sh     # Query OpenRouter for free tool-use models
README.md                 # Operations manual
```

## Key Env Vars
- `HERMES_VM_HOME` — host-side root for all VM state (default: `$HOME/hermes-vm-data`)
- `LIMA_HOME` — `$HERMES_VM_HOME/lima`
- `HERMES_VM_NAME` — Lima instance name (default: `ubuntu-hermes`)
- `HERMES_VERSION` — pinned PyPI version (default: `0.16.0`)
- `GEMMA_BASE_MODEL` — Ollama weights tag to pull (default: `gemma4:12b-it-qat`)
- `GEMMA_MODEL` — local alias Hermes routes to (default: `gemma4-hermes`)
- `LOCAL_LLM_PORT` — host Ollama port (default: `11435`)
- `LOCAL_LLM_CONTEXT` — Ollama/Hermes context window (default: `65536`)
- `HERMES_SHELL_SESSION` / `HERMES_HOST_SHELL_SESSION` — tmux session names

## Provisioning
`ubuntu-hermes.yaml` contains ordered cloud-init `provision:` blocks (system mode), all idempotent. Covers: apt upgrades, SSH hardening, DNS, ZFS, rootless Docker, `hermes` user, systemd units, UFW.

## Security Architecture (5 layers)
1. Hermes Agent's own approval/blocklist
2. Unprivileged `hermes` user (no sudo, no privileged groups; owns only `/srv/hermes`, `/var/lib/hermes`, `/var/log/hermes`)
3. `hermes-gateway.service` systemd hardening: `ProtectSystem=strict`, `ProtectHome=read-only`, empty `CapabilityBoundingSet`, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`
4. Rootless Docker per tool call: `--cap-drop ALL`, `--security-opt no-new-privileges`, `--pids-limit 256`, `noexec` tmpfs
5. UFW outbound-only allowlist (53/80/443/123), LAN blocked (`10/8`, `172.16/12`, `192.168/16`); host Ollama egress added dynamically by `hermes-gemma-local.sh`

## Known Platform Quirks / Workarounds
- **`cloud-final.service` exits 1** — Lima's `05-lima-disks.sh` tries `mount -t ext4` on a ZFS member → fixed with a `SuccessExitStatus=1` systemd drop-in
- **`%U` in systemd `Environment=`** resolves as root UID 0, not `hermes` UID → hardcoded as UID 999
- **`limactl start` timeout** — "did not receive running status" even when VM is healthy → `setup.sh` detects and ignores this
- **Lima-level snapshots are broken** on the `vz` backend → use APFS `cp -c` (clonefile) for host-level backups; ZFS dataset snapshots (`tank@hardened-baseline`) for data rollback
- **Homebrew Ollama 0.30.x** omits `llama-server` → install Ollama.app cask; `hermes-gemma-local.sh` symlinks the binary

## Secrets Handling
Secrets never touch host disk. `hermes-config.sh` pipes values via stdin into the VM's `/srv/hermes/.hermes/.env`.
