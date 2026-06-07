# hermes-vm

A hardened Ubuntu 24.04 LTS Server VM for running container-based agent
workloads (Hermes runtime) on a macOS Apple Silicon host. Boots from a cloud
image under Lima with the Apple Virtualization Framework backend, has no LAN
access, an encrypted ZFS data pool, and is fully unattended after first
provisioning.

> **Note for AI agents:** If you are an AI coding agent (Claude Code or
> similar) reading this to extend or troubleshoot the setup, start with
> [`AGENTS.md`](./AGENTS.md) and [`ubuntu-hermes.yaml`](./ubuntu-hermes.yaml)
> — the single source of truth for provisioning — and the wrappers under
> [`scripts/`](./scripts/). Then read [Section D Troubleshooting](#troubleshooting) before making any
> changes. Hard constraints:
>
> 1. Do **not** run `limactl factory-reset` without first backing up
>    `/etc/zfs/tank.key` (use `./scripts/keyfile-backup.sh`). The encrypted
>    `tank` pool persists across factory-reset but becomes unrecoverable
>    forever without the original keyfile.
> 2. All in-VM provisioning must remain idempotent. Re-running
>    `limactl start` or re-applying a step should never destroy state.
>    Follow the existing patterns in `ubuntu-hermes.yaml` (every step
>    guards with `[ -f ... ]`, `id ... >/dev/null 2>&1 ||`,
>    `zpool list ... ||`, etc.).
> 3. Never hardcode host paths in the YAML or scripts. Configuration goes
>    through the `HERMES_VM_HOME` / `LIMA_HOME` environment variables
>    (see [Configuration](#configuration)).

---

## Table of contents

- [A. Prerequisites](#a-prerequisites)
- [B. Motivation, principles, tech](#b-motivation-principles-tech)
- [C. Requirements and recommended setup](#c-requirements-and-recommended-setup)
- [D. Detailed setup and troubleshooting](#d-detailed-setup-and-troubleshooting)
  - [Scripts](#scripts)
  - [Configuration](#configuration)
  - [Step-by-step setup from scratch](#step-by-step-setup-from-scratch)
  - [Verification](#verification)
  - [Installing Hermes Agent](#installing-hermes-agent)
  - [Daily use](#daily-use)
  - [Snapshot strategy](#snapshot-strategy)
  - [Troubleshooting](#troubleshooting)
    - [hermes-gateway.service fails immediately (stale lock)](#hermes-gateway-service-fails-to-start-immediately-exit-code-after-1-second)
    - [hermes-gateway.service pre-check hangs 30 s (%U bug)](#hermes-gateway-service-pre-check-hangs-for-30-seconds-then-fails)
    - [Local Ollama / Gemma inference fails](#local-ollama--gemma-inference-fails)
    - [OpenRouter 429 — is my API key missing?](#openrouter-429-add-your-own-key--is-the-api-key-missing)
    - [Slack bot never responds (Socket Mode disabled)](#slack-bot-connected-but-never-responds-to-messages)
    - [Slack bot rejects your messages (Unauthorized user)](#slack-bot-receives-messages-but-rejects-them-unauthorized-user)
    - [Agent advises editing config.yaml for secrets](#hermes-agent-gives-advice-about-editing-configyaml-for-slack--api-keys)
    - [Agent asks for sudo password](#hermes-agent-asks-for-the-sudo-password)
    - [Agent diagnoses wrong config files](#hermes-agent-diagnoses-the-wrong-config-files-wrong-user-context)
- [E. Appendix: install prerequisites](#e-appendix-install-prerequisites)

---

## A. Prerequisites

Required on the macOS host before starting. Install instructions are in the
[Appendix](#e-appendix-install-prerequisites).

- macOS on Apple Silicon (M1/M2/M3/M4).
- Homebrew.
- Lima 2.1.1 or newer (`limactl`, `lima`).
- `jq` (used by some validation commands).
- An APFS volume with at least 300 GiB free for the VM bundle. An external
  SSD is strongly recommended.
- This repo cloned to a writable directory.

---

## B. Motivation, principles, tech

This VM exists to give an agent (or a person) a security-isolated workspace
for running untrusted container workloads without polluting the macOS host —
the host stays clean, the guest is disposable, and the data partition is
encrypted at rest. The design principles are: idempotent cloud-init
provisioning (re-running never destroys state), no LAN access (the VM cannot
reach `192.168.0.0/16`, `10.0.0.0/8`, or `172.16.0.0/12`), encrypted data
(AES-256-GCM ZFS pool, keyfile auto-loaded at boot), snapshot rollback (ZFS
dataset snapshots plus APFS `cp -c` clone-on-write of the whole VM), and
minimal host integration (no shared mounts, no clipboard, no agent
forwarding). The stack is Lima 2.1.1 with the Apple Virtualization Framework
(`vmType: vz`) on Apple Silicon, an Ubuntu 24.04 LTS Server cloud image
(arm64), a 200 GiB encrypted ZFS pool (`tank`) holding three Hermes
datasets (`tank/hermes`, `tank/hermes-var`, `tank/hermes-log`), no
system Docker daemon (Hermes brings its own rootless dockerd, owned by
the unprivileged `hermes` user), host Ollama for local LLM inference
(Gemma 4 12B QAT via `gemma4-hermes` on port 11435; the VM reaches the
host at `host.lima.internal`), and UFW deny-all-by-default with an
explicit allow-list (53/80/443/123 outbound, 22 inbound for `limactl
shell`; host-Ollama egress is added at runtime by `hermes-gemma-local.sh`).

---

## C. Requirements and recommended setup

### Required

- **Host CPU:** Apple Silicon (M1/M2/M3/M4). Intel Macs are not supported by
  this configuration.
- **Host RAM:** at least 16 GiB.
- **Host disk:** an APFS volume with at least 300 GiB free for the VM
  bundle (60 GiB rootfs + 200 GiB data disk + overhead + APFS clone
  snapshots). An external SSD is strongly recommended so the bundle stays
  off the internal drive.

### Recommended sizing

If the host is mostly used to drive the agent inside this VM, dedicate
roughly 80 % of host CPU cores and 75 % of host RAM to the guest. As an
example, on a 10-core / 16 GiB host that is `cpus: 8`, `memory: "12GiB"`,
leaving 4 GiB for macOS — those are the values shipped in
`ubuntu-hermes.yaml`. Adjust both fields proportionally for your hardware.

### Emergency power-down (one-liner)

```bash
./scripts/stop.sh
```

The host immediately reclaims the CPU and RAM allocation. VM state is
preserved on disk and resumes with `./scripts/start.sh`.

---

## D. Detailed setup and troubleshooting

### Scripts

Every operation has a wrapper under [`./scripts/`](./scripts/). The wrappers
read configuration from a shared `env.sh` and never hardcode host paths, so
the same scripts work on any machine that meets the prerequisites.

| Script | Purpose |
| --- | --- |
| [`setup.sh`](./scripts/setup.sh) | First-time setup: storage layout, pre-create tank disk, start VM. Idempotent. |
| [`verify.sh`](./scripts/verify.sh) | Run all hardening checks. Exit 0 on full pass. |
| [`shell.sh`](./scripts/shell.sh) | Open an interactive shell in the VM, or run a one-off command. Interactive mode uses a persistent host **tmux** session (survives SSH disconnect). |
| [`host-shell-setup.sh`](./scripts/host-shell-setup.sh) | One-time: auto-attach **tmux** on SSH login to the Mac host so remote shells resume after disconnect. |
| [`start.sh`](./scripts/start.sh) | Resume the VM. |
| [`stop.sh`](./scripts/stop.sh) | Power down the VM (preserves state). |
| [`backup.sh`](./scripts/backup.sh) | Cold-copy backup of disk + datadisk + lima.yaml using APFS clonefile. |
| [`restore.sh`](./scripts/restore.sh) `<name>` | Restore from a backup directory under `${HERMES_VM_HOME}/backups/`. |
| [`keyfile-backup.sh`](./scripts/keyfile-backup.sh) | Export the ZFS encryption keyfile to base64 outside the VM. |
| [`keyfile-restore.sh`](./scripts/keyfile-restore.sh) | Restore the keyfile after a factory-reset. |
| [`destroy.sh`](./scripts/destroy.sh) | DESTRUCTIVE: tear down VM and tank disk (with confirmation). |
| [`hermes-install.sh`](./scripts/hermes-install.sh) | One-time: install Hermes Agent from PyPI into a `uv`-managed venv at `~/.hermes/venv/`, set up rootless dockerd, configure `terminal.backend=docker`. Idempotent. |
| [`hermes-update.sh`](./scripts/hermes-update.sh) | Upgrade (or pin) the Hermes Agent PyPI version: `./scripts/hermes-update.sh 0.16.0`. No-ops if already at target. Agent state/config/memory survive. |
| [`hermes-config.sh`](./scripts/hermes-config.sh) | Prompt for an API key name and value; upsert into `/srv/hermes/.hermes/.env` via stdin — value never appears in `ps` or on host disk. |
| [`hermes-env-edit.sh`](./scripts/hermes-env-edit.sh) | Open `/srv/hermes/.hermes/.env` in `$EDITOR` (vi/vim/nano/emacs) inside the VM as the `hermes` user. Preserves ownership and 0600 mode. |
| [`hermes-gateway.sh`](./scripts/hermes-gateway.sh) | Manage `hermes-gateway.service` (start / stop / restart / status / logs / enable / disable). |
| [`hermes-gemma-local.sh`](./scripts/hermes-gemma-local.sh) | **Default LLM backend:** host Ollama with Gemma 4 12B QAT (`gemma4-hermes` alias, 64K ctx). Subcommands: `setup`, `start/stop/status/logs`, `enable-hermes`, `purge-vm`, `test`. Stops in-VM Ollama and Cursor proxy. |
| [`hermes-cursor-proxy.sh`](./scripts/hermes-cursor-proxy.sh) | *(Legacy)* Cursor Agent API proxy (`hermes-cursor-proxy.service`, port 4646). Not used when `hermes-gemma-local.sh setup` is active. |
| [`hermes-model.sh`](./scripts/hermes-model.sh) | *(Legacy)* Interactive OpenRouter model picker; writes `model.default` and fallbacks to `config.yaml`. |
| [`hermes.sh`](./scripts/hermes.sh) | Run any `hermes` subcommand as the `hermes` user inside the VM (e.g. `./scripts/hermes.sh chat`). |
| [`list-free-models.sh`](./scripts/list-free-models.sh) | Query OpenRouter live for free models that support tool use; prints model ID and context length. |

### Configuration

All scripts source [`scripts/env.sh`](./scripts/env.sh), which respects:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HERMES_VM_HOME` | `${HOME}/hermes-vm-data` | Root for VM bundle, disks, backups. Point at your APFS volume of choice. |
| `LIMA_HOME` | `${HERMES_VM_HOME}/lima` | Lima's instance directory. |
| `HERMES_VM_NAME` | `ubuntu-hermes` | Lima instance name. |
| `TANK_SIZE` | `200GiB` | Size of the encrypted data disk (used by `setup.sh` only on first run). |
| `HERMES_VERSION` | `0.16.0` | PyPI version passed to `hermes-install.sh` and `hermes-update.sh`. Override on the command line: `HERMES_VERSION=0.16.0 ./scripts/hermes-update.sh`. |
| `GEMMA_BASE_MODEL` | `gemma4:12b-it-qat` | Ollama weights pulled by `hermes-gemma-local.sh`. |
| `GEMMA_MODEL` | `gemma4-hermes` | Local Ollama alias (base model + `num_ctx`); Hermes routes here. |
| `LOCAL_LLM_PORT` | `11435` | Host Ollama port (11434 is reserved for Lima's in-VM forward). |
| `LOCAL_LLM_CONTEXT` | `65536` | Context window for Hermes 0.16+ tool use (requires ≥64K). |
| `HERMES_SHELL_SESSION` | `hermes-vm` | Host tmux session name used by interactive `shell.sh`. |
| `HERMES_HOST_SHELL_SESSION` | `hermes-host` | Host tmux session name for SSH logins (after `host-shell-setup.sh install`). |
| `HERMES_SHELL_TMUX` | `1` | Set to `0` to disable host tmux wrapping in `shell.sh`. |

Set `HERMES_VM_HOME` to your APFS volume (external SSD strongly recommended)
and persist it in your shell rc:

```bash
export HERMES_VM_HOME="/path/to/apfs/volume/hermes-vm"

# zsh
echo "export HERMES_VM_HOME=\"$HERMES_VM_HOME\"" >> ~/.zshrc

# bash
echo "export HERMES_VM_HOME=\"$HERMES_VM_HOME\"" >> ~/.bashrc
```

You do not need to export `LIMA_HOME` separately — `env.sh` derives it from
`HERMES_VM_HOME`. If you have an existing Lima setup at `~/.lima` you want
to keep, set `LIMA_HOME` explicitly.

### Step-by-step setup from scratch

Assumes the [Appendix](#e-appendix-install-prerequisites) prerequisites are
already installed.

1. Set `HERMES_VM_HOME` (see [Configuration](#configuration)).
2. Clone this repo and `cd` into it.
3. Run setup:

   ```bash
   ./scripts/setup.sh
   ```

   The script:
   - Creates `${HERMES_VM_HOME}/lima` and `${HERMES_VM_HOME}/backups`.
   - Pre-creates the `tank` disk via `limactl disk create` (REQUIRED — Lima's
     `additionalDisks:` does **not** auto-create disks; skipping this step
     is the single most common first-run mistake).
   - Calls `limactl start --tty=false ubuntu-hermes.yaml`. First run takes
     ~5–10 min for the image download + provisioning.

   > **Note:** Lima may exit non-zero with `did not receive an event with the
   > running status` after about 10 minutes on instances whose cached cidata
   > uses an older boot probe. The VM is in fact running. `setup.sh` detects
   > this and continues; if you hit it manually, see
   > [the relevant troubleshooting entry](#limactl-start-hangs-for-10-minutes-then-exits-with-did-not-receive-running).

After `setup.sh` returns, run [`verify.sh`](#verification) to confirm
the security posture. Then install Hermes and the local LLM backend:

```bash
./scripts/hermes-install.sh              # rootless docker + Hermes Agent (PyPI)
./scripts/hermes-gemma-local.sh setup    # host Ollama, pull Gemma, route Hermes locally
./scripts/hermes.sh chat -Q -q "hello"   # quick non-interactive smoke test
```

For cloud models (OpenRouter or Cursor) instead of local Gemma, see
[Installing Hermes Agent](#installing-hermes-agent) and the legacy scripts
`hermes-model.sh` / `hermes-cursor-proxy.sh`.

### Verification

```bash
./scripts/verify.sh
```

Runs the full hardening test suite (internet reachable, LAN unreachable,
UFW posture, no system dockerd, rootless dockerd up for hermes, ZFS
health, key auto-load, fail2ban / unattended-upgrades / cloud-final
silencer, plus a Hermes hardening regression block: hermes not in any
privileged group, cannot write `/etc`, cannot disable UFW, cannot read
`/etc/zfs/tank.key`, sshd hardening directives intact). Prints `PASS` /
`FAIL` per check and exits 0 only on full pass.

If you want to inspect the same things by hand:

```bash
./scripts/shell.sh                                    # interactive shell

# Internet reachable
curl -fsS https://google.com -o /dev/null && echo OK

# LAN unreachable (all three should fail)
ping -c 1 -W 2 192.168.1.1 ; echo "exit=$?"
ping -c 1 -W 2 10.0.0.1    ; echo "exit=$?"
ping -c 1 -W 2 172.16.0.1  ; echo "exit=$?"

# Firewall posture
sudo ufw status verbose

# Rootless Docker (only after ./scripts/hermes-install.sh has run)
sudo -iu hermes docker info | grep -i rootless     # → "rootless"
[ ! -S /var/run/docker.sock ] && echo "no system dockerd, good"

# ZFS pool + snapshots
zpool status tank
zfs list -t snapshot -r tank

# Core services
systemctl is-active fail2ban unattended-upgrades cloud-final.service
```

### Installing Hermes Agent

[Nous Research's Hermes Agent](https://github.com/NousResearch/hermes-agent)
runs inside the VM as the unprivileged `hermes` user, with five
defense-in-depth layers between agent-emitted commands and the host's
hardening.

```bash
./scripts/hermes-install.sh              # one-time: rootless docker + hermes binary (PyPI)
./scripts/hermes-gemma-local.sh setup    # recommended: host Ollama + Gemma 4 12B QAT
./scripts/hermes.sh chat                 # interactive
./scripts/hermes-gateway.sh start        # optional: long-running daemon (Slack, etc.)
./scripts/hermes-gateway.sh logs         # follow daemon logs
```

`hermes-gemma-local.sh setup` installs host Ollama, pulls `gemma4:12b-it-qat`,
creates a local `gemma4-hermes` alias with 64K context (required by Hermes
0.16+), disables in-VM cloud/local LLM backends, and routes all Hermes model
calls to `http://host.lima.internal:11435/v1`. No OpenRouter API key is
needed for chat when this backend is active.

For **cloud inference** instead, set an API key and pick a model:

```bash
./scripts/hermes-config.sh               # set OPENROUTER_API_KEY (prompted, never on host disk)
./scripts/hermes-model.sh                # interactive OpenRouter model picker
./scripts/hermes-gateway.sh start        # start the long-running daemon (optional)
```

`hermes-install.sh` is idempotent — it installs the pinned `HERMES_VERSION` from
PyPI into a `uv`-managed venv at `~/.hermes/venv/` and creates a shim at
`~/.local/bin/hermes`. To upgrade to a newer release:

```bash
./scripts/hermes-update.sh 0.16.0        # upgrade in-place; state/config/memory preserved
```

`hermes-config.sh` prompts for a key name (default `OPENROUTER_API_KEY`) and
value; the value is piped via stdin so it is never visible in `ps`. Only
needed when using OpenRouter or other cloud backends — not for local Gemma.

The gateway daemon is shipped disabled. Start it manually when you need
Slack, webhooks, or other always-on integrations:
`./scripts/hermes-gateway.sh start`. Logs follow with
`./scripts/hermes-gateway.sh logs`.

**Layered sandbox**

1. **Hermes app-layer guards** (always on) — approval system, hardline
   blocklist, path-write protection, SSRF protection.
2. **`hermes` user boundary** — no sudo, no privileged groups, owns only
   `/srv/hermes`, `/var/lib/hermes`, `/var/log/hermes` (encrypted ZFS).
3. **systemd unit hardening** — `hermes-gateway.service` runs with
   `ProtectSystem=strict`, `ProtectHome=read-only`, empty
   `CapabilityBoundingSet`, `SystemCallFilter=@system-service`,
   `MemoryDenyWriteExecute`, `RestrictAddressFamilies=AF_UNIX AF_INET
   AF_INET6`. Drops `CAP_NET_ADMIN` (cannot modify UFW) and
   `CAP_NET_BIND_SERVICE` (cannot bind <1024 to hijack ssh).
4. **Rootless dockerd container per tool call** — `terminal.backend=docker`.
   Container UID 0 maps to hermes's subuid 100000, never host root.
   `--cap-drop ALL`, `--security-opt no-new-privileges`, `--pids-limit
   256`, tmpfs `/tmp` with `noexec,nosuid` (Hermes's own defaults).
5. **UFW outbound 53/80/443/123 only + LAN deny** — applies to container
   traffic too (slirp4netns egresses via the host network namespace).

`./scripts/verify.sh` enforces all of the above with regression checks
for: no system dockerd, rootless dockerd up for hermes, hermes not in
any privileged group, hermes cannot write `/etc`, UFW default policy
unchanged, sshd hardening directives unchanged, hermes cannot disable
UFW, hermes cannot read `/etc/zfs/tank.key`.

### Daily use

```bash
# VM lifecycle
./scripts/start.sh                                       # resume the VM
./scripts/stop.sh                                        # power down (preserves state)
./scripts/shell.sh                                       # interactive shell as root
./scripts/shell.sh -- sudo -iu hermes docker ps          # rootless docker as hermes

# Hermes Agent
./scripts/hermes.sh chat                                 # interactive chat session
./scripts/hermes.sh --version                            # print agent version
./scripts/hermes.sh config show                          # show current config
./scripts/hermes.sh status                               # API keys, gateway, platforms
./scripts/hermes-gateway.sh status                       # gateway daemon state
./scripts/hermes-gateway.sh start                        # start gateway daemon
./scripts/hermes-gateway.sh restart                      # restart (picks up .env changes)
./scripts/hermes-gateway.sh logs                         # follow daemon logs
./scripts/hermes-gateway.sh stop                         # stop daemon

# Configuration and secrets
./scripts/hermes-config.sh                               # upsert a key into .env (prompted)
./scripts/hermes-env-edit.sh                             # open .env in $EDITOR inside the VM
./scripts/list-free-models.sh                            # list free OpenRouter models with tool support

# Upgrading the agent
./scripts/hermes-update.sh 0.16.0                        # upgrade to a specific PyPI version

# Local LLM (Gemma 4 12B QAT on host — recommended)
./scripts/hermes-gemma-local.sh setup                    # one-shot: install Ollama, pull model, purge cloud backends, enable
./scripts/hermes-gemma-local.sh status                   # host Ollama + Hermes routing
./scripts/hermes-gemma-local.sh test                     # smoke test VM → host inference
./scripts/hermes-gemma-local.sh start                    # start host Ollama after reboot

# Snapshots
./scripts/shell.sh -- sudo zfs snapshot -r tank@before-experiment-$(date +%Y%m%d)
./scripts/backup.sh                                      # full APFS clone of VM + data disk
```

`HERMES_VM_HOME` (and therefore `LIMA_HOME`) must be set in every shell
that talks to the VM. Persist both in your shell rc:

```bash
# bash
echo 'export HERMES_VM_HOME="/path/to/apfs/volume/hermes-vm"' >> ~/.bashrc
echo 'export LIMA_HOME="$HERMES_VM_HOME/lima"' >> ~/.bashrc
```

### Snapshot strategy

> **Warning:** `limactl snapshot create / apply / delete` is **not
> implemented for the vz backend.** The command exists but errors out.
> Treat Lima-level snapshots as unavailable on this host.

Two working strategies replace it.

#### Data rollback (ZFS dataset)

A recursive snapshot named `hardened-baseline` is taken at provisioning
time as `tank@hardened-baseline`. To roll back a single dataset:

```bash
./scripts/shell.sh -- sudo zfs rollback tank/hermes@hardened-baseline
```

Substitute `tank/hermes-var` or `tank/hermes-log` as needed. Take new
named snapshots before risky changes:

```bash
./scripts/shell.sh -- sudo zfs snapshot -r tank@before-experiment-2026-05-09
```

#### Full VM rollback (APFS clonefile)

[`backup.sh`](./scripts/backup.sh) stops the VM, copies the disk, datadisk,
`lima.yaml`, and the repo YAML into `${HERMES_VM_HOME}/backups/<timestamp>/`
using APFS `cp -c` (clonefile), then starts the VM again. On APFS the
copy is essentially free until a file diverges.

```bash
./scripts/backup.sh
```

To restore from a previous backup:

```bash
ls "${HERMES_VM_HOME}/backups/"             # see available timestamps
./scripts/restore.sh 20260509-120000        # use one
```

`restore.sh` stops the VM, requires explicit `restore` confirmation, then
clones the backed-up files back over the live ones and restarts.

> **Note:** `cp -c` only works between paths on the same APFS volume. If
> you need to keep backups on a different filesystem, copy the resulting
> backup directory out with `cp` or `tar` after `backup.sh` finishes.

### Troubleshooting

One subsection per recurring failure.

#### `cloud-final.service` reports an error every boot

Lima's `05-lima-disks.sh` hardcodes `mount -t ext4 /dev/vdb1`. On this VM
`/dev/vdb1` is a ZFS pool member, not an ext4 partition, so the mount
call exits non-zero and `cloud-final.service` records a failure in
`systemctl status`. Provisioning is unaffected — Lima's `boot.sh` writes
`/run/lima-boot-done` at the end of its boot chain regardless of
per-script failures, which is why this YAML probes that file instead of
`cloud-init status --wait`.

Functional impact: zero. The error is a cosmetic systemd state.

The silencer is provision step #6 in `ubuntu-hermes.yaml` (between the ZFS
step and the Hermes runtime user step). It installs a systemd drop-in at
`/etc/systemd/system/cloud-final.service.d/swallow-exit.conf` containing
`[Service]\nSuccessExitStatus=1`, which tells systemd to treat
`cloud-final.service`'s exit-1 as success. Result: `systemctl --failed`
lists 0 units, `systemctl is-active cloud-final.service` reports `active`,
nothing downstream sees a failure.

`cloud-init status` still prints `error - done` because cloud-init writes
its own status file independently of systemd's unit state. That string is
purely a status-file artefact at this point and does not propagate to any
service or boot dependency.

The silencer lives on the rootfs (not the cached cidata), so it survives
`limactl stop && limactl start`. Don't `limactl factory-reset` to "reapply"
the YAML cleanly — that would also wipe `/etc/zfs/tank.key` and lock the
encrypted pool forever.

#### `limactl start` hangs for 10 minutes then exits with "did not receive running"

Lima's hostagent waits for a probe to succeed before reporting the
instance as `Running`. Two probe strategies have been used here:

- **Current** (`ubuntu-hermes.yaml` ships this): `until [ -f
  /run/lima-boot-done ]; do sleep 1; done`. Reliable, because Lima writes
  this file unconditionally at the end of its boot script chain.
- **Older** (`cloud-init status --wait`): blocks on cloud-final, which
  inherits the cosmetic ZFS-vs-ext4 failure described above and never
  reports success — so the probe times out at 10 minutes and Lima
  declares the instance unhealthy even though it is fully booted.

Existing instances first created under the older probe carry it in their
cached cidata. New instances built from the current YAML use the better
probe and will not time out. To force the new probe on an existing
instance you have to recreate it, which implies the
[factory-reset / keyfile-backup procedure
below](#i-want-to-factory-reset-to-apply-yaml-changes).

If `limactl start` does time out, verify the VM is actually up:

```bash
limactl list
./scripts/shell.sh -- uptime
```

If the shell works, ignore the cosmetic timeout. `start.sh` already
detects this case and continues without erroring.

#### ZFS datasets unmounted after reboot, services start on empty mount points

Symptom: after a reboot, `/srv/hermes`, `/var/lib/hermes`, and
`/var/log/hermes` are empty (or owned by `root` with no contents); the
`hermes` user's rootless dockerd fails to start, and any service that
depends on hermes's home (the gateway daemon, the Hermes binary at
`/srv/hermes/.local/bin/hermes`) errors out.

Root cause: Ubuntu ships an empty stub at
`/lib/systemd/system/zfs-load-key.service` (effectively masked). With
`keylocation=file:///etc/zfs/tank.key`, the encrypted datasets need an
explicit `zfs load-key -a` after `zfs-import.target` and before
`zfs-mount.service`, otherwise `zfs-mount.service` skips the locked
datasets and the rootless docker daemon starts on top of an empty
`/srv/hermes`.

`ubuntu-hermes.yaml` installs a real unit at
`/etc/systemd/system/zfs-load-key.service` (ordered `After=zfs-import.target`,
`Before=zfs-mount.service`, `WantedBy=zfs-mount.service`). To recover:

```bash
./scripts/shell.sh -- sudo systemctl status zfs-load-key.service
./scripts/shell.sh -- sudo zfs load-key -a
./scripts/shell.sh -- sudo zfs mount -a
./scripts/shell.sh -- sudo -iu hermes systemctl --user restart docker
./scripts/hermes-gateway.sh restart
```

If the unit is missing or empty, re-run the ZFS provision step from
`ubuntu-hermes.yaml` (it is idempotent — the keyfile and pool are not
recreated if they already exist) or recreate the unit by hand from the
text in the YAML.

#### I want to factory-reset to apply YAML changes

> **Warning:** `limactl factory-reset` wipes the rootfs **and the keyfile
> at `/etc/zfs/tank.key`**. The encrypted `tank` data disk persists on
> disk but is **unrecoverable forever** without that exact keyfile. There
> is no recovery procedure. Back the keyfile up first.

Backup procedure (run while the current VM is alive):

```bash
./scripts/keyfile-backup.sh
# writes ${HERMES_VM_HOME}/tank.key.b64 (mode 0400)
```

The output file is the only thing standing between you and the encrypted
contents of the data disk. Move it to private storage (password manager
attachment, hardware key vault, encrypted USB) — do not commit it to git
and do not leave it next to the VM bundle.

Restore procedure (run after factory-reset / re-provision, before any
attempt to import the existing `tank` pool):

```bash
./scripts/keyfile-restore.sh
# reads ${HERMES_VM_HOME}/tank.key.b64 by default; pass another path as arg 1
```

`keyfile-restore.sh` writes the key inside the VM with mode 0400 and
calls `zfs load-key -a` followed by `zfs mount -a`. After restore, the
hermes user's rootless dockerd will pick up the now-mounted home on its
next start (or restart it manually with
`./scripts/shell.sh -- sudo -iu hermes systemctl --user restart docker`).

#### Lima YAML rejected with `unknown field "description"`

Lima's strict YAML schema does not accept `description:` as a field on
items inside `provision:`. Use `#` comments above the script instead:

```yaml
provision:
  # Install security packages.
  - mode: system
    script: |
      ...
```

#### Lima YAML rejected with `mountType must not be one of ... mountTypesUnsupported`

`mountTypesUnsupported` conflicts with Lima's default
`mountType: virtiofs`. With `mounts: []` the field is unnecessary —
remove it. The current YAML does not set it.

#### How do I see boot logs / debug a failure?

Two log surfaces, host and guest:

```bash
# Host side — Lima's serial-console capture
ls "${LIMA_HOME}/${HERMES_VM_NAME:-ubuntu-hermes}"/serial*.log
tail -F "${LIMA_HOME}/${HERMES_VM_NAME:-ubuntu-hermes}/serial.log"

# Guest side — the journal for the current boot
./scripts/shell.sh -- sudo journalctl -b 0 --no-pager
./scripts/shell.sh -- sudo journalctl -u cloud-final --no-pager
./scripts/shell.sh -- sudo journalctl -u zfs-load-key --no-pager
./scripts/shell.sh -- sudo journalctl -u hermes-gateway --no-pager
./scripts/shell.sh -- sudo -iu hermes journalctl --user -u docker --no-pager   # rootless dockerd
```

#### `hermes-gateway.service` fails to start immediately (exit-code after ~1 second)

Symptom: `systemctl status hermes-gateway.service` shows the main process
exiting with `status=1/FAILURE` within a second of starting — no 30-second
pre-check timeout.

The `ExecStartPre` pre-check passed but `hermes gateway` exited with:

```
❌ Gateway already running (PID <N>).
   Use 'hermes gateway restart' to replace it, or 'hermes gateway stop' to kill it first.
```

Root cause: a previous manually-started gateway process (e.g. from a
debugging session) is still running and holding the lock. The service's
restart loop keeps failing against it.

Fix:

```bash
# Find and kill the stale process
./scripts/shell.sh -- sudo bash -c 'pkill -u hermes -f "hermes gateway" || true'
./scripts/hermes-gateway.sh start
```

#### `hermes-gateway.service` pre-check hangs for 30 seconds then fails

Symptom: `journalctl -u hermes-gateway.service` shows the service starting,
waiting ~30 seconds, then `ExecStartPre` exiting with `status=1/FAILURE`.
The `ExecStart` line never appears.

Root cause: systemd's `%U` specifier in `Environment=` lines resolves in the
system (root) context, yielding UID 0, not the UID of `User=hermes`. The
pre-check therefore tests `/run/user/0/docker.sock`, which does not exist.
This bug is fixed in `ubuntu-hermes.yaml` (hardcoded UID 999 and `id -u
hermes` at exec time). If the live service file pre-dates the fix, apply it
manually:

```bash
./scripts/shell.sh -- sudo sed -i \
  's|/run/user/%U|/run/user/999|g' \
  /etc/systemd/system/hermes-gateway.service
./scripts/shell.sh -- sudo sed -i \
  "s|until test -S \"\\\$XDG_RUNTIME_DIR/docker.sock\"|until test -S \"/run/user/\$(id -u hermes)/docker.sock\"|" \
  /etc/systemd/system/hermes-gateway.service
./scripts/shell.sh -- sudo systemctl daemon-reload
./scripts/hermes-gateway.sh start
```

#### Local Ollama / Gemma inference fails

Symptoms include HTTP 500 from Ollama, `llama-server binary not found`, or
Hermes errors about context below 64K / response truncation.

**`llama-server binary not found` (Homebrew Ollama 0.30.x)**

The Homebrew `ollama` formula omits the `llama-server` runner needed for
GGUF models. Install the official app and let the script link the binary:

```bash
brew install --cask ollama-app
./scripts/hermes-gemma-local.sh install-host   # re-runs ensure_llama_server + pull
```

**Context too small (Hermes 0.16+)**

Hermes 0.16 requires ≥64K runtime context for tool use. The plain
`gemma4:12b-it-qat` tag defaults to 4K–8K. Use the `gemma4-hermes` alias
created by `hermes-gemma-local.sh setup` (sets `num_ctx=65536`). Re-run:

```bash
./scripts/hermes-gemma-local.sh enable-hermes
./scripts/hermes-gemma-local.sh test
```

**Port 11435 vs 11434**

Lima forwards guest `:11434` to the host for in-VM services. Host inference
runs on `:11435` so the two do not collide. After reboot, restart host
Ollama: `./scripts/hermes-gemma-local.sh start`.

**UFW blocks VM → host**

Cloud-init does not hardcode the Lima gateway IP. `hermes-gemma-local.sh
enable-hermes` inserts a UFW egress rule dynamically. Re-run it if inference
was working and stopped after a VM rebuild.

**First request is slow**

Cold-loading `gemma4-hermes` with 64K context on a 16 GiB Mac can take
2–3 minutes. Subsequent requests are faster while Ollama keeps the model
loaded (`OLLAMA_KEEP_ALIVE`, default 10m).

#### OpenRouter 429 "add your own key" — is the API key missing?

A 429 response with the message `add your own key to accumulate your rate
limits` does **not** mean the `OPENROUTER_API_KEY` is absent or wrong. A
missing key produces 401. The 429 means the specific free-tier model's
inference pool is exhausted upstream.

Verify the key is loaded and check the current model:

```bash
./scripts/hermes.sh status   # shows "OpenRouter ✓ sk-o..." when key is present
```

If the key is present but requests keep 429-ing, the configured model's free
capacity is gone. Switch to a model that is currently available:

```bash
./scripts/list-free-models.sh                            # live list, changes as sponsors rotate
./scripts/hermes-model.sh                                # interactive picker (writes config.yaml)
./scripts/hermes-gateway.sh restart
```

Always use the `:free` suffix when picking a free OpenRouter model (e.g.
`qwen/qwen3-coder:free`). The meta-router id `openrouter/free` is **not**
strictly free — it routes to paid models if the account has any credits and
will produce 402 errors when the credit limit is hit.

#### Slack bot connected but never responds to messages

Symptom: `hermes status` shows `Slack ✓ configured`, gateway is `active
(running)`, Slack tokens pass `auth.test`, but @mentions and DMs produce
no response and nothing appears in `journalctl -u hermes-gateway.service`.

Root cause: **Socket Mode is disabled** in the Slack app settings. Without
it, Slack has nowhere to deliver events and the gateway receives nothing.

Fix — in `api.slack.com/apps → <your app> → Socket Mode`: toggle
**Enable Socket Mode** on.

While there, confirm under **Event Subscriptions → Subscribe to bot events**
that at minimum these two events are listed:

| Event | Purpose |
| --- | --- |
| `app_mention` | @mentions in channels |
| `message.im` | Direct messages to the bot |

And under **OAuth & Permissions → Bot Token Scopes** that the bot has:

| Scope | Purpose |
| --- | --- |
| `app_mentions:read` | Receive `app_mention` events |
| `users:read` | Resolve Slack usernames for `SLACK_ALLOWED_USERS` |

After any scope change, reinstall the app (yellow banner), store the new
bot token, and restart the gateway:

```bash
./scripts/hermes-config.sh          # SLACK_BOT_TOKEN → new xoxb-...
./scripts/hermes-gateway.sh restart
```

#### Slack bot receives messages but rejects them (Unauthorized user)

Symptom: Socket Mode is on, gateway is running, but every message produces
`WARNING gateway.run: Unauthorized user: UXXXXXXXXX (your-name) on slack`
in the journal and the bot stays silent.

Root cause: `SLACK_ALLOWED_USERS` in `.env` contains a display name (e.g.
`alice`) but the gateway filters by **Slack user ID** (the `U...` UID).
Display names can change; UIDs are stable — so hermes always compares
against the UID and rejects anything not in the allowlist.

Fix — copy your UID from the log line (`Unauthorized user: U01234567AB
(alice)` → `U01234567AB`) and update the allowlist:

```bash
./scripts/hermes-env-edit.sh
# change: SLACK_ALLOWED_USERS=alice
# to:     SLACK_ALLOWED_USERS=U01234567AB
```

Then restart:

```bash
./scripts/hermes-gateway.sh restart
```

To add multiple users, check whether your version of hermes expects a
comma-separated list or repeated env vars (`SLACK_ALLOWED_USERS_1=...`).

#### Hermes agent gives advice about editing `config.yaml` for Slack / API keys

Ignore it. `config.yaml` is for non-secret runtime config (model, terminal
backend, personalities). Secrets (`OPENROUTER_API_KEY`, `SLACK_BOT_TOKEN`,
`SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, etc.) belong exclusively in
`/srv/hermes/.hermes/.env`. The runtime reads them from there via `hermes
config env-path`. Anything written to `config.yaml` via `hermes config set`
for a key that belongs in `.env` is silently ignored by the runtime.

To add or update a secret:

```bash
./scripts/hermes-config.sh          # prompted; value is never echoed or written to host disk
# or, to edit .env directly:
./scripts/hermes-env-edit.sh
```

After updating `.env`, restart the gateway:

```bash
./scripts/hermes-gateway.sh restart
```

This also applies to Slack: Socket Mode (the `xapp-` app-level token)
requires no public URL and no webhook. Only `SLACK_BOT_TOKEN`,
`SLACK_APP_TOKEN`, and `SLACK_SIGNING_SECRET` in `.env` are needed. No
`gateway.platforms.slack` section in `config.yaml` is required.

#### Hermes agent asks for the sudo password

The `hermes` user has no sudo access and never will. It is not in the
`sudo` or `wheel` group. No password exists that would satisfy the prompt —
`sudo` will reject any input unconditionally.

If the agent needs a privileged operation done, deny the sudo request and
describe what specific command needs to run. Then execute it yourself:

```bash
./scripts/shell.sh -- sudo <command>
```

You can also give the agent this standing instruction to avoid repeat
prompts:

> You do not have sudo access and never will. Your user (`hermes`) is
> deliberately unprivileged — not in the sudo or wheel group. There is no
> password to provide. If you need a privileged operation done, ask the
> human to run it for you.

#### Hermes agent diagnoses the wrong config files (wrong user context)

Symptom: a `hermes chat` session reports that `SLACK_BOT_TOKEN` is empty,
`.env` is missing, or `hermes` is not in PATH — even though `hermes status`
on the host shows everything configured.

Root cause: the agent ran a shell command that resolved to the *calling*
user's home directory (e.g. `/home/<your-username>/.hermes/`) instead of
the `hermes` user's home at `/srv/hermes/.hermes/`. Commands like `cat
~/.hermes/.env` in agent tool calls go to the wrong path.

The correct locations are:

| Resource | Path |
| --- | --- |
| `.env` (secrets) | `/srv/hermes/.hermes/.env` |
| `config.yaml` | `/srv/hermes/.hermes/config.yaml` |
| `hermes` binary | `/srv/hermes/.local/bin/hermes` |

When instructing the agent to read or write config, always use absolute
paths under `/srv/hermes/`.

#### I want to disable the VM and free its resources without deleting it

```bash
./scripts/stop.sh
```

CPU and RAM allocations are returned to macOS immediately. State is
preserved.

To delete the VM entirely (DESTRUCTIVE — wipes the rootfs and the
encrypted data disk and the keyfile):

```bash
./scripts/destroy.sh
```

`destroy.sh` requires explicit `destroy` confirmation. It removes the
VM instance and the `tank` data disk; it does **not** touch
`${HERMES_VM_HOME}/backups/`. Make sure the keyfile and any data you
care about are backed up first.

---

## E. Appendix: install prerequisites

### Homebrew

One-liner from [brew.sh](https://brew.sh):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the post-install instructions Homebrew prints to add `brew` to
your `PATH`.

### Lima

```bash
brew install lima
```

This installs both `limactl` (the CLI you'll use throughout this README)
and `lima` (a thin shell wrapper). Verify:

```bash
limactl --version
```

You want 2.1.1 or newer.

### jq

```bash
brew install jq
```

Used by some validation commands and by future scripts in this repo.

### Ollama (local LLM backend)

Required for the default Gemma backend (`hermes-gemma-local.sh`). Install
both the CLI and the official app — Homebrew's formula alone is missing
`llama-server` on 0.30.x:

```bash
brew install ollama
brew install --cask ollama-app
```

Then run `./scripts/hermes-gemma-local.sh setup` from the repo. Host
Ollama listens on port **11435** (not 11434). Logs:
`./scripts/hermes-gemma-local.sh logs`.

### tmux (recommended for interactive `shell.sh`)

```bash
brew install tmux
```

Interactive `./scripts/shell.sh` attaches to a host tmux session named
`hermes-vm` (override with `HERMES_SHELL_SESSION`). If your SSH session
drops, re-run `./scripts/shell.sh` from the repo to reattach. One-off
commands (`./scripts/shell.sh -- …`) bypass tmux.

To resume **any** SSH login on the Mac host (not just the VM shell):

```bash
./scripts/host-shell-setup.sh install
```

That adds a small snippet to your shell rc. New SSH sessions auto-attach
to tmux session `hermes-host` (`HERMES_HOST_SHELL_SESSION`). Uninstall
with `./scripts/host-shell-setup.sh uninstall`.

### Optional: external SSD

`HERMES_VM_HOME` should point at an APFS volume with at least 300 GiB
free. Two requirements:

1. **Writable by your user.** Lima writes the VM bundle, the additional
   disk image, and runtime sockets under `$LIMA_HOME`; the volume needs
   to be writable without `sudo`.
2. **APFS-formatted.** APFS gives you `cp -c` (clonefile), which is what
   makes the [full-VM rollback procedure](#full-vm-rollback-apfs-clonefile)
   instant. ExFAT or HFS+ will work for storage but the backup step
   becomes a slow full copy.

Format with Disk Utility (GUI) or `diskutil`:

```bash
diskutil list                                          # find the disk identifier
diskutil eraseDisk APFS hermes-vm-data <identifier>    # WIPES the disk
```

Then either set `HERMES_VM_HOME=/Volumes/hermes-vm-data` or create a
subdirectory there and point `HERMES_VM_HOME` at it.
