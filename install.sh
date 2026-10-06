#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-10-05"
INSTALL_META_VERSION="2"
# Deliberately fixed: do not make the production lock path user-configurable.
SS_INSTALL_LOCK_PATH="/run/shadowsocks-installer/operation.lock"

usage() {
  cat <<'EOF'
Install Shadowsocks (shadowsocks-rust) server with AEAD (default: aes-128-gcm).

USAGE
  curl -fsSL <RAW_URL>/install.sh | bash -s -- [options]

NOTES
  - If your system does not support process substitution (e.g. /dev/fd missing), avoid: bash <(curl ...)

OPTIONS
  -p, --port <port>         Server port (default: 8388)
  -k, --password <passwd>   Server password (default: random)
  -m, --method <method>     Cipher method (default: aes-128-gcm)
  -v, --version <tag>       shadowsocks-rust version tag (default: latest)
      --bin-dir <dir>       Install ssserver into (default: /usr/local/bin)
      --config-dir <dir>    Config dir (default: /etc/shadowsocks)
      --user <name>         Run service as this system user (default: shadowsocks)
      --mode <mode>         Transport mode: tcp_and_udp | tcp_only | udp_only (default: tcp_and_udp)
      --no-udp              Alias for --mode tcp_only
      --skip-sha256         Do not attempt sha256 verification
  -h, --help                Show help

ENV (alternative to flags)
  SS_PORT, SS_PASSWORD, SS_METHOD, SS_VERSION, SS_MODE

UPGRADE BEHAVIOR
  - If an existing config is found at <config-dir>/config.json, and you do NOT explicitly
    pass --port/--password/--method/--mode (or related env vars), installer reuses existing
    values so an upgrade keeps your current node settings.

NOTES
  - Debian/Ubuntu, CentOS/RHEL/Rocky/AlmaLinux/Fedora supported.
  - This script creates/updates a systemd service: shadowsocks-server.service
EOF
}

log_info() { echo "[信息] $*"; }
log_ok() { echo "[成功] $*"; }
log_warn() { echo "[警告] $*" >&2; }

die() { echo "[错误] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_value() {
  local opt="$1"
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    die "${opt} requires a value"
  fi
}

require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    die "Run as root (use: sudo bash -s -- ...)"
  fi
}

acquire_install_lock() {
  command -v flock >/dev/null 2>&1 || die "Missing command: flock (util-linux)"
  local lock_dir="${SS_INSTALL_LOCK_PATH%/*}" response
  if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
    mkdir -m 700 -- "$lock_dir" 2>/dev/null || [[ -d "$lock_dir" ]] || die "Cannot create lock directory"
  fi
  [[ -d "$lock_dir" && ! -L "$lock_dir" && "$(stat -c %u:%a "$lock_dir")" == 0:700 ]] || die "Unsafe lock directory"
  [[ ! -L "$SS_INSTALL_LOCK_PATH" ]] || die "Unsafe lock file"
  if [[ -e "$SS_INSTALL_LOCK_PATH" ]]; then
    [[ -f "$SS_INSTALL_LOCK_PATH" && "$(stat -c %u:%a "$SS_INSTALL_LOCK_PATH")" == 0:600 ]] || die "Unsafe lock file"
  fi
  # Bash coprocess pipe descriptors are close-on-exec, unlike a normal exec 9>.
  # flock owns the lock, --close keeps it out of its child; EOF releases it only
  # when this shell exits (after rollback). No service/daemon inherits the lock.
  coproc SS_LOCK { umask 077; flock -n -o "$SS_INSTALL_LOCK_PATH" sh -c 'echo locked; cat >/dev/null'; }
  # Keep the write pipe open in the invoking shell until its EXIT cleanup.
  [[ -n "${SS_LOCK[1]}" ]] || die "Cannot hold install lock"
  IFS= read -r response <&"${SS_LOCK[0]}" || die "Another installer or uninstaller is already running"
  [[ "$response" == locked ]] || die "Cannot acquire install lock"
}

