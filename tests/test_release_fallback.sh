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
for api_response in 'not-json' '{"assets":[]}' '{"assets":[{"name":"other.aarch64-unknown-linux-musl.tar.xz"}]}'; do
  github_api() { printf '%s' "$api_response"; }
  curl() { printf '%s' '<a href="/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/test.x86_64-unknown-linux-musl.tar.xz">asset</a>'; }
  jq -e '.assets[0].name == "test.x86_64-unknown-linux-musl.tar.xz"' <<<"$(get_release_by_tag v1.25.0 x86_64-unknown-linux-musl)" >/dev/null
done

# Use distinct tags/assets so accepting any document instead of the page is visible.
valid_api='{"tag_name":"v9.9.9","assets":[{"name":"api.x86_64-unknown-linux-musl.tar.xz","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/api.x86_64-unknown-linux-musl.tar.xz"}]}'
github_api() { printf '%s' "$api_response"; }
curl() {
  case "${*: -1}" in
    */releases/latest) printf '%s' 'https://github.com/shadowsocks/shadowsocks-rust/releases/tag/v1.25.0' ;;
    */expanded_assets/v1.25.0) printf '%s' '<a href="/shadowsocks/shadowsocks-rust/releases/download/v1.25.0/page.x86_64-unknown-linux-musl.tar.xz">asset</a>' ;;
    *) return 22 ;;
  esac
}
for api_response in "$valid_api $valid_api" "false $valid_api" "$valid_api false" "$valid_api invalid-tail" 'false' '[]' ''; do
  # Conditional assignment deliberately disables errexit inside both functions.
  if ! latest="$(get_latest_version)"; then echo 'expected latest page fallback' >&2; exit 1; fi
  [[ "$latest" == v1.25.0 ]]
  if ! release_json="$(get_release_by_tag v1.25.0 x86_64-unknown-linux-musl)"; then echo 'expected release page fallback' >&2; exit 1; fi
  jq -se 'length == 1 and (.[0].assets[0].name == "page.x86_64-unknown-linux-musl.tar.xz")' <<<"$release_json" >/dev/null
done

# A single valid object succeeds without a page request, and normalizes its tag.
api_response="$valid_api"
curl() { echo 'unexpected page request' >&2; return 22; }
if ! latest="$(get_latest_version)"; then exit 1; fi
[[ "$latest" == v9.9.9 ]]
if ! release_json="$(get_release_by_tag v1.25.0 x86_64-unknown-linux-musl)"; then exit 1; fi
jq -se 'length == 1 and (.[0] | .tag_name == "v1.25.0" and .assets[0].name == "api.x86_64-unknown-linux-musl.tar.xz")' <<<"$release_json" >/dev/null

# Failed acquisition and malformed content must explicitly fail in conditionals.
for api_response in "$valid_api $valid_api" "false $valid_api" "$valid_api false" "$valid_api invalid-tail"; do
  curl() { return 22; }
  if latest="$(get_latest_version)"; then echo 'expected latest API/page failure' >&2; exit 1; fi
  if release_json="$(get_release_by_tag v1.25.0)"; then echo 'expected release API/page failure' >&2; exit 1; fi
  curl() { printf '%s' '<html>No release assets</html>'; }
  if latest="$(get_latest_version)"; then echo 'expected invalid latest page failure' >&2; exit 1; fi
  if release_json="$(get_release_by_tag v1.25.0)"; then echo 'expected empty release page failure' >&2; exit 1; fi
done
github_api() { return 22; }
curl() { return 22; }
if get_latest_version >/dev/null 2>&1; then exit 1; fi
if get_release_by_tag v1.25.0 >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'release API fallback tests passed'
