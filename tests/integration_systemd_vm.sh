#!/usr/bin/env bash
# DESTRUCTIVE opt-in test: run only inside a new disposable VM with its own PID 1.
# Never invoke on a developer workstation, shared CI host, or production server.
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
[[ "${SS_DISPOSABLE_VM_ACK:-}" == I_ACCEPT_DISPOSABLE_VM_DESTRUCTION ]] || { echo 'REFUSED: explicit disposable-VM acknowledgment required' >&2; exit 1; }
[[ "${EUID}" == 0 && "$(cat /proc/1/comm)" == systemd ]] || { echo 'REFUSED: root and systemd PID 1 required' >&2; exit 1; }
systemd-detect-virt --vm --quiet || { echo 'REFUSED: a disposable VM (not host/container) is required' >&2; exit 1; }
[[ ! -e /etc/systemd/system/shadowsocks-server.service && ! -L /etc/systemd/system/shadowsocks-server.service && ! -e /etc/shadowsocks && ! -L /etc/shadowsocks && ! -e /usr/local/bin/ssserver && ! -L /usr/local/bin/ssserver ]] || { echo 'REFUSED: existing installation' >&2; exit 1; }
[[ "$(systemctl show -p LoadState --value shadowsocks-server.service)" == not-found ]] || { echo 'REFUSED: pre-existing service (including vendor/runtime unit)' >&2; exit 1; }
for user in shadowsocks ss-integration; do
  if getent passwd "$user" >/dev/null; then echo 'REFUSED: existing test user' >&2; exit 1; fi
done
if getent group ss-integration-primary >/dev/null; then echo 'REFUSED: existing test group' >&2; exit 1; fi
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for cmd in python3 jq ss flock shellcheck curl openssl xz tar; do command -v "$cmd" >/dev/null; done
work="$(mktemp -d /opt/ss-integration.XXXXXX)"
chmod 755 "$work" # Service account must traverse the isolated fixture parent.
cleanup() {
  local original_status=$? cleanup_status=0
  systemctl disable --now shadowsocks-server.service >/dev/null 2>&1 || { echo 'Cleanup failed: disable service' >&2; cleanup_status=1; }
  rm -f /etc/systemd/system/shadowsocks-server.service || { echo 'Cleanup failed: remove unit' >&2; cleanup_status=1; }
  systemctl daemon-reload || { echo 'Cleanup failed: daemon-reload' >&2; cleanup_status=1; }
  userdel ss-integration >/dev/null 2>&1 || { echo 'Cleanup failed: delete user' >&2; cleanup_status=1; }
  groupdel ss-integration-primary >/dev/null 2>&1 || { echo 'Cleanup failed: delete group' >&2; cleanup_status=1; }
  rm -rf -- "$work" || { echo 'Cleanup failed: remove work directory' >&2; cleanup_status=1; }
  # Preserve the test failure; otherwise a cleanup failure must fail the run.
  if (( original_status != 0 )); then return "$original_status"; fi
  return "$cleanup_status"
}
trap cleanup EXIT
groupadd --system ss-integration-primary
useradd --system --no-create-home --gid ss-integration-primary --shell /usr/sbin/nologin ss-integration
mkdir -p "$work/archive" "$work/bin" "$work/config"
# This fixture is NOT shadowsocks-rust: it exercises actual systemd hardening,
# group access, child listeners/cgroups, readiness, upgrade rollback and uninstall.
cat > "$work/archive/ssserver" <<'PY'
#!/usr/bin/python3
import json, os, socket, sys, time
if '--version' in sys.argv:
    print('systemd integration fixture'); sys.exit(0)
with open(sys.argv[sys.argv.index('-c') + 1]) as f:
    config = json.load(f)
if os.fork() == 0:
    sockets = []
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        s = socket.socket(socket.AF_INET, kind)
        s.bind(('127.0.0.1', config['server_port']))
        if kind == socket.SOCK_STREAM: s.listen()
        sockets.append(s)
    while True: time.sleep(1)
while True: time.sleep(1)
PY
chmod 755 "$work/archive/ssserver"
tar -cJf "$work/asset.tar.xz" -C "$work/archive" ssserver
# Real writers/main/unit/rollback; only release acquisition and package installation
# are replaced to avoid depending on network/upstream versions.
(
  source "$repo/install.sh"
  install_deps() { :; }
  get_release_by_tag() { printf '%s\n' '{"tag_name":"vtest","assets":[{"name":"test.x86_64-unknown-linux-musl.tar.xz","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.x86_64-unknown-linux-musl.tar.xz"}]}'; }
  get_arch() { echo x86_64-unknown-linux-musl; }
  download_release_asset() { cp "$work/asset.tar.xz" "$2"; }
  curl() { printf 127.0.0.1; }
  main --version vtest --bin-dir "$work/bin" --config-dir "$work/config" --user ss-integration --port 18388 --password fixture --skip-sha256
)
gid="$(id -g ss-integration)"
[[ "$(stat -c %g "$work/config")" == "$gid" && "$(stat -c %g "$work/config/config.json")" == "$gid" ]]
grep -q "^Group=$gid$" /etc/systemd/system/shadowsocks-server.service
cp -p "$work/config/config.json" "$work/original-config"
# A deliberately broken executable must fail readiness and restore a live service.
# shellcheck disable=SC2016
printf '#!/bin/sh\nif [ "$1" = --version ]; then exit 0; fi\nexit 1\n' > "$work/archive/ssserver"
tar -cJf "$work/asset.tar.xz" -C "$work/archive" ssserver
# Capture failure outside conditional context so main retains errexit.
set +e
(
  set -e
  source "$repo/install.sh"
  install_deps() { :; }
  get_release_by_tag() { printf '%s\n' '{"tag_name":"vtest","assets":[{"name":"test.x86_64-unknown-linux-musl.tar.xz","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.x86_64-unknown-linux-musl.tar.xz"}]}'; }
  get_arch() { echo x86_64-unknown-linux-musl; }
  download_release_asset() { cp "$work/asset.tar.xz" "$2"; }
  main --version vtest --bin-dir "$work/bin" --config-dir "$work/config" --user ss-integration --skip-sha256
)
upgrade_status=$?
set -e
if (( upgrade_status == 0 )); then echo 'Broken upgrade unexpectedly succeeded'; exit 1; fi
cmp "$work/original-config" "$work/config/config.json"
source "$repo/install.sh"
wait_ready 18388 tcp_and_udp
bash "$repo/uninstall.sh" --yes --config-dir "$work/config" --bin-path "$work/bin/ssserver" --user ss-integration
[[ ! -e "$work/bin/ssserver" && ! -e "$work/config/config.json" && ! -e /etc/systemd/system/shadowsocks-server.service ]]
getent passwd ss-integration >/dev/null # Existing account must be retained.
echo 'REAL SYSTEMD VM integration passed (fixture, not shadowsocks protocol test)'
