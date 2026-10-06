#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

jq -n \
  --arg config_dir "$tmp_dir" \
  '{
    ssserverPath: "/usr/local/bin/ssserver",
    configDir: $config_dir,
    runUser: "shadowsocks",
    serviceName: "--help"
  }' > "${tmp_dir}/install-meta.json"

sed "s|/run/shadowsocks-installer/operation.lock|$tmp_dir/lock/operation.lock|g" "$repo_dir/uninstall.sh" > "$tmp_dir/uninstaller"
run_uninstaller=(bash)
if [[ ${EUID:-0} -ne 0 ]]; then
  run_uninstaller=(sudo bash)
fi

if output="$("${run_uninstaller[@]}" "$tmp_dir/uninstaller" --config-dir "$tmp_dir" </dev/null 2>&1)"; then
  printf 'expected unsafe metadata to be rejected\n' >&2
  exit 1
fi
grep -Eq 'Invalid install metadata|Unsafe metadata' <<<"$output"

printf '%s\n' 'uninstall validation tests passed'
