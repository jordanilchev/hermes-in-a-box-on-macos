# hermes-vm

A hardened Ubuntu 24.04 LTS Server VM for running container-based agent
workloads (Hermes runtime) on a macOS Apple Silicon host. Boots from a cloud
image under Lima with the Apple Virtualization Framework backend, has no LAN
access, an encrypted ZFS data pool, and is fully unattended after first
provisioning.

> **Note for AI agents:** If you are an AI coding agent (Claude Code or
> similar) reading this to extend or troubleshoot the setup, start with
> [`ubuntu-hermes.yaml`](./ubuntu-hermes.yaml) — the single source of truth
> for provisioning — and the wrappers under [`scripts/`](./scripts/). Then
> read [Section D Troubleshooting](#troubleshooting) before making any
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
the unprivileged `hermes` user), and UFW deny-all-by-default with an
explicit allow-list (53/80/443/123 outbound, 22 inbound for `limactl
shell`).

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
| [`shell.sh`](./scripts/shell.sh) | Open an interactive shell in the VM, or run a one-off command. |
| [`start.sh`](./scripts/start.sh) | Resume the VM. |
| [`stop.sh`](./scripts/stop.sh) | Power down the VM (preserves state). |
| [`backup.sh`](./scripts/backup.sh) | Cold-copy backup of disk + datadisk + lima.yaml using APFS clonefile. |
| [`restore.sh`](./scripts/restore.sh) `<name>` | Restore from a backup directory under `${HERMES_VM_HOME}/backups/`. |
| [`keyfile-backup.sh`](./scripts/keyfile-backup.sh) | Export the ZFS encryption keyfile to base64 outside the VM. |
| [`keyfile-restore.sh`](./scripts/keyfile-restore.sh) | Restore the keyfile after a factory-reset. |
| [`destroy.sh`](./scripts/destroy.sh) | DESTRUCTIVE: tear down VM and tank disk (with confirmation). |

### Configuration

All scripts source [`scripts/env.sh`](./scripts/env.sh), which respects:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HERMES_VM_HOME` | `${HOME}/hermes-vm-data` | Root for VM bundle, disks, backups. Point at your APFS volume of choice. |
| `LIMA_HOME` | `${HERMES_VM_HOME}/lima` | Lima's instance directory. |
| `HERMES_VM_NAME` | `ubuntu-hermes` | Lima instance name. |
| `TANK_SIZE` | `200GiB` | Size of the encrypted data disk (used by `setup.sh` only on first run). |

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
the security posture.

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
./scripts/hermes-install.sh              # one-time: rootless docker + hermes binary
./scripts/hermes-config.sh               # set an API key (prompted, never on host disk)
./scripts/hermes-gateway.sh start        # start the long-running daemon (optional)
./scripts/hermes.sh chat                 # interactive
./scripts/hermes-gateway.sh logs         # follow daemon logs
```

`hermes-install.sh` is idempotent — it sets up rootless dockerd for the
`hermes` user, runs the upstream installer (only if `~/.local/bin/hermes`
is missing), and configures `terminal.backend=docker` so every tool call
runs inside a rootless container. `hermes-config.sh` prompts for a key
name (default `OPENROUTER_API_KEY`) and value; the value is piped via
stdin so it is never visible in `ps`.

The gateway daemon is shipped disabled. After setting an API key, start
it manually with `./scripts/hermes-gateway.sh start`. Logs follow with
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
./scripts/shell.sh                                       # interactive shell
./scripts/shell.sh -- sudo -iu hermes docker ps          # rootless docker as hermes
./scripts/hermes.sh chat                                 # interactive Hermes session
./scripts/hermes-gateway.sh status                       # gateway daemon state
./scripts/stop.sh                                        # power down (preserves state)
./scripts/start.sh                                       # resume
```

`HERMES_VM_HOME` (and therefore `LIMA_HOME`) must be set in every shell
that talks to the VM. Persist it in your shell rc as shown in
[Configuration](#configuration).

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