normalize_path() {
  [[ "$1" == /* && "$1" =~ ^[A-Za-z0-9_./:+-]+$ ]] || die "Invalid absolute path: $1"
  realpath -m -- "$1"
}

# Validate one JSON object before reading any fields. Legacy v1 paths are
# canonicalized in memory only; never rewrite untrusted metadata on disk.
read_install_metadata() {
  local path="$1" metadata field value
  metadata="$(jq -se 'length == 1 and (.[0] | type == "object")' "$path")" || die "Invalid install metadata: expected one object"
  [[ "$metadata" == true ]] || die "Invalid install metadata: expected one object"
  metadata="$(jq -e '(.metaVersion == "1" or .metaVersion == "2") and
    ([.ssserverPath, .configDir, .configPath, .runUser, .serviceName] | all(.[]; type == "string")) and
    .serviceName == "shadowsocks-server.service" and
    (.metaVersion == "1" or (.createdUser | type == "boolean"))' "$path")" || die "Invalid install metadata schema"
  metadata="$(cat -- "$path")"
  if [[ "$(jq -r .metaVersion <<<"$metadata")" == 1 ]]; then
    for field in ssserverPath configDir configPath; do
      value="$(jq -r --arg field "$field" '.[$field]' <<<"$metadata")"
      [[ ! -L "$value" ]] || die "Symlink metadata path refused"
      value="$(normalize_path "$value")" || return 1
      metadata="$(jq --arg field "$field" --arg value "$value" '.[$field]=$value' <<<"$metadata")"
    done
  fi
  printf '%s\n' "$metadata"
}

safe_directory() {
  case "$1" in
    /|/etc|/usr|/usr/local|/var|/home|/root|/tmp|/run|/opt|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/etc/systemd|/etc/systemd/system) return 1 ;;
  esac
  case "$1" in /dev/*|/proc/*|/sys/*|/boot/*) return 1 ;; esac
}

validate_install_inputs() {
  local bin_dir config_dir user="$3"
  [[ ! -L "$1" && ! -L "$2" ]] || die "Symlink install directory refused"
  bin_dir="$(normalize_path "$1")" || return 1
  config_dir="$(normalize_path "$2")" || return 1
  if ! safe_directory "$bin_dir" || ! safe_directory "$config_dir"; then die "Unsafe install directory"; fi
  [[ "$bin_dir" != "$config_dir" && "$config_dir" != "$bin_dir/"* && "$bin_dir" != "$config_dir/"* ]] || die "Overlapping installation directories"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid --user: $user"
  case "$user" in root|daemon|nobody|bin|sys|sync|www-data|sshd|systemd-*) die "Critical service user: $user" ;; esac
  if id -u "$user" >/dev/null 2>&1; then
    [[ "$(id -u "$user")" != 0 ]] || die "Cannot run as UID 0"
  fi
}

install_deps() {
  log_info "正在安装依赖..."

  if [[ -f /etc/debian_version ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends ca-certificates curl iproute2 jq openssl xz-utils >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install ca-certificates curl iproute jq openssl xz >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum -y install ca-certificates curl iproute jq openssl xz >/dev/null
  else
    die "Unsupported OS. This installer supports Debian/Ubuntu (apt) and CentOS/RHEL/Fedora (dnf/yum)."
  fi

  log_ok "依赖安装完成"
}

get_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    *) die "Unsupported arch: $arch (supported: x86_64, aarch64)" ;;
  esac
}

github_api() {
  local url="$1"
  curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 1 --retry-max-time 300 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: SSAes128gcm-installer' \
    "$url"
}

get_latest_version() {
  local tag release_url
  if tag="$(github_api "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -er '.tag_name | select(type == "string" and length > 0)')"; then
    printf '%s\n' "$tag"
    return 0
  fi

  log_warn "GitHub API 不可用，改用官方 Release 页面获取最新版本"
  release_url="$(curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 1 --retry-max-time 300 -o /dev/null -w '%{url_effective}' \
    'https://github.com/shadowsocks/shadowsocks-rust/releases/latest')" || return 1
  [[ "$release_url" == https://github.com/shadowsocks/shadowsocks-rust/releases/tag/* ]] || return 1
  tag="${release_url##*/}"
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s\n' "$tag"
}

get_release_by_tag() {
  local tag="$1" arch="${2:-}" release_json assets_html
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if release_json="$(github_api "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/tags/${tag}" | jq -e --arg arch "$arch" --arg tag "$tag" 'select(.assets | type == "array" and length > 0) | select(all(.assets[]; (.name | type == "string") and (.browser_download_url | type == "string") and .browser_download_url == ("https://github.com/shadowsocks/shadowsocks-rust/releases/download/" + $tag + "/" + .name))) | select($arch == "" or any(.assets[]; (.name // "") | endswith("." + $arch + ".tar.xz")))')"; then
    release_json="$(jq --arg tag "$tag" '.tag_name=$tag' <<<"$release_json")"
    printf '%s\n' "$release_json"
    return 0
  fi

  log_warn "GitHub API 不可用，改用官方 Release 页面获取下载地址"
  assets_html="$(curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 1 --retry-max-time 300 \
    "https://github.com/shadowsocks/shadowsocks-rust/releases/expanded_assets/${tag}")" || return 1
  jq -Rse --arg tag "$tag" '
    {tag_name: $tag, assets: ([. | scan("href=\"(/shadowsocks/shadowsocks-rust/releases/download/[^\"]+)\"") | .[0]
      | select(startswith("/shadowsocks/shadowsocks-rust/releases/download/" + $tag + "/"))
      | {name: (split("/") | last), browser_download_url: ("https://github.com" + .)}] | unique_by(.name))}
    | select(.assets | length > 0)' <<<"$assets_html"
}

download_release_asset() {
  local url="$1" out="$2"
  curl -fL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 1 --retry-max-time 300 -o "$out" "$url"
}

validate_asset() {
  local name="$1" url="$2" tag="$3"
  [[ "$name" =~ ^[A-Za-z0-9._+-]+$ && "$url" == "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${name}" ]] || die "Unsafe release asset: $name"
}

maybe_verify_sha256_from_release() {
  local tar_path="$1" tar_name="$2" release_json="$3" skip="$4" sha_url expected actual tmp_sha
  if [[ "$skip" == 1 ]]; then log_warn "跳过 SHA256 校验（--skip-sha256）"; return; fi
  need_cmd sha256sum
  sha_url="$(jq -r --arg n "${tar_name}.sha256" '.assets[]? | select(.name == $n) | .browser_download_url' <<<"$release_json" | head -n1)"
  [[ -n "$sha_url" && "$sha_url" != null ]] || die "Missing ${tar_name}.sha256 (use --skip-sha256 only if intentional)"
  validate_asset "${tar_name}.sha256" "$sha_url" "$(jq -r .tag_name <<<"$release_json")"
  tmp_sha="${tar_path}.checksum"
  curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 1 --retry-max-time 300 -o "$tmp_sha" "$sha_url" || die "Checksum download failed"
  expected="$(awk -v n="$tar_name" '
    NF == 1 { pure=$1; count++; next }
    $2 == n || $2 == "*" n || $2 == "./" n || $2 == "*./" n { matched=$1; matches++ }
    END { if (matches == 1) print matched; else if (matches == 0 && count == 1 && NR == 1) print pure }
  ' "$tmp_sha")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "Missing, ambiguous or malformed SHA256 digest"
  actual="$(sha256sum "$tar_path")"; actual="${actual%% *}"
  [[ "${expected,,}" == "$actual" ]] || die "SHA256 mismatch: $tar_name"
  rm -f -- "$tmp_sha"
}

validate_extracted_binary() {
  local binary="$1"
  [[ -f "$binary" && -x "$binary" ]] || die "Downloaded archive does not contain an executable ssserver"
  "$binary" --version >/dev/null 2>&1 || die "Downloaded ssserver cannot run on this system"
}

generate_password() {
  local method="$1" bytes=24
  case "$method" in
    2022-blake3-aes-128-gcm) bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) bytes=32 ;;
  esac
  openssl rand -base64 "$bytes" | tr -d '\n'
}

