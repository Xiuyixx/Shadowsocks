#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Uninstall Shadowsocks (shadowsocks-rust) installed by this repo.

USAGE
  bash uninstall.sh [options]

OPTIONS
      --bin-path <path>      Override ssserver path (default: auto-detect, fallback /usr/local/bin/ssserver)
      --config-dir <dir>     Override config dir (default: auto-detect, fallback /etc/shadowsocks)
      --user <name>          Override service user (default: auto-detect, fallback shadowsocks)
      --service <name>       Override service name (default: auto-detect, fallback shadowsocks-server.service)
      --keep-user            Do not delete the service user
      --yes                  Confirm without a terminal (automation)
  -h, --help                 Show help

NOTES
  - If install metadata exists at <config-dir>/install-meta.json, uninstall reads it first.
  - Explicit CLI options must match validated install metadata.
EOF
}

log_info() { echo "[信息] $*"; }
log_ok() { echo "[成功] $*"; }
log_warn() { echo "[警告] $*" >&2; }

die() { echo "[错误] $*" >&2; exit 1; }
require_value() {
  local opt="$1"
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    die "${opt} requires a value"
  fi
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
  bin_dir="$(normalize_path "$1")" || return 1
  config_dir="$(normalize_path "$2")" || return 1
  if ! safe_directory "$bin_dir" || ! safe_directory "$config_dir"; then die "Unsafe install directory"; fi
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid --user: $user"
  case "$user" in root|daemon|nobody|bin|sys|sync|www-data|sshd|systemd-*) die "Critical service user: $user" ;; esac
  if id -u "$user" >/dev/null 2>&1; then
    [[ "$(id -u "$user")" != 0 ]] || die "Cannot run as UID 0"
  fi
}

validate_uninstall_inputs() {
  [[ ! -L "$BIN_PATH" && ! -L "$CONFIG_DIR" ]] || die "Refusing symlink uninstall targets"
  BIN_PATH="$(normalize_path "$BIN_PATH")"
  CONFIG_DIR="$(normalize_path "$CONFIG_DIR")"
  [[ "${BIN_PATH##*/}" == ssserver ]] || die "Invalid binary basename (expected ssserver)"
  validate_install_inputs "${BIN_PATH%/*}" "$CONFIG_DIR" "$SS_USER"
  [[ "$SERVICE_NAME" == shadowsocks-server.service ]] || die "Invalid --service or metadata service: $SERVICE_NAME"
  [[ "$CONFIG_DIR" != "${BIN_PATH%/*}" && "$BIN_PATH" != "$CONFIG_DIR/"* ]] || die "Overlapping uninstall paths"
}

BIN_PATH=""
CONFIG_DIR=""
SS_USER=""
SERVICE_NAME=""
KEEP_USER="0"
YES="0"
CREATED_USER=false

EXPLICIT_BIN_PATH="0"
EXPLICIT_CONFIG_DIR="0"
EXPLICIT_SS_USER="0"
EXPLICIT_SERVICE_NAME="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-path)
      require_value "$1" "${2:-}"
      BIN_PATH="$2"
      EXPLICIT_BIN_PATH="1"
      shift 2
      ;;
    --config-dir)
      require_value "$1" "${2:-}"
      CONFIG_DIR="$2"
      EXPLICIT_CONFIG_DIR="1"
      shift 2
      ;;
    --user)
      require_value "$1" "${2:-}"
      SS_USER="$2"
      EXPLICIT_SS_USER="1"
      shift 2
      ;;
    --service)
      require_value "$1" "${2:-}"
      SERVICE_NAME="$2"
      EXPLICIT_SERVICE_NAME="1"
      shift 2
      ;;
    --keep-user) KEEP_USER="1"; shift 1 ;;
    --yes) YES="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

if [[ ${EUID:-0} -ne 0 ]]; then
  die "请以 root 运行：sudo bash $0"
fi

# Defaults are accepted only with verified ownership evidence.
DEFAULT_CONFIG_DIR="/etc/shadowsocks"
DEFAULT_BIN_PATH="/usr/local/bin/ssserver"
DEFAULT_SS_USER="shadowsocks"
DEFAULT_SERVICE_NAME="shadowsocks-server.service"

meta_config_dir="$CONFIG_DIR"
if [[ -z "$meta_config_dir" ]]; then
  meta_config_dir="$DEFAULT_CONFIG_DIR"
fi
[[ ! -L "$meta_config_dir" ]] || die "Refusing symlink config directory"
meta_config_dir="$(normalize_path "$meta_config_dir")"
safe_directory "$meta_config_dir" || die "Unsafe config directory"
META_PATH="${meta_config_dir%/}/install-meta.json"

if [[ -e "$META_PATH" ]]; then
  [[ -f "$META_PATH" && ! -L "$META_PATH" && "$(stat -c %u "$META_PATH")" == 0 && "$(stat -c %a "$META_PATH")" == 600 ]] || die "Unsafe metadata ownership/permissions"
  command -v jq >/dev/null || die "jq required to validate metadata"
  metadata="$(read_install_metadata "$META_PATH")"
  jq -e --arg dir "$meta_config_dir" '.configDir == $dir and .configPath == ($dir + "/config.json")' <<<"$metadata" >/dev/null || die "Invalid install metadata association"
  CREATED_USER="$(jq -r '.metaVersion == "2" and .createdUser == true' <<<"$metadata")"
  meta_bin_path="$(jq -r .ssserverPath <<<"$metadata")"
  meta_ss_user="$(jq -r .runUser <<<"$metadata")"
  meta_service_name="$(jq -r .serviceName <<<"$metadata")"
  [[ "$EXPLICIT_BIN_PATH" == 1 ]] || BIN_PATH="$meta_bin_path"
  [[ "$EXPLICIT_CONFIG_DIR" == 1 ]] || CONFIG_DIR="$meta_config_dir"
  [[ "$EXPLICIT_SS_USER" == 1 ]] || SS_USER="$meta_ss_user"
  [[ "$EXPLICIT_SERVICE_NAME" == 1 ]] || SERVICE_NAME="$meta_service_name"
