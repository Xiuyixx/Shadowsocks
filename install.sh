#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-05-05-5"
INSTALL_META_VERSION="1"

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
  SS_PORT, SS_PASSWORD, SS_METHOD, SS_VERSION

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

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
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
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "Unsupported arch: $arch (supported: x86_64, aarch64)" ;;
  esac
}

github_api() {
  local url="$1"
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: SSAes128gcm-installer' \
    "$url"
}

generate_password() {
  local method="$1"

  case "$method" in
    2022-blake3-aes-128-gcm)
      openssl rand -base64 16 | tr -d '=\n'
      ;;
    2022-blake3-aes-256-gcm)
      openssl rand -base64 32 | tr -d '=\n'
      ;;
    *)
      openssl rand -base64 24 | tr -d '\n'
      ;;
  esac
}

get_latest_version() {
  local http_code response latest_version
  # Capture both response body and HTTP status code in one request.
  response="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: SSAes128gcm-installer' \
    -w '\n__HTTP_CODE__:%{http_code}' \
    "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" 2>/dev/null || true)"
  http_code="$(printf '%s' "$response" | grep -o '__HTTP_CODE__:[0-9]*' | cut -d: -f2 || echo 0)"
  response="$(printf '%s' "$response" | grep -v '__HTTP_CODE__:')"

  if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
    die "GitHub API rate limit exceeded (HTTP ${http_code}). Please wait a few minutes and retry, or specify a version manually with --version vX.Y.Z"
  fi

  latest_version="$(printf '%s' "$response" | jq -r .tag_name 2>/dev/null || true)"

  if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    die "Failed to determine latest shadowsocks-rust version (HTTP ${http_code:-unknown}). This may be caused by a network issue. Please retry later or specify a version manually with --version vX.Y.Z"
  fi

  printf '%s\n' "$latest_version"
}

get_release_by_tag() {
  local tag="$1"
  github_api "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/tags/${tag}"
}

download_release_asset() {
  local url="$1" out="$2"
  # Quiet download (no progress), but still show errors.
  curl -fL -sS --retry 3 --retry-delay 1 -o "$out" "$url"
  # Fail fast on empty/truncated downloads.
  if [[ ! -s "$out" ]]; then
    die "Downloaded file is empty or missing: ${out} (URL: ${url}). Possible network interruption."
  fi
}

maybe_verify_sha256_from_release() {
  local tar_path="$1" tar_name="$2" release_json="$3" skip="$4"
  if [[ "$skip" == "1" ]]; then
    log_warn "跳过 sha256 校验（--skip-sha256）"
    return 0
  fi

  local sha_url
  sha_url="$(jq -r --arg n "${tar_name}.sha256" '.assets[]? | select(.name == $n) | .browser_download_url' <<<"$release_json" | head -n1)"
  if [[ -z "$sha_url" || "$sha_url" == "null" ]]; then
    sha_url="$(jq -r '.assets[]? | select(.name | endswith(".sha256")) | .browser_download_url' <<<"$release_json" | head -n1)"
  fi

  if [[ -z "$sha_url" || "$sha_url" == "null" ]]; then
    log_warn "该 release 未找到 .sha256 资产，继续安装但不做校验"
    return 0
  fi

  local tmp_sha
  tmp_sha="$(mktemp)"

  if ! curl -fsSL -sS "$sha_url" -o "$tmp_sha"; then
    log_warn "下载 sha256 文件失败，继续安装但不做校验"
    rm -f "$tmp_sha"
    return 0
  fi

  if ! command -v sha256sum >/dev/null 2>&1; then
    log_warn "系统缺少 sha256sum，无法校验"
    rm -f "$tmp_sha"
    return 0
  fi

  # The sha256 file may contain multiple entries and varying formats.
  # Use only exact-match strategies to avoid path-injection false matches.
  local expected actual
  expected="$(awk -v n="$tar_name" '
    $2 == n || $2 == "*" n || $2 == "./" n || $2 == "*./" n { print $1; exit }
    { next }
  ' "$tmp_sha" 2>/dev/null || true)"

  if [[ -z "$expected" ]]; then
    log_warn "sha256 文件中未找到 ${tar_name} 的条目，继续安装但不做校验"
    rm -f "$tmp_sha"
    return 0
  fi

  actual="$(sha256sum "$tar_path" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    log_warn "sha256 校验失败：${tar_name}"
    echo "    expected: ${expected}" >&2
    echo "    actual:   ${actual}" >&2
    rm -f "$tmp_sha"
    exit 1
  fi

  log_ok "sha256 校验通过"
  rm -f "$tmp_sha"
}

