#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
printf payload > "$work/test.tar.xz"
digest="$(sha256sum "$work/test.tar.xz")"; digest="${digest%% *}"
release='{"tag_name":"vtest","assets":[{"name":"test.tar.xz.sha256","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.tar.xz.sha256"}]}'
curl() {
  [[ "$checksum" != download-error ]] || return 22
  while [[ $# -gt 0 ]]; do if [[ "$1" == -o ]]; then printf '%s\n' "$checksum" > "$2"; return; fi; shift; done
  return 1
}
for checksum in "$digest" "$digest  test.tar.xz" "${digest^^} *test.tar.xz"; do
  maybe_verify_sha256_from_release "$work/test.tar.xz" test.tar.xz "$release" 0
done
for checksum in '' bad "${digest}  wrong.tar.xz" "$(printf '%064d' 0)" download-error; do
  if (maybe_verify_sha256_from_release "$work/test.tar.xz" test.tar.xz "$release" 0) >/dev/null 2>&1; then echo 'expected checksum failure'; exit 1; fi
done
if (maybe_verify_sha256_from_release "$work/test.tar.xz" test.tar.xz '{"assets":[]}' 0) >/dev/null 2>&1; then exit 1; fi
maybe_verify_sha256_from_release "$work/test.tar.xz" test.tar.xz '{}' 1
printf '%s\n' 'strict checksum tests passed'