validate_password_for_method() {
  local method="$1" password="$2" expected_bytes decoded_bytes
  case "$method" in
    2022-blake3-aes-128-gcm) expected_bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) expected_bytes=32 ;;
    *) return 0 ;;
  esac

  need_cmd base64
  if ! decoded_bytes="$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c)"; then
    die "Password for ${method} must be valid base64 encoding ${expected_bytes} bytes"
  fi
  [[ "$decoded_bytes" == "$expected_bytes" ]] ||
    die "Password for ${method} must decode to ${expected_bytes} bytes (got ${decoded_bytes})"
}

normalize_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port"
  port="${port#"${port%%[!0]*}"}"
  [[ -n "$port" && ${#port} -le 5 ]] || die "Port out of range: $1"
  (( port <= 65535 )) || die "Port out of range: $1"
  printf '%s\n' "$port"
}

ensure_user() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
    TX_CREATED_USER=1
  fi
  TX_USER_GID="$(id -g "$user")" || die "Cannot resolve primary GID for $user"
  [[ "$TX_USER_GID" =~ ^[0-9]+$ ]] || die "Invalid primary GID for $user"
  TX_USER_GROUP="$(getent group "$TX_USER_GID" | awk -F: 'NR == 1 {print $1}')"
  [[ -n "$TX_USER_GROUP" ]] || die "Cannot resolve primary group for $user"
}

write_config() {
  local config_path="$1" port="$2" password="$3" method="$4" mode="$5" group="$6"

  need_cmd jq

  # Write JSON via jq to avoid escaping/format issues.
  local tmp_config
  tmp_config="$(mktemp "${config_path}.tmp.XXXXXX")"
  TX_TEMPS+=("$tmp_config" "${tmp_config}.base")

  # NOTE: keep config format compatible across shadowsocks-rust versions.
  # Some versions expect `server` to be a string (not an array).
  local source_config="${7:-}"
  if [[ -n "$source_config" && -f "$source_config" ]]; then
    jq -se 'length == 1 and (.[0] | type == "object")' "$source_config" >/dev/null || die "Malformed existing config"
  else
    source_config="${tmp_config}.base"
    printf '%s\n' '{"server":"0.0.0.0","timeout":300,"fast_open":false,"nameserver":"1.1.1.1"}' > "$source_config"
  fi
  jq --argjson port "$port" --arg password "$password" --arg method "$method" --arg mode "$mode" \
    '.server_port=$port | .password=$password | .method=$method | .mode=$mode' "$source_config" > "$tmp_config"
  [[ "$source_config" != "${tmp_config}.base" ]] || rm -f -- "$source_config"

  install -m 0640 -o root -g "$group" "$tmp_config" "$config_path"
  rm -f "$tmp_config"
}

write_systemd_unit() {
  local unit_path="$1" ss_bin="$2" config_path="$3" config_dir="$4" user="$5" gid="$6"

  cat > "$unit_path" <<EOF
[Unit]
Description=Shadowsocks (shadowsocks-rust) Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${gid}
Environment=RUST_LOG=info
ExecStart=${ss_bin} -c ${config_path}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${config_dir}
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
}

write_install_meta() {
  local meta_path="$1" ss_bin="$2" config_dir="$3" config_path="$4" user="$5" service_name="$6" version="$7"
  need_cmd jq

  local tmp_meta
  tmp_meta="$(mktemp "${meta_path}.tmp.XXXXXX")"
  TX_TEMPS+=("$tmp_meta")
  jq -n \
    --arg installer_version "$SCRIPT_VERSION" \
    --arg meta_version "$INSTALL_META_VERSION" \
    --arg ss_bin "$ss_bin" \
    --arg config_dir "$config_dir" \
    --arg config_path "$config_path" \
    --arg user "$user" \
    --arg service_name "$service_name" \
    --arg ss_version "$version" \
    --argjson created_user "${TX_USER_OWNED:-false}" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      metaVersion: $meta_version,
      createdUser: $created_user,
      installerVersion: $installer_version,
      installedAt: $installed_at,
      serviceName: $service_name,
      runUser: $user,
      ssserverPath: $ss_bin,
      configDir: $config_dir,
      configPath: $config_path,
      shadowsocksRustVersion: $ss_version
    }' > "$tmp_meta"

  install -m 0600 -o root -g root "$tmp_meta" "$meta_path"
  rm -f "$tmp_meta"
}