ensure_user() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
  fi
}

write_config() {
  local config_path="$1" port="$2" password="$3" method="$4" mode="$5" user="$6" fast_open="${7:-false}"

  need_cmd jq

  # Write JSON via jq to avoid escaping/format issues.
  local tmp_config
  tmp_config="$(mktemp)"

  # NOTE: keep config format compatible across shadowsocks-rust versions.
  # Some versions expect `server` to be a string (not an array).
  # Bind to "::" (dual-stack) so IPv6 clients can connect; shadowsocks-rust
  # falls back gracefully when IPv6 is unavailable at runtime.
  jq -n \
    --arg server "::" \
    --argjson server_port "$port" \
    --arg password "$password" \
    --arg method "$method" \
    --argjson timeout 300 \
    --argjson fast_open "$fast_open" \
    --arg nameserver "1.1.1.1" \
    --arg mode "$mode" \
    '{
      server: $server,
      server_port: $server_port,
      password: $password,
      method: $method,
      timeout: $timeout,
      fast_open: $fast_open,
      nameserver: $nameserver,
      mode: $mode
    }' > "$tmp_config"

  install -m 0640 -o root -g "$user" "$tmp_config" "$config_path"
  rm -f "$tmp_config"
}

write_systemd_unit() {
  local unit_path="$1" ss_bin="$2" config_path="$3" config_dir="$4" user="$5" ss_version="$6"

  cat > "$unit_path" <<EOF
[Unit]
Description=Shadowsocks (shadowsocks-rust) Server ${ss_version}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
Group=${user}
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
# May conflict with some older shadowsocks-rust builds; disable if service fails to start
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
}

