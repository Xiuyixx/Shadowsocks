#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Only redirect the fixed unit destination; run the actual main, writers and rollback.
sed "s|/etc/systemd/system/shadowsocks-server.service|$work/unit|g" "$repo_dir/install.sh" > "$work/installer"
mkdir "$work/archive"
printf '#!/usr/bin/env bash\nprintf "test binary\\n"\n' > "$work/archive/ssserver"
tar -cJf "$work/asset.tar.xz" -C "$work/archive" ssserver
for scenario in new upgrade ip_failure restart start write signal readiness meta malformed config_stream config_objects v1 v1_noncanonical metadata_stream metadata_objects; do
  case_dir="$work/$scenario"; mkdir -p "$case_dir/bin" "$case_dir/config"
  if [[ "$scenario" != new ]]; then
    printf old-binary > "$case_dir/bin/ssserver"
    printf '%s\n' '{"server":"::","server_port":8488,"password":"old-key","method":"aes-128-gcm","mode":"tcp_only","plugin":"keep","custom":{"x":[1,2]},"fast_open":true}' > "$case_dir/config/config.json"
    printf old-unit > "$work/unit"
    chmod 700 "$case_dir/config"
    cp -p "$case_dir/config/config.json" "$case_dir/old-config"
    if [[ "$scenario" == malformed ]]; then printf '{bad' > "$case_dir/config/config.json"; cp "$case_dir/config/config.json" "$case_dir/old-config"; fi
  else rm -f "$work/unit"; fi
  case "$scenario" in
    config_stream) printf 'false\n' > "$case_dir/config/config.json"; cat "$case_dir/old-config" >> "$case_dir/config/config.json"; cp "$case_dir/config/config.json" "$case_dir/old-config" ;;
    config_objects) cat "$case_dir/old-config" >> "$case_dir/config/config.json"; cp "$case_dir/config/config.json" "$case_dir/old-config" ;;
  esac
  if [[ "$scenario" == v1* || "$scenario" == metadata_* ]]; then
    legacy_dir="$case_dir/config/"; legacy_bin="$case_dir/bin/ssserver"; legacy_config="$legacy_dir/config.json"
    if [[ "$scenario" == v1_noncanonical ]]; then legacy_dir="$case_dir/config/../config/"; legacy_bin="$case_dir/bin/../bin/ssserver"; legacy_config="$case_dir/config/./config.json"; fi
    jq -n --arg dir "$legacy_dir" --arg bin "$legacy_bin" --arg config "$legacy_config" '{metaVersion:"1",configDir:$dir,configPath:$config,ssserverPath:$bin,runUser:"shadowsocks",serviceName:"shadowsocks-server.service"}' > "$case_dir/config/install-meta.json"
    if [[ "$scenario" == metadata_stream ]]; then { echo false; cat "$case_dir/config/install-meta.json"; } > "$case_dir/meta-stream"; cp "$case_dir/meta-stream" "$case_dir/config/install-meta.json"; fi
    if [[ "$scenario" == metadata_objects ]]; then cp "$case_dir/config/install-meta.json" "$case_dir/meta-copy"; cat "$case_dir/meta-copy" >> "$case_dir/config/install-meta.json"; fi
    chmod 600 "$case_dir/config/install-meta.json"
    cp "$case_dir/config/install-meta.json" "$case_dir/old-meta"
  fi
  set +e
  (
    set -e
    source "$work/installer"
    install_deps() { :; }
    require_root() { :; }
    id() { if [[ "$*" == '-u shadowsocks' ]]; then echo 987; else command id "$@"; fi; }
    chown() { :; }
    install() { local args=(); while [[ $# -gt 0 ]]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done; command install "${args[@]}"; }
    journalctl() { :; }
    sleep() { :; }
    curl() { [[ "$scenario" != ip_failure ]] || return 22; printf '203.0.113.1'; }
    get_release_by_tag() { printf '{"tag_name":"vtest","assets":[{"name":"test.x86_64-unknown-linux-musl.tar.xz","browser_download_url":"https://github.com/shadowsocks/shadowsocks-rust/releases/download/vtest/test.x86_64-unknown-linux-musl.tar.xz"}]}'; }
    uname() { echo x86_64; }
    download_release_asset() { cp "$work/asset.tar.xz" "$2"; }
    mock_running=0
    [[ "$scenario" == new || "$scenario" == start ]] || mock_running=1
    systemctl() {
      case "$1" in
        is-active) (( mock_running )) || return 1 ;;
        is-enabled) echo disabled; return 1 ;;
        show) echo 123 ;;
        stop) mock_running=0 ;;
        restart) [[ "$scenario" != restart ]] || return 1 ;;
        start) [[ "$scenario" != start ]] || return 1; mock_running=1 ;;
      esac
      printf '%s\n' "$*" >> "$case_dir/systemctl.log"
    }
    ss() { printf 'LISTEN 0 1 0.0.0.0:8488 0.0.0.0:* users:(("ssserver",pid=123,fd=3))\nLISTEN 0 1 0.0.0.0:8388 0.0.0.0:* users:(("ssserver",pid=123,fd=3))\n'; }
    if [[ "$scenario" == write ]]; then
      mv() { if [[ "$*" == *config.json ]]; then return 1; fi; command mv "$@"; }
    fi
    if [[ "$scenario" == signal ]]; then
      write_install_meta() { kill -TERM "${BASHPID}"; }
    fi
    if [[ "$scenario" == meta ]]; then
      write_install_meta() { return 1; }
    fi
    if [[ "$scenario" == readiness ]]; then ss() { :; }; fi
    main --version vtest --bin-dir "$case_dir/bin" --config-dir "$case_dir/config" --skip-sha256 --mode tcp_only
  ) > "$case_dir/output" 2>&1
  result=$?
  set -e
  if (( result == 0 )); then
    case "$scenario" in new|upgrade|ip_failure|v1|v1_noncanonical) ;; *) cat "$case_dir/output"; echo "expected $scenario failure"; exit 1 ;; esac
    jq -e '.metaVersion == "2" and .createdUser == false' "$case_dir/config/install-meta.json" >/dev/null
    if [[ "$scenario" == upgrade ]]; then jq -e '.server == "::" and .fast_open and .plugin == "keep" and .custom.x == [1,2] and .password == "old-key"' "$case_dir/config/config.json" >/dev/null; fi
  else
    case "$scenario" in new|upgrade|ip_failure|v1|v1_noncanonical) cat "$case_dir/output"; exit 1 ;; esac
    [[ "$(cat "$case_dir/bin/ssserver")" == old-binary ]]
    cmp "$case_dir/old-config" "$case_dir/config/config.json"
    [[ "$(cat "$work/unit")" == old-unit ]]
    if [[ -e "$case_dir/old-meta" ]]; then cmp "$case_dir/old-meta" "$case_dir/config/install-meta.json"; else [[ ! -e "$case_dir/config/install-meta.json" ]]; fi
    [[ "$(stat -c %a "$case_dir/config")" == 700 ]]
    if [[ "$scenario" != malformed && "$scenario" != config_* && "$scenario" != metadata_* ]]; then grep -q '^disable ' "$case_dir/systemctl.log"; fi
  fi
  if grep -q 'Rollback incomplete' "$case_dir/output"; then
    backup_dir="$(sed -n 's/.*backups preserved at \([^;]*\);.*/\1/p' "$case_dir/output")"
    [[ -d "$backup_dir/backup" ]]
    cmp "$case_dir/old-config" "$backup_dir/backup/1"
    rm -rf -- "$backup_dir"
  fi
  [[ -z "$(find "$case_dir" -name '*.new.*' -print)" ]]
done
printf '%s\n' 'full main transactional tests passed'
