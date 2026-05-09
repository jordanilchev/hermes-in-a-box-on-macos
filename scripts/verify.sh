#!/usr/bin/env bash
# Run all hardening verifications. Exit 0 if everything passes.

. "$(dirname "$0")/env.sh"
set -eu

require_cmd limactl

shell() { limactl shell "${HERMES_VM_NAME}" -- "$@"; }
fail=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
miss() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; fail=1; }

echo "== 15.1 Internet access =="
if shell curl -s -o /dev/null --max-time 8 -w "%{http_code}" https://google.com 2>/dev/null | grep -qE "^(2|3)[0-9]{2}$"; then
  pass "https://google.com responds"
else
  miss "https://google.com unreachable"
fi

echo "== 15.2 LAN isolation =="
for tgt in 192.168.1.1 10.0.0.1 172.16.0.1; do
  if shell timeout 3 ping -c 2 -W 2 "$tgt" >/dev/null 2>&1; then
    miss "$tgt is REACHABLE — UFW LAN-deny is broken"
  else
    pass "$tgt blocked"
  fi
done

echo "== 15.3 UFW =="
ufw_status=$(shell sudo ufw status 2>/dev/null | head -1 || true)
[[ "$ufw_status" == *active* ]] && pass "ufw active" || miss "ufw not active ($ufw_status)"

echo "== 15.4 Docker (no system dockerd; rootless dockerd for hermes) =="
shell bash -c '[ ! -S /var/run/docker.sock ]' \
  && pass "no system docker socket" \
  || miss "system docker socket present at /var/run/docker.sock"
if shell systemctl is-active docker >/dev/null 2>&1; then
  miss "system docker.service is active (should not exist)"
else
  pass "system docker.service absent"
fi
if shell sudo -iu hermes docker info >/dev/null 2>&1; then
  if shell sudo -iu hermes docker info 2>/dev/null | grep -qi rootless; then
    pass "hermes rootless dockerd active"
  else
    miss "hermes dockerd reachable but not rootless"
  fi
else
  miss "hermes rootless dockerd not reachable (run ./scripts/hermes-install.sh)"
fi

echo "== ZFS =="
[[ "$(shell zpool list -H -o health tank 2>/dev/null)" == "ONLINE" ]] && pass "zpool tank ONLINE" || miss "zpool tank not ONLINE"
[[ "$(shell zfs get -H -o value keystatus tank 2>/dev/null)" == "available" ]] && pass "tank key loaded" || miss "tank key not loaded"
for ds in tank/hermes tank/hermes-var tank/hermes-log; do
  [[ "$(shell zfs get -H -o value mounted "$ds" 2>/dev/null)" == "yes" ]] && pass "$ds mounted" || miss "$ds not mounted"
done

echo "== Other services =="
for svc in fail2ban unattended-upgrades zfs-load-key.service; do
  [[ "$(shell systemctl is-enabled "$svc" 2>/dev/null)" == "enabled" || "$(shell systemctl is-active "$svc" 2>/dev/null)" == "active" ]] \
    && pass "$svc enabled/active" || miss "$svc not enabled or active"
done

echo "== cloud-final silencer =="
[[ "$(shell systemctl is-active cloud-final.service 2>/dev/null)" == "active" ]] \
  && pass "cloud-final.service active (silencer working)" || miss "cloud-final.service not active — silencer may be missing"

echo "== Hermes hardening regressions =="
# hermes user is not in any privileged group
if shell id hermes 2>/dev/null | grep -qE '\b(docker|sudo|wheel|adm)\b'; then
  miss "hermes is in a privileged group"
else
  pass "hermes not in docker/sudo/wheel/adm"
fi
# hermes cannot write into /etc (systemd unit + ProtectSystem will also block at runtime)
if shell sudo -u hermes touch /etc/regression-check 2>&1 | grep -qi 'permission denied'; then
  pass "hermes cannot write /etc/"
else
  shell sudo rm -f /etc/regression-check >/dev/null 2>&1 || true
  miss "hermes wrote to /etc/ (or unexpected error)"
fi
# UFW default policy unchanged (deny in/out)
if shell sudo ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming), deny (outgoing)'; then
  pass "UFW default deny in/out unchanged"
else
  miss "UFW default policy modified"
fi
# sshd hardening drop-in still has the four critical directives
miss_sshd=0
for line in 'PermitRootLogin no' 'PasswordAuthentication no' 'PubkeyAuthentication yes' 'PermitEmptyPasswords no'; do
  shell sudo grep -qx "$line" /etc/ssh/sshd_config.d/99-hermes-hardening.conf 2>/dev/null \
    || { miss "sshd drop-in lost: $line"; miss_sshd=1; }
done
[ $miss_sshd -eq 0 ] && pass "sshd hardening drop-in intact"
# hermes cannot disable UFW (running ufw as hermes errors with "must be root")
if shell sudo -n -u hermes ufw disable >/dev/null 2>&1; then
  miss "hermes was able to run ufw disable"
else
  pass "hermes cannot disable UFW"
fi
# /etc/zfs/tank.key is unreadable by hermes (mode 0400 root:root, in /etc/zfs which is 0700)
if shell sudo -u hermes cat /etc/zfs/tank.key 2>&1 | grep -qi 'permission denied'; then
  pass "hermes cannot read /etc/zfs/tank.key"
else
  miss "hermes can read /etc/zfs/tank.key"
fi

echo
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "FAILED checks above" >&2; exit 1; }