write_install_meta() {
  local meta_path="$1" ss_bin="$2" config_dir="$3" config_path="$4" user="$5" service_name="$6" version="$7"
  need_cmd jq

  local tmp_meta
  tmp_meta="$(mktemp)"
  jq -n \
    --arg installer_version "$SCRIPT_VERSION" \
    --arg meta_version "$INSTALL_META_VERSION" \
    --arg ss_bin "$ss_bin" \
    --arg config_dir "$config_dir" \
    --arg config_path "$config_path" \
    --arg user "$user" \
    --arg service_name "$service_name" \
    --arg ss_version "$version" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      metaVersion: $meta_version,
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

cleanup_tmp() {
  local dir="${1:-}"
  if [[ -n "$dir" && -d "$dir" ]]; then
    rm -rf "$dir"
  fi
}

port_is_listening() {
  local port="$1"
  # Match listening entries in both IPv4 and IPv6 forms:
  #   IPv4:  "0.0.0.0:PORT" or "*:PORT"
  #   IPv6:  ":::PORT"  (triple-colon, as shown by `ss`/`netstat` for [::]:PORT)
  # Use two separate patterns to avoid the ambiguity of matching "::" vs ":::".
  local pattern_v4="(0\.0\.0\.0|\*):${port}([^0-9]|$)"
  local pattern_v6=":::${port}([^0-9]|$)"

  if command -v ss >/dev/null 2>&1; then
    local out
    out="$(ss -lntup 2>/dev/null)"
    printf '%s\n' "$out" | grep -Eq "${pattern_v4}" && return 0
    printf '%s\n' "$out" | grep -Eq "${pattern_v6}" && return 0
    return 1
  fi

  if command -v netstat >/dev/null 2>&1; then
    local out
    out="$(netstat -lntup 2>/dev/null)"
    printf '%s\n' "$out" | grep -Eq "${pattern_v4}" && return 0
    printf '%s\n' "$out" | grep -Eq "${pattern_v6}" && return 0
    return 1
  fi

  log_warn "未找到 ss/netstat，跳过监听端口探测，仅依赖 systemd 状态判断"
  return 2
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
  local mode=""
  local skip_sha256="0"

  local explicit_port="0"
  local explicit_password="0"
  local explicit_method="0"
  local explicit_mode="0"

  [[ -n "${SS_PORT:-}" ]] && explicit_port="1"
  [[ -n "${SS_PASSWORD:-}" ]] && explicit_password="1"
  [[ -n "${SS_METHOD:-}" ]] && explicit_method="1"

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
  need_cmd uname

  install_deps
  need_cmd curl
  need_cmd jq
  need_cmd systemctl
  need_cmd tar
  need_cmd head
  need_cmd grep

  local existing_config="${config_dir%/}/config.json"
  if [[ -f "$existing_config" ]]; then
    if [[ "$explicit_port" == "0" ]]; then
      port="$(jq -r '.server_port // empty' "$existing_config" 2>/dev/null || true)"
    fi
    if [[ "$explicit_password" == "0" ]]; then
      password="$(jq -r '.password // empty' "$existing_config" 2>/dev/null || true)"
    fi
    if [[ "$explicit_method" == "0" ]]; then
      method="$(jq -r '.method // empty' "$existing_config" 2>/dev/null || true)"
    fi
    if [[ "$explicit_mode" == "0" ]]; then
      mode="$(jq -r '.mode // empty' "$existing_config" 2>/dev/null || true)"
    fi
    log_info "检测到已有配置：${existing_config}（未显式指定参数时将沿用原值）"
  fi

  : "${port:=8388}"
  : "${method:=aes-128-gcm}"
  : "${mode:=tcp_and_udp}"

  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: $port"

  if [[ -z "$password" ]]; then
    need_cmd openssl
    password="$(generate_password "$method")"
  fi

  if [[ "$method" == 2022-* ]]; then
    log_info "检测到 SS2022 方法：${method}，正在校验 password 格式..."
    # Validate base64 password length for SS2022 methods.
    # 2022-blake3-aes-128-gcm requires 16-byte key (base64 = 24 chars, no padding)
    # 2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305 require 32-byte key (base64 = 44 chars)
    local required_key_bytes=0
    case "$method" in
      2022-blake3-aes-128-gcm) required_key_bytes=16 ;;
      2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) required_key_bytes=32 ;;
    esac
    if (( required_key_bytes > 0 )); then
      local decoded_len
      decoded_len="$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c || echo 0)"
      if (( decoded_len != required_key_bytes )); then
        die "SS2022 方法 ${method} 需要 ${required_key_bytes} 字节的 base64 key，但当前 password 解码后为 ${decoded_len} 字节。\n  生成建议：openssl rand -base64 ${required_key_bytes}"
      fi
      log_ok "SS2022 password 格式校验通过（${decoded_len} 字节）"
    fi
  fi

  if [[ "$mode" != "tcp_and_udp" && "$mode" != "tcp_only" && "$mode" != "udp_only" ]]; then
    die "Invalid --mode: $mode (use tcp_and_udp, tcp_only, or udp_only)"
  fi

  local ss_arch
  ss_arch="$(get_arch)"

  # Auto-detect TCP Fast Open support (kernel >= 4.11, /proc knob value >= 2).
  # Detect here in main() so write_config receives it as a plain argument.
  # Auto-detect TCP Fast Open support.
  # Kernel value meaning: 1=client TFO, 2=server TFO, 3=both.
  # A value >= 2 means server-side TFO is enabled.
  # If TFO is not enabled, print a one-time hint; do NOT modify kernel params automatically.
  local tfo_val fast_open
  tfo_val="$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo 0)"
  fast_open=false
  if (( tfo_val >= 2 )); then
    fast_open=true
    log_info "TCP Fast Open 已启用（内核支持，/proc/sys/net/ipv4/tcp_fastopen=${tfo_val}）"
  else
    log_info "TCP Fast Open 未启用（当前值：${tfo_val}）。如需启用，请手动执行："
    log_info "  echo 3 | sudo tee /proc/sys/net/ipv4/tcp_fastopen"
    log_info "  # 永久生效：echo 'net.ipv4.tcp_fastopen=3' | sudo tee /etc/sysctl.d/10-tfo.conf && sudo sysctl -p /etc/sysctl.d/10-tfo.conf"
  fi

  log_info "步骤 1/3：获取 shadowsocks-rust 版本信息..."
  if [[ "$version" == "latest" ]]; then
    version="$(get_latest_version)"
  fi
  [[ -n "$version" && "$version" != "null" ]] || die "Failed to determine shadowsocks-rust version"

  local release_json
  if ! release_json="$(get_release_by_tag "$version")"; then
    die "Failed to fetch release metadata for tag: $version"
  fi
  log_ok "目标版本：${version}"

  local tar_url tar_name
  tar_url="$(jq -r --arg arch "$ss_arch" '.assets[]? | select(.name | test("\\." + $arch + "\\.tar\\.xz$")) | .browser_download_url' <<<"$release_json" | head -n1)"
  tar_name="$(jq -r --arg arch "$ss_arch" '.assets[]? | select(.name | test("\\." + $arch + "\\.tar\\.xz$")) | .name' <<<"$release_json" | head -n1)"

  [[ -n "$tar_url" && "$tar_url" != "null" ]] || die "No release asset found for arch: ${ss_arch} (tag: ${version})"
  [[ -n "$tar_name" && "$tar_name" != "null" ]] || die "Failed to resolve release asset name (arch: ${ss_arch})"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'cleanup_tmp "${tmp_dir:-}"' EXIT

  log_info "步骤 2/3：下载并安装 ssserver..."
  log_info "Installing shadowsocks-rust ${version} (${ss_arch})"
  download_release_asset "$tar_url" "${tmp_dir}/${tar_name}"
  maybe_verify_sha256_from_release "${tmp_dir}/${tar_name}" "$tar_name" "$release_json" "$skip_sha256"

  tar -C "$tmp_dir" -xJf "${tmp_dir}/${tar_name}"

  local ss_bin="${bin_dir%/}/ssserver"
  install -m 0755 "${tmp_dir}/ssserver" "$ss_bin"
  log_ok "ssserver 已安装到：${ss_bin}"

  log_info "步骤 3/3：生成配置并启动服务..."

  ensure_user "$user"

  mkdir -p "$config_dir"
  chmod 750 "$config_dir"
  chown root:"$user" "$config_dir"

  local config_path="${config_dir%/}/config.json"
  write_config "$config_path" "$port" "$password" "$method" "$mode" "$user" "$fast_open"

  if [[ ! -s "$config_path" ]]; then
    die "配置文件写入失败或为空：${config_path}"
  fi
  if ! jq -e . "$config_path" >/dev/null 2>&1; then
    log_warn "配置文件不是合法 JSON：${config_path}"
    sed -n '1,120p' "$config_path" >&2 || true
    exit 1
  fi

  if ! jq -e '(.server | type) == "string"' "$config_path" >/dev/null 2>&1; then
    log_warn "配置字段 server 类型不正确（需要 string）：${config_path}"
    sed -n '1,120p' "$config_path" >&2 || true
    exit 1
  fi

  if ! jq -e '(.server_port | type) == "number"' "$config_path" >/dev/null 2>&1; then
    log_warn "配置字段 server_port 类型不正确（需要 number）：${config_path}"
    sed -n '1,120p' "$config_path" >&2 || true
    exit 1
  fi

  # Use the actual config values as the source of truth.
  port="$(jq -r '.server_port' "$config_path")"
  method="$(jq -r '.method' "$config_path")"
  mode="$(jq -r '.mode' "$config_path")"

  log_ok "配置文件已写入：${config_path}"
  log_info "最终配置：port=${port}, method=${method}, mode=${mode}"

  local service_name="shadowsocks-server.service"
  local unit_path="/etc/systemd/system/${service_name}"
  write_systemd_unit "$unit_path" "$ss_bin" "$config_path" "$config_dir" "$user" "$version"

  systemctl daemon-reload
  systemctl enable "$service_name" >/dev/null
  if systemctl is-active --quiet "$service_name"; then
    systemctl restart "$service_name" >/dev/null
  else
    systemctl start "$service_name" >/dev/null
  fi

  if ! systemctl is-active --quiet "$service_name"; then
    log_warn "服务启动失败：${service_name}"
    systemctl status "$service_name" --no-pager -l >&2 || true
    journalctl -u "$service_name" -n 200 --no-pager -l >&2 || true
    log_warn "你也可以手动运行进行定位：${ss_bin} -c ${config_path} -vvv"
    exit 1
  fi

  write_install_meta "${config_dir%/}/install-meta.json" "$ss_bin" "$config_dir" "$config_path" "$user" "$service_name" "$version"
  log_ok "安装元数据已写入：${config_dir%/}/install-meta.json"

  # Verify the port is actually listening (service may exit quickly after start).
  # Allow up to ~5 seconds (15 * 0.35s) for slower machines or first-run setups.
  local tries listen_result
  tries=15
  listen_result=1
  while (( tries > 0 )); do
    if port_is_listening "$port"; then
      listen_result=0
      log_ok "服务运行正常（已监听端口 ${port}）"
      break
    else
      listen_result=$?
      if [[ "$listen_result" == "2" ]]; then
        break
      fi
    fi
    sleep 0.35
    tries=$((tries - 1))
  done

  if [[ "$listen_result" == "1" && "$tries" == "0" ]]; then
    log_warn "服务看似已启动，但未监听端口：${port}"
    systemctl status shadowsocks-server.service --no-pager -l >&2 || true
    journalctl -u shadowsocks-server.service -n 200 --no-pager -l >&2 || true
    dump_process_diagnostics
    exit 1
  fi

  local hostname_short node_name public_ip ip_fallback
  hostname_short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "ss")"
  node_name="${hostname_short}"

  public_ip=""
  if command -v curl >/dev/null 2>&1; then
    local ip_source
    for ip_source in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com" "https://ipinfo.io/ip"; do
      public_ip="$(curl -fsSL --max-time 5 "$ip_source" 2>/dev/null || true)"
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
    log_warn "无法自动获取公网 IP，SS 链接中的服务器地址将显示为 <YOUR_SERVER_IP>，请手动替换后再导入客户端。"
  fi

  echo
  echo "====================================== 配置信息 ======================================"
  echo "节点名称: ${node_name}"
  echo "服务器地址: ${ip_fallback}"
  echo "端口: ${port}"
  echo "密码: ${password}"
  echo "加密方式: ${method}"
  echo "传输模式: ${mode}"
  echo "====================================================================================="

  local ss_link=""
  if command -v base64 >/dev/null 2>&1; then
    local userinfo_b64
    # SS URI spec: base64url (RFC 4648 §5), NO padding ('=').
    # Steps: standard base64 encode → strip padding → replace + with - and / with _
    userinfo_b64="$(printf '%s' "${method}:${password}" | base64 -w 0 2>/dev/null || printf '%s' "${method}:${password}" | base64 2>/dev/null | tr -d '\n')"
    userinfo_b64="$(printf '%s' "$userinfo_b64" | tr -d '=')"
    userinfo_b64="${userinfo_b64//+/-}"
    userinfo_b64="${userinfo_b64//\//_}"
    if [[ -n "$userinfo_b64" ]]; then
      ss_link="ss://${userinfo_b64}@${ip_fallback}:${port}#${node_name}"
    fi
  fi

  if [[ -z "$ss_link" ]]; then
    ss_link="ss://${method}:${password}@${ip_fallback}:${port}#${node_name}"
  fi

  echo "SS链接: ${ss_link}"
  echo "提示: 复制上面的 SS 链接导入客户端即可使用"

  local ss_ver_str
  ss_ver_str="$("$ss_bin" --version 2>&1 | head -1 || echo '未知')"
  echo "ssserver 版本: ${ss_ver_str}"

  echo
  local firewall_proto="TCP"
  if [[ "$mode" == "tcp_and_udp" ]]; then
    firewall_proto="TCP, UDP"
  fi
  echo "Firewall/Security Group: allow ${firewall_proto} ${port}"
  log_ok "=== 一键安装完成 ==="
}

main "$@"
