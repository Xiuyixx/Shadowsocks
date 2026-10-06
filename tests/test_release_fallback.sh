#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/install.sh"

github_api() { return 22; }
curl() {
  case "${*: -1}" in
    */releases/latest) printf '%s' 'https://github.com/shadowsocks/shadowsocks-rust/releases/tag/v1.25.0' ;;
    */expanded_assets/v1.25.0)
      printf '%s\n' '<a href="/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/shadowsocks-v1.25.0.x86_64-unknown-linux-musl.tar.xz">binary</a>' \
        '<a href="/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/shadowsocks-v1.25.0.x86_64-unknown-linux-musl.tar.xz.sha256">checksum</a>' ;;
    *) return 22 ;;
  esac
}
[[ "$(get_latest_version)" == 'v1.25.0' ]]
release_json="$(get_release_by_tag v1.25.0)"
jq -e '.assets | length == 2' <<<"$release_json" >/dev/null
jq -e '.assets[] | select(.name == "shadowsocks-v1.25.0.x86_64-unknown-linux-musl.tar.xz") | .browser_download_url == "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/shadowsocks-v1.25.0.x86_64-unknown-linux-musl.tar.xz"' <<<"$release_json" >/dev/null
if get_release_by_tag v0.0.0 >/dev/null 2>&1; then
  echo 'expected missing release to fail' >&2
  exit 1
fi
curl() { printf '%s' '<html>No release assets</html>'; }
if get_release_by_tag v1.25.0 >/dev/null 2>&1; then
  echo 'expected empty release assets to fail' >&2
  exit 1
fi
github_api() { printf '%s' '{"tag_name":"v1.25.0","assets":[]}'; }
[[ "$(get_latest_version)" == 'v1.25.0' ]]
# Empty API assets plus an empty release page must fail on every jq version.
if get_release_by_tag v1.25.0 >/dev/null 2>&1; then
  echo 'expected empty API and page assets to fail' >&2
  exit 1
fi
github_api() { printf '%s' '{"tag_name":"v1.25.0","assets":[{"name":"test.x86_64-unknown-linux-musl.tar.xz","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/test.x86_64-unknown-linux-musl.tar.xz"}]}'; }
jq -e '.tag_name == "v1.25.0"' <<<"$(get_release_by_tag v1.25.0)" >/dev/null
printf '%s\n' 'release API fallback tests passed'
for api_response in 'not-json' '{"assets":[]}' '{"assets":[{"name":"other.aarch64-unknown-linux-musl.tar.xz"}]}'; do
  github_api() { printf '%s' "$api_response"; }
  curl() { printf '%s' '<a href="/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/test.x86_64-unknown-linux-musl.tar.xz">asset</a>'; }
  jq -e '.assets[0].name == "test.x86_64-unknown-linux-musl.tar.xz"' <<<"$(get_release_by_tag v1.25.0 x86_64-unknown-linux-musl)" >/dev/null
done
