#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_dir}/install.sh"

assert_fails() {
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'expected failure: %s\n' "$*" >&2
    exit 1
  fi
}

[[ "$(format_uri_host '203.0.113.1')" == "203.0.113.1" ]]
[[ "$(format_uri_host '2001:db8::1')" == "[2001:db8::1]" ]]
[[ "$(format_uri_host '[2001:db8::1]')" == "[2001:db8::1]" ]]

fixture_dir="$(mktemp -d)"
trap 'rm -rf -- "$fixture_dir"' EXIT
validate_install_inputs "$fixture_dir/bin" "$fixture_dir/config" "shadowsocks"
assert_fails validate_install_inputs "/" "/etc/shadowsocks" "shadowsocks"
assert_fails validate_install_inputs "/usr/local/bin" "/" "shadowsocks"
assert_fails validate_install_inputs "/usr/local/bad path" "/etc/shadowsocks" "shadowsocks"
assert_fails validate_install_inputs "/usr/local/bin" "/etc/shadowsocks" $'bad\nUser=root'

fake_binary="$fixture_dir/fake-binary"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_binary"
chmod +x "$fake_binary"
assert_fails validate_extracted_binary "$fake_binary"
printf '#!/usr/bin/env bash\nprintf "shadowsocks test\\n"\n' > "$fake_binary"
validate_extracted_binary "$fake_binary"

password_128="$(generate_password '2022-blake3-aes-128-gcm')"
password_256="$(generate_password '2022-blake3-aes-256-gcm')"
validate_password_for_method '2022-blake3-aes-128-gcm' "$password_128"
validate_password_for_method '2022-blake3-aes-256-gcm' "$password_256"
validate_password_for_method '2022-blake3-chacha20-poly1305' "$password_256"
assert_fails validate_password_for_method '2022-blake3-aes-128-gcm' "$password_256"
assert_fails validate_password_for_method '2022-blake3-aes-256-gcm' 'not-base64'

ss() {
  case "$*" in
    *-ltn*) printf 'LISTEN 0 1024 0.0.0.0:8388 0.0.0.0:* users:(("ssserver",pid=123,fd=3))\n' ;;
    *-lun*) return 0 ;;
  esac
}
port_is_listening 8388 tcp_only 123
assert_fails port_is_listening 8388 udp_only 123
assert_fails port_is_listening 8388 tcp_and_udp 123

ss() {
  case "$*" in
    *-ltn*) printf 'LISTEN 0 1024 0.0.0.0:8388 0.0.0.0:* users:(("ssserver",pid=123,fd=3))\n' ;;
    *-lun*) printf 'UNCONN 0 0 0.0.0.0:8388 0.0.0.0:* users:(("ssserver",pid=123,fd=3))\n' ;;
  esac
}
port_is_listening 8388 tcp_and_udp 123

printf '%s\n' 'installer helper tests passed'
assert_fails validate_install_inputs /usr/local/bin /etc/../etc root
assert_fails validate_install_inputs /usr/local/bin /tmp/../usr shadowsocks
assert_fails port_is_listening 8388 tcp_only 999
pid_in_service_cgroup() { [[ "$1" == 123 && "$2" == /test/service ]]; }
systemctl() { case "$1" in is-active) return 0 ;; show) if [[ "$*" == *ControlGroup* ]]; then echo /test/service; else echo 123; fi ;; esac; }
sleep() { :; }
wait_ready 8388 tcp_and_udp
systemctl() { case "$1" in is-active) return 0 ;; show) echo 999 ;; esac; }
assert_fails wait_ready 8388 tcp_only
