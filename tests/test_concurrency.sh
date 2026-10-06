#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
sed "s|/run/shadowsocks-installer/operation.lock|$work/lock/operation.lock|g" "$repo/install.sh" > "$work/installer"
sed "s|/run/shadowsocks-installer/operation.lock|$work/lock/operation.lock|g" "$repo/uninstall.sh" > "$work/uninstaller"
# The real installer enters dependency installation while holding the lock.
# No host dependencies/service/user changes: stop it at this mocked boundary.
(
  source "$work/installer"
  install_deps() { touch "$work/entered"; while [[ ! -e "$work/release" ]]; do sleep 0.02; done; exit 17; }
  # Hosted runners may have user-writable /usr/local/bin; isolate path checks too.
  main --bin-dir "$work/bin" --config-dir "$work/config"
) > "$work/holder-output" 2>&1 &
holder=$!
for ((i=0; i<200; i++)); do [[ ! -e "$work/entered" ]] || break; sleep 0.02; done
[[ -e "$work/entered" ]]
if bash "$work/uninstaller" --yes --config-dir "$work/nonexistent" > "$work/output" 2>&1; then exit 1; fi
grep -q 'Another installer or uninstaller' "$work/output"
if bash "$work/installer" > "$work/output" 2>&1; then exit 1; fi
grep -q 'Another installer or uninstaller' "$work/output"
touch "$work/release"
wait "$holder" && exit 1
# A daemon launched by a helper must not keep the coprocess pipe/lock alive.
(
  source "$work/installer"
  acquire_install_lock
  bash -c 'sleep 5 </dev/null >/dev/null 2>&1 &' 
)
for ((i=0; i<100; i++)); do
  if flock -n "$work/lock/operation.lock" true; then break; fi
  sleep 0.02
done
flock -n "$work/lock/operation.lock" true
# Symlink and insecure lock directories must be refused before any mutation.
mv "$work/lock" "$work/safe-lock"
ln -s "$work/safe-lock" "$work/lock"
if bash "$work/uninstaller" --yes > "$work/output" 2>&1; then exit 1; fi
grep -q 'Unsafe lock directory' "$work/output"
printf '%s\n' 'simultaneous installer/uninstaller, lock lifetime and symlink tests passed'
