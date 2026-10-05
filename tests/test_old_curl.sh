#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo/install.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Model curl 7.61: reject newer flags, require finite portable retry controls.
curl() {
  local arg output="" previous=""
  for arg in "$@"; do
    [[ "$arg" != --retry-all-errors ]] || return 2
    [[ "$previous" != -o ]] || output="$arg"
    previous="$arg"
  done
  [[ " $* " == *' --retry 3 '* && " $* " == *' --retry-max-time 300 '* && " $* " == *' --max-time '* ]] || return 2
  case "${*: -1}" in
    */releases/latest)
      if [[ " $* " == *' --url_effective '* || " $* " == *' %{url_effective} '* ]]; then printf '%s' 'https://github.com/shadowsocks/shadowsocks-rust/releases/tag/vtest'; else return 22; fi ;;
    */expanded_assets/vtest) printf '%s' '<a href="/shadowsocks/shadowsocks-rust/releases/download/vtest/test.x86_64-unknown-linux-musl.tar.xz">asset</a>' ;;
    *.sha256) sha256sum "$work/asset" | awk '{print $1}' > "$output" ;;
    *.tar.xz) printf asset > "$output" ;;
    *) return 22 ;;
  esac
}
[[ "$(get_latest_version)" == vtest ]]
get_release_by_tag vtest x86_64-unknown-linux-musl > "$work/release"
download_release_asset 'https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.tar.xz' "$work/asset"
maybe_verify_sha256_from_release "$work/asset" test.tar.xz '{"tag_name":"vtest","assets":[{"name":"test.tar.xz.sha256","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.tar.xz.sha256"}]}' 0
printf '%s\n' 'old curl portable retry API, fallback, asset, and checksum tests passed'
