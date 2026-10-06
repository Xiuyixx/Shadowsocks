#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Redirect proc reads only in this isolated copy; production never accepts a proc override.
sed "s|/proc/\$pid/cgroup|$work/proc/\$pid/cgroup|g" "$repo/install.sh" > "$work/installer"
source "$work/installer"
assert_fails() { if ("$@") >/dev/null 2>&1; then echo "expected failure: $*"; exit 1; fi; }
for port in 1 0001 65535 00065535; do [[ "$(normalize_port "$port")" == "$((10#$port))" ]]; done
[[ "$(normalize_port "$(printf '%01000d' 1)")" == 1 ]]
for port in 0 000 65536 99999999999999999999999999999999 18446744073709551617 -1 +1 1.0 1e3; do assert_fails normalize_port "$port"; done
# Existing user has a differently named primary group; same-name group absent.
id() { case "$*" in '-u svc') echo 987 ;; '-g svc') echo 654 ;; *) return 1 ;; esac; }
getent() { [[ "$*" == 'group 654' ]] || return 1; echo 'shared-primary:x:654:'; }
ensure_user svc
[[ "$TX_USER_GID" == 654 && "$TX_USER_GROUP" == shared-primary && "$TX_CREATED_USER" == 0 ]]
write_systemd_unit "$work/unit" /opt/bin/ssserver /opt/config/config.json /opt/config svc "$TX_USER_GID"
grep -q '^Group=654$' "$work/unit"
install() { [[ "$*" == *'-g 654 '* ]]; command cp "${@: -2}"; }
write_config "$work/config" 8388 key aes-128-gcm tcp_only "$TX_USER_GID"
# New users resolve their actual primary group after creation as well.
created=0
id() { (( created )) || return 1; case "$1" in -u) echo 987 ;; -g) echo 654 ;; esac; }
useradd() { created=1; }
ensure_user svc
[[ "$TX_CREATED_USER" == 1 && "$TX_USER_GID" == 654 ]]
service=/system.slice/shadowsocks-server.service
for pid in 123 456 1234 789; do mkdir -p "$work/proc/$pid"; done
printf '0::%s\n' "$service" > "$work/proc/123/cgroup"
printf '0::%s/plugin\n' "$service" > "$work/proc/456/cgroup"
printf '0::%s-evil\n' "$service" > "$work/proc/1234/cgroup"
printf '0::/unrelated\n' > "$work/proc/789/cgroup"
pid_in_service_cgroup 456 "$service"
assert_fails pid_in_service_cgroup 1234 "$service"
assert_fails pid_in_service_cgroup 789 "$service"
printf '8:cpu:/unrelated\n1:name=systemd:%s/plugin\n' "$service" > "$work/proc/456/cgroup"
pid_in_service_cgroup 456 "$service"
printf '8:cpu:%s/plugin\n1:name=systemd:/unrelated\n' "$service" > "$work/proc/789/cgroup"
assert_fails pid_in_service_cgroup 789 "$service"
listener=456
ss() { printf 'LISTEN 0 1 0.0.0.0:8388 0.0.0.0:* users:(("plugin",pid=%s,fd=3))\n' "$listener"; }
port_is_listening 8388 tcp_only 123 "$service"
for listener in 1234 789; do assert_fails port_is_listening 8388 tcp_only 123 "$service"; done
listener=456
systemctl() { case "$1" in is-active) return 0 ;; show) if [[ "$*" == *ControlGroup* ]]; then echo "$service"; else echo 123; fi ;; esac; }
sleep() { :; }
wait_ready 8388 tcp_only
listener=789
assert_fails wait_ready 8388 tcp_only
printf '%s\n' 'decimal ports, primary groups, v1/v2 descendant cgroups and PID-prefix tests passed'
