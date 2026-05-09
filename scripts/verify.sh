#!/usr/bin/env bash
# Run all hardening verifications. Exit 0 if everything passes.

. "$(dirname "$0")/env.sh"

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

echo "== 15.4 Docker =="
[[ "$(shell systemctl is-active docker 2>/dev/null)" == "active" ]] && pass "docker active" || miss "docker not active"
sd=$(shell sudo docker info 2>/dev/null | awk -F': *' '/Storage Driver/{print $2; exit}')
[[ "$sd" == "zfs" ]] && pass "storage driver: zfs" || miss "storage driver: $sd (expected zfs)"
priv=$(shell bash -c 'sudo docker ps -q | xargs -r sudo docker inspect --format "{{.HostConfig.Privileged}}" | grep -c true || true')
[[ "${priv:-0}" == "0" ]] && pass "no privileged containers" || miss "$priv privileged containers"

echo "== ZFS =="
[[ "$(shell zpool list -H -o health tank 2>/dev/null)" == "ONLINE" ]] && pass "zpool tank ONLINE" || miss "zpool tank not ONLINE"
[[ "$(shell zfs get -H -o value keystatus tank 2>/dev/null)" == "available" ]] && pass "tank key loaded" || miss "tank key not loaded"
for ds in tank/docker tank/hermes tank/hermes-var tank/hermes-log; do
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

echo
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "FAILED checks above" >&2; exit 1; }