# All transaction state is global: EXIT traps must not depend on expired main locals.
TX_DIR=""; TX_ACTIVE=0; TX_COMMITTED=0; TX_CREATED_USER=0; TX_USER_OWNED=false
TX_FILES=(); TX_EXISTED=(); TX_RUNNING=0; TX_ENABLED=disabled; TX_USER=""; TX_CONFIG=""; TX_CONFIG_EXISTED=0
TX_USER_GID=""; TX_USER_GROUP=""

atomic_replace() {
  local source="$1" target="$2" temp
  temp="$(mktemp "${target}.new.XXXXXX")"
  TX_TEMPS+=("$temp")
  cp -p -- "$source" "$temp" || return 1
  mv -fT -- "$temp" "$target" || return 1
}

transaction_exit() {
  local result="$?" i failed=0
  trap - EXIT INT TERM HUP
  set +e
  if (( TX_ACTIVE && ! TX_COMMITTED )); then
    log_warn "Installation failed (exit ${result}); restoring previous installation"
    systemctl status shadowsocks-server.service --no-pager -l >&2
    journalctl -u shadowsocks-server.service -n 50 --no-pager >&2
    systemctl stop shadowsocks-server.service || failed=1
    for i in "${!TX_FILES[@]}"; do
      if [[ "${TX_EXISTED[i]}" == 1 ]]; then
        atomic_replace "${TX_DIR}/backup/$i" "${TX_FILES[$i]}" || failed=1
      else rm -f -- "${TX_FILES[$i]}" || failed=1; fi
    done
    if (( TX_CONFIG_EXISTED )); then
      chmod "$TX_CONFIG_MODE" "$TX_CONFIG" || failed=1
      chown "$TX_CONFIG_OWNER" "$TX_CONFIG" || failed=1
    else rmdir -- "$TX_CONFIG" 2>/dev/null || true; fi
    systemctl daemon-reload || failed=1
    case "$TX_ENABLED" in
      enabled) systemctl enable shadowsocks-server.service || failed=1 ;;
      enabled-runtime) systemctl disable shadowsocks-server.service; systemctl enable --runtime shadowsocks-server.service || failed=1 ;;
      masked|masked-runtime) systemctl mask shadowsocks-server.service || failed=1 ;;
      *) systemctl disable shadowsocks-server.service || failed=1 ;;
    esac
    if (( TX_RUNNING )); then systemctl start shadowsocks-server.service || failed=1; fi
    if (( TX_CREATED_USER )); then userdel "$TX_USER" || failed=1; fi
    (( failed == 0 )) || log_warn "Rollback incomplete; backups preserved at ${TX_DIR}; inspect service and files manually"
    (( result != 0 )) || result=1
  fi
  for i in "${TX_TEMPS[@]}"; do rm -f -- "$i"; done
  if [[ "$failed" == 0 && "$TX_DIR" == /tmp/shadowsocks-install.* && -d "$TX_DIR" ]]; then rm -rf -- "$TX_DIR"; fi
  exit "$result"
}
TX_TEMPS=()

