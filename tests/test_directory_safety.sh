#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo/install.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
assert_fails() { if ("$@") >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }
mkdir -p "$work/bin" "$work/config" "$work/parent/child"
# Root-owned sticky /tmp is permitted as an ancestor, not an install target.
validate_install_inputs "$work/bin" "$work/config" ss-directory-test
validate_directory_chain "$work/new/child"
validate_directory_chain /usr/local/bin
chmod 777 "$work/bin"
assert_fails validate_install_inputs "$work/bin" "$work/config" ss-directory-test
[[ "$(stat -c %a "$work/bin")" == 777 ]]
chmod 755 "$work/bin"
chmod 770 "$work/config"
assert_fails validate_install_inputs "$work/bin" "$work/config" ss-directory-test
chmod 755 "$work/config"
chmod 777 "$work/parent"
assert_fails validate_directory_chain "$work/parent/child"
assert_fails validate_directory_chain "$work/parent/missing/child"
chmod 755 "$work/parent"
chown 12345 "$work/bin"
assert_fails validate_install_inputs "$work/bin" "$work/config" ss-directory-test
chown 0 "$work/bin"
chown 12345 "$work/parent"
assert_fails validate_directory_chain "$work/parent/child"
assert_fails validate_directory_chain "$work/parent/missing/child"
chown 0 "$work/parent"
ln -s "$work/parent" "$work/link"
assert_fails validate_directory_chain "$work/link/child"
# Main must reject unsafe paths before package installation or account writes.
chmod 777 "$work/bin"
set +e
(
  acquire_install_lock() { :; }
  install_deps() { touch "$work/deps-called"; }
  useradd() { touch "$work/useradd-called"; }
  main --bin-dir "$work/bin" --config-dir "$work/config" --user ss-directory-test
) > "$work/output" 2>&1
result=$?
set -e
[[ "$result" != 0 && ! -e "$work/deps-called" && ! -e "$work/useradd-called" ]]
grep -q 'Directory must not be group/world writable' "$work/output"
# Uninstall checks the same chains before reading metadata or touching services.
sed -n '/^validate_directory_chain() {$/,/^}$/p' "$repo/uninstall.sh" > "$work/uninstall-check.sh"
source "$work/uninstall-check.sh"
assert_fails validate_directory_chain "$work/bin"
chmod 755 "$work/bin"
validate_directory_chain "$work/bin"
chmod 777 "$work/parent"
assert_fails validate_directory_chain "$work/parent/missing/child"
chmod 755 "$work/parent"
assert_fails validate_directory_chain "$work/link/child"
printf '%s\n' 'directory ownership, modes, missing ancestors and early rejection tests passed'
