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

if output="$(bash "${repo_dir}/uninstall.sh" --config-dir "$tmp_dir" </dev/null 2>&1)"; then
  printf 'expected unsafe metadata to be rejected\n' >&2
  exit 1
fi
grep -q 'Invalid --service or metadata service' <<<"$output"

printf '%s\n' 'uninstall validation tests passed'