port_is_listening() {
  local port="$1" mode="$2" pid="${3:-}" cgroup="${4:-}" protocol output candidate found
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  for protocol in tcp udp; do
    [[ "$mode" == tcp_only && "$protocol" == udp ]] && continue
    [[ "$mode" == udp_only && "$protocol" == tcp ]] && continue
    if [[ "$protocol" == tcp ]]; then output="$(ss -H -ltnp 2>/dev/null)"; else output="$(ss -H -lunp 2>/dev/null)"; fi
    found=0
    while IFS= read -r candidate; do
      if [[ "$candidate" == "$pid" ]] || { [[ -n "$cgroup" ]] && pid_in_service_cgroup "$candidate" "$cgroup"; }; then found=1; break; fi
    done < <(awk -v port="$port" '$4 ~ (":" port "$") {print}' <<<"$output" | grep -oE 'pid=[0-9]+,' | sed -E 's/pid=([0-9]+),/\1/' || true)
    (( found )) || return 1
  done
}

pid_in_service_cgroup() {
  local pid="$1" expected="$2" hierarchy controllers path
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected" == /* && -r "/proc/$pid/cgroup" ]] || return 1
  while IFS=: read -r hierarchy controllers path; do
    [[ "$hierarchy:$controllers" == "0:" || ",$controllers," == *,name=systemd,* ]] || continue
    [[ "$path" == "$expected" || "$path" == "$expected"/* ]] && return 0
  done < "/proc/$pid/cgroup"
  return 1
}

wait_ready() {
  local port="$1" mode="$2" pid previous="" stable=0 tries cgroup
  for (( tries=0; tries<30; tries++ )); do
    systemctl is-active --quiet shadowsocks-server.service || return 1
    pid="$(systemctl show -p MainPID --value shadowsocks-server.service)"
    cgroup="$(systemctl show -p ControlGroup --value shadowsocks-server.service 2>/dev/null || true)"
    if port_is_listening "$port" "$mode" "$pid" "$cgroup" && pid_in_service_cgroup "$pid" "$cgroup"; then
      if [[ "$pid" == "$previous" ]]; then stable=$((stable+1)); else stable=1; fi
      (( stable >= 4 )) && return 0
    else stable=0; fi
    previous="$pid"
    sleep 0.5
  done
  return 1
}

format_uri_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

dump_process_diagnostics() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -a -f '(^|/)(ssserver|shadowsocks)([[:space:]]|$)' >&2 || true
    return 0
  fi

  ps -eo pid=,args= | awk '/ssserver|shadowsocks/ { print }' >&2 || true
}

main() {
  local port="${SS_PORT:-}"
  local password="${SS_PASSWORD:-}"
  local method="${SS_METHOD:-}"
  local version="${SS_VERSION:-latest}"
  local bin_dir="/usr/local/bin"
  local config_dir="/etc/shadowsocks"
  local user="shadowsocks"
  local mode="${SS_MODE:-}"
  local skip_sha256="0"

  local explicit_port="0"
  local explicit_password="0"
  local explicit_method="0"
  local explicit_mode="0"

  [[ -n "${SS_PORT:-}" ]] && explicit_port="1"
  [[ -n "${SS_PASSWORD:-}" ]] && explicit_password="1"
  [[ -n "${SS_METHOD:-}" ]] && explicit_method="1"
  [[ -n "${SS_MODE:-}" ]] && explicit_mode="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port) require_value "$1" "${2:-}"; port="$2"; explicit_port="1"; shift 2 ;;
      -k|--password) require_value "$1" "${2:-}"; password="$2"; explicit_password="1"; shift 2 ;;
      -m|--method) require_value "$1" "${2:-}"; method="$2"; explicit_method="1"; shift 2 ;;
      -v|--version) require_value "$1" "${2:-}"; version="$2"; shift 2 ;;
      --bin-dir) require_value "$1" "${2:-}"; bin_dir="$2"; shift 2 ;;
      --config-dir) require_value "$1" "${2:-}"; config_dir="$2"; shift 2 ;;
      --user) require_value "$1" "${2:-}"; user="$2"; shift 2 ;;
      --mode) require_value "$1" "${2:-}"; mode="$2"; explicit_mode="1"; shift 2 ;;
      --no-udp) mode="tcp_only"; explicit_mode="1"; shift 1 ;;
      --skip-sha256) skip_sha256="1"; shift 1 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done

  log_info "=== 进入一键安装模式 ==="
  log_info "Installer version: ${SCRIPT_VERSION}"
  require_root
  acquire_install_lock
  need_cmd uname

  [[ ! -L "$bin_dir" && ! -L "$config_dir" ]] || die "Symlink install directory refused"
  bin_dir="$(normalize_path "$bin_dir")"
  config_dir="$(normalize_path "$config_dir")"
  validate_install_inputs "$bin_dir" "$config_dir" "$user"

  install_deps
  need_cmd curl
  need_cmd jq
  need_cmd systemctl
  need_cmd tar
  need_cmd head
  need_cmd grep
  need_cmd ss
  need_cmd realpath

  local existing_config="${config_dir%/}/config.json"
  if [[ -e "$existing_config" ]]; then
    [[ -f "$existing_config" && ! -L "$existing_config" ]] || die "Unsafe existing config"
    jq -se 'length == 1 and (.[0] | type == "object" and ((.server // "0.0.0.0") | type == "string") and ((.server_port // 8388) | type == "number") and ((.password // "") | type == "string") and ((.method // "aes-128-gcm") | type == "string"))' "$existing_config" >/dev/null || die "Malformed existing config; refusing reset"
    if [[ "$explicit_port" == "0" ]]; then
      port="$(jq -r '.server_port // empty' "$existing_config" 2>/dev/null)"
    fi
    if [[ "$explicit_password" == "0" ]]; then
      password="$(jq -r '.password // empty' "$existing_config" 2>/dev/null)"
    fi
    if [[ "$explicit_method" == "0" ]]; then
      method="$(jq -r '.method // empty' "$existing_config" 2>/dev/null)"
    fi
    if [[ "$explicit_mode" == "0" ]]; then
      mode="$(jq -r '.mode // empty' "$existing_config" 2>/dev/null)"
    fi
    log_info "检测到已有配置：${existing_config}（未显式指定参数时将沿用原值）"
  fi

  : "${port:=8388}"
  : "${method:=aes-128-gcm}"
  : "${mode:=tcp_and_udp}"

  port="$(normalize_port "$port")"

  if [[ "$explicit_method" == 1 && "$explicit_password" == 0 && -f "$existing_config" && "$method" != "$(jq -r ' .method // empty' "$existing_config")" ]]; then
    password=""
  fi
  if [[ -z "$password" ]]; then
    need_cmd openssl
    password="$(generate_password "$method")"
  fi

  if [[ "$method" == 2022-* ]]; then
    validate_password_for_method "$method" "$password"
    log_info "检测到 SS2022 方法：${method}（password 长度校验通过）"
  fi

  if [[ "$mode" != "tcp_and_udp" && "$mode" != "tcp_only" && "$mode" != "udp_only" ]]; then
    die "Invalid --mode: $mode (use tcp_and_udp, tcp_only or udp_only)"
  fi

  local ss_arch
  ss_arch="$(get_arch)"

  log_info "步骤 1/3：获取 shadowsocks-rust 版本信息..."
  if [[ "$version" == "latest" ]]; then
    version="$(get_latest_version)"
  fi
  [[ -n "$version" && "$version" != "null" ]] || die "Failed to determine shadowsocks-rust version"

  local release_json
  if ! release_json="$(get_release_by_tag "$version" "$ss_arch")"; then
    die "Failed to fetch release metadata for tag: $version"
  fi
  log_ok "目标版本：${version}"

  local tar_url tar_name
  tar_url="$(jq -r --arg arch "$ss_arch" '.assets[]? | select(.name | endswith("." + $arch + ".tar.xz")) | .browser_download_url' <<<"$release_json" | head -n1)"
  tar_name="$(jq -r --arg arch "$ss_arch" '.assets[]? | select(.name | endswith("." + $arch + ".tar.xz")) | .name' <<<"$release_json" | head -n1)"

  [[ -n "$tar_url" && "$tar_url" != "null" ]] || die "No release asset found for arch: ${ss_arch} (tag: ${version})"
  [[ -n "$tar_name" && "$tar_name" != "null" ]] || die "Failed to resolve release asset name (arch: ${ss_arch})"

  validate_asset "$tar_name" "$tar_url" "$version"
  TX_DIR="$(mktemp -d /tmp/shadowsocks-install.XXXXXX)"
  trap transaction_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  download_release_asset "$tar_url" "${TX_DIR}/${tar_name}"
  maybe_verify_sha256_from_release "${TX_DIR}/${tar_name}" "$tar_name" "$release_json" "$skip_sha256"
  # Extract only the expected regular binary, not arbitrary archive paths or links.
  [[ "$(tar -tJf "${TX_DIR}/${tar_name}" | grep -cxE '(\./)?ssserver')" == 1 ]] || die "Archive must contain exactly one ssserver"
  local member
  member="$(tar -tJf "${TX_DIR}/${tar_name}" | grep -xE '(\./)?ssserver')"
  [[ "$(tar -tvJf "${TX_DIR}/${tar_name}" "$member")" == -* ]] || die "ssserver must be a regular file"
  tar -xOJf "${TX_DIR}/${tar_name}" "$member" > "${TX_DIR}/ssserver"
  chmod 755 "${TX_DIR}/ssserver"
  validate_extracted_binary "${TX_DIR}/ssserver"

  local ss_bin="${bin_dir}/ssserver" config_path="${config_dir}/config.json"
  local service_name="shadowsocks-server.service" unit_path="/etc/systemd/system/shadowsocks-server.service"
  local meta_path="${config_dir}/install-meta.json" i
  TX_USER="$user"; TX_CONFIG="$config_dir"
  TX_FILES=("$ss_bin" "$config_path" "$unit_path" "$meta_path")
  mkdir -p "${TX_DIR}/backup" "${TX_DIR}/stage"
  for i in "${!TX_FILES[@]}"; do
    [[ ! -L "${TX_FILES[$i]}" ]] || die "Refusing symlink target: ${TX_FILES[$i]}"
    if [[ -e "${TX_FILES[$i]}" ]]; then
      [[ -f "${TX_FILES[$i]}" ]] || die "Target is not a regular file"
      TX_EXISTED[i]=1; cp -p -- "${TX_FILES[$i]}" "${TX_DIR}/backup/$i"
    else TX_EXISTED[i]=0; fi
  done
  if [[ -e "$meta_path" ]]; then
    [[ "$(stat -c %u "$meta_path")" == 0 && "$(stat -c %a "$meta_path")" == 600 ]] || die "Unsafe metadata ownership/permissions"
    local metadata
    metadata="$(read_install_metadata "$meta_path")"
    jq -e --arg bin "$ss_bin" --arg dir "$config_dir" --arg user "$user" '
      (.metaVersion == "1" or .metaVersion == "2") and .ssserverPath == $bin and .configDir == $dir and
      .configPath == ($dir + "/config.json") and .runUser == $user and .serviceName == "shadowsocks-server.service" and
      (.metaVersion == "1" or (.createdUser | type == "boolean"))' <<<"$metadata" >/dev/null || die "Metadata does not match installation"
    TX_USER_OWNED="$(jq -r '.metaVersion == "2" and .createdUser == true' <<<"$metadata")"
  fi
  TX_RUNNING=0
  if systemctl is-active --quiet "$service_name"; then TX_RUNNING=1; fi
  TX_ENABLED="$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
  case "$TX_ENABLED" in masked|masked-runtime) die "Service is masked; unmask explicitly before installation" ;; esac
  if [[ -d "$config_dir" ]]; then
    [[ "$(stat -c %u "$config_dir")" == 0 ]] || die "Config directory must be root-owned"
    [[ "$(( 8#$(stat -c %a "$config_dir") & 0022 ))" == 0 ]] || die "Config directory must not be group/world writable"
    TX_CONFIG_EXISTED=1
    TX_CONFIG_MODE="$(stat -c %a "$config_dir")"; TX_CONFIG_OWNER="$(stat -c %u:%g "$config_dir")"
  fi
  TX_ACTIVE=1
  ensure_user "$user"
  (( TX_CREATED_USER == 0 )) || TX_USER_OWNED=true
  write_config "${TX_DIR}/stage/config.json" "$port" "$password" "$method" "$mode" "$TX_USER_GID" "$existing_config"
  write_systemd_unit "${TX_DIR}/stage/unit" "$ss_bin" "$config_path" "$config_dir" "$user" "$TX_USER_GID"
  chmod 644 "${TX_DIR}/stage/unit"
  write_install_meta "${TX_DIR}/stage/meta" "$ss_bin" "$config_dir" "$config_path" "$user" "$service_name" "$version"
  mkdir -p "$bin_dir" "$config_dir"
  chmod 750 "$config_dir"; chown root:"$TX_USER_GID" "$config_dir"
  atomic_replace "${TX_DIR}/ssserver" "$ss_bin"
  atomic_replace "${TX_DIR}/stage/config.json" "$config_path"
  atomic_replace "${TX_DIR}/stage/unit" "$unit_path"
  atomic_replace "${TX_DIR}/stage/meta" "$meta_path"
  systemctl daemon-reload
  systemctl enable "$service_name" >/dev/null
  if (( TX_RUNNING )); then systemctl restart "$service_name"; else systemctl start "$service_name"; fi
  wait_ready "$port" "$mode" || die "Service failed stable, service-cgroup listening readiness"
  TX_COMMITTED=1

  local hostname_short node_name public_ip ip_fallback uri_host
  hostname_short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "ss")"
  node_name="$(printf '%s' "$hostname_short" | tr ' ' '-' | tr -cd 'A-Za-z0-9._~-')"
  [[ -n "$node_name" ]] || node_name="ss"

  public_ip=""
  if command -v curl >/dev/null 2>&1; then
    local ip_source
    for ip_source in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com" "https://ipinfo.io/ip"; do
      public_ip="$(curl -fsSL --connect-timeout 5 --max-time 5 "$ip_source" 2>/dev/null || true)"
      # 去除可能的空白/换行
      public_ip="$(echo "$public_ip" | tr -d '[:space:]')"
      [[ -n "$public_ip" && "$public_ip" =~ ^[0-9a-fA-F.:]+$ ]] && break
      public_ip=""
    done
  fi

  ip_fallback="<YOUR_SERVER_IP>"
  if [[ -n "$public_ip" ]]; then
    ip_fallback="$public_ip"
  else
    log_warn "无法自动获取公网 IP，请手动替换 SS 链接中的服务器地址"
  fi
  uri_host="$(format_uri_host "$ip_fallback")"

  echo
  echo "Shadowsocks ${version} 已就绪"
  echo "节点名称: ${node_name}"
  echo "服务器地址: ${ip_fallback}"
  echo "端口: ${port}"
  echo "密码: ${password}"
  echo "加密方式: ${method}"
  echo "传输模式: ${mode}"


  local ss_link=""
  if command -v base64 >/dev/null 2>&1; then
    local userinfo_b64
    userinfo_b64="$(printf '%s' "${method}:${password}" | base64 -w 0 2>/dev/null || printf '%s' "${method}:${password}" | base64 2>/dev/null | tr -d '\n')"
    userinfo_b64="$(printf '%s' "$userinfo_b64" | tr '+/' '-_' | tr -d '=')"
    if [[ -n "$userinfo_b64" ]]; then
      ss_link="ss://${userinfo_b64}@${uri_host}:${port}#${node_name}"
    fi
  fi

  if [[ -z "$ss_link" ]]; then
    ss_link="ss://${method}:${password}@${uri_host}:${port}#${node_name}"
  fi

  echo "SS链接: ${ss_link}"
  echo "提示: 复制上面的 SS 链接导入客户端即可使用"

  echo
  local firewall_proto="TCP"
  if [[ "$mode" == "tcp_and_udp" ]]; then
    firewall_proto="TCP, UDP"
  elif [[ "$mode" == "udp_only" ]]; then
    firewall_proto="UDP"
  fi
  echo "Firewall/Security Group: allow ${firewall_proto} ${port}"
  log_ok "安装完成"
}

# BASH_SOURCE[0] is unset when bash reads the installer from stdin.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