fi

: "${CONFIG_DIR:=$DEFAULT_CONFIG_DIR}"
: "${BIN_PATH:=$DEFAULT_BIN_PATH}"
: "${SS_USER:=$DEFAULT_SS_USER}"
: "${SERVICE_NAME:=$DEFAULT_SERVICE_NAME}"

validate_uninstall_inputs
[[ ! -L "$BIN_PATH" && ! -L "$CONFIG_DIR" ]] || die "Refusing symlink uninstall targets"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
if [[ -e "$META_PATH" ]]; then
  [[ "$SS_USER" == "$meta_ss_user" && "$BIN_PATH" == "$meta_bin_path" && "$CONFIG_DIR" == "$meta_config_dir" && "$SERVICE_NAME" == "$meta_service_name" ]] || die "Explicit overrides must match install metadata"
fi
# Even metadata must not authorize deleting a unit belonging to another install.
# Legacy installations without metadata require both the generated unit and config.
if [[ -e "$UNIT_PATH" || ! -e "$META_PATH" ]]; then
  [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" && "$(stat -c %u "$UNIT_PATH")" == 0 ]] || die "Missing or unsafe installer unit"
  [[ "$(grep -c '^ExecStart=' "$UNIT_PATH")" == 1 && "$(grep '^ExecStart=' "$UNIT_PATH")" == "ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/config.json" ]] || die "Installer unit ExecStart association mismatch"
  [[ "$(grep -c '^User=' "$UNIT_PATH")" == 1 && "$(grep '^User=' "$UNIT_PATH")" == "User=${SS_USER}" ]] || die "Installer unit user association mismatch"
fi
if [[ ! -e "$META_PATH" ]]; then
  command -v jq >/dev/null || die "jq required to validate legacy config"
  [[ -f "$CONFIG_DIR/config.json" && ! -L "$CONFIG_DIR/config.json" && "$(stat -c %u "$CONFIG_DIR/config.json")" == 0 ]] || die "Missing or unsafe legacy config"
  jq -se 'length == 1 and (.[0] | type == "object" and (.server | type == "string") and
    (.server_port | type == "number" and . >= 1 and . <= 65535 and floor == .) and
    (.password | type == "string" and length > 0) and (.method | type == "string" and length > 0) and
    (.mode == "tcp_only" or .mode == "udp_only" or .mode == "tcp_and_udp"))' "$CONFIG_DIR/config.json" >/dev/null || die "Invalid legacy installer config"
fi
for target in "$CONFIG_DIR/config.json" "$META_PATH"; do
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || die "Unsafe installer file: $target"
done

log_info "=== 开始卸载 Shadowsocks（shadowsocks-rust）==="
log_info "service=${SERVICE_NAME}, bin=${BIN_PATH}, configDir=${CONFIG_DIR}, user=${SS_USER}"

echo
log_warn "此操作将停止服务并删除以下内容："
echo "  - systemd 服务：${SERVICE_NAME}"
echo "  - 二进制：${BIN_PATH}"
echo "  - 安装器配置文件：${CONFIG_DIR}/config.json 和 install-meta.json（保留其他文件）"
[[ "$KEEP_USER" == "0" && "$CREATED_USER" == true ]] && echo "  - 系统用户：${SS_USER}"
echo
if [[ "$YES" != 1 ]]; then
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then die "Confirmation requires a terminal; use --yes for automation"; fi
  printf '确认卸载？[y/N]: ' >&3
  read -r _confirm <&3 || _confirm=""
  exec 3>&-
  if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then log_info "已取消卸载。"; exit 0; fi
fi

if command -v systemctl >/dev/null 2>&1; then
  log_info "停止并禁用服务：${SERVICE_NAME}"
  systemctl disable --now "$SERVICE_NAME" >/dev/null
  systemctl stop "$SERVICE_NAME" >/dev/null

  if [[ -f "$UNIT_PATH" ]]; then
    log_info "移除 systemd unit：${UNIT_PATH}"
    rm -f "$UNIT_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
else
  die "systemctl required; refusing to delete a potentially running installation"
fi

if [[ -d "$CONFIG_DIR" ]]; then
  log_info "移除安装器配置文件：${CONFIG_DIR}"
  rm -f -- "$CONFIG_DIR/config.json" "$META_PATH"
  rmdir -- "$CONFIG_DIR" 2>/dev/null || log_info "保留非空配置目录：${CONFIG_DIR}"
fi

if [[ -f "$BIN_PATH" ]]; then
  log_info "移除二进制：${BIN_PATH}"
  rm -f "$BIN_PATH"
fi

if [[ "$KEEP_USER" == "0" && "$CREATED_USER" == true ]]; then
  if id -u "$SS_USER" >/dev/null 2>&1; then
    log_info "移除系统用户：${SS_USER}"
    userdel "$SS_USER" >/dev/null 2>&1 || true
  fi
else
  log_info "按参数要求保留用户：${SS_USER}"
fi

log_ok "卸载完成"
log_warn "提示：如果你之前手动放行过端口（云安全组/防火墙），需要你自行回收规则。"
