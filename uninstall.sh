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
  -h, --help                 Show help

NOTES
  - If install metadata exists at <config-dir>/install-meta.json, uninstall reads it first.
  - Explicit CLI options override install metadata.
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

BIN_PATH=""
CONFIG_DIR=""
SS_USER=""
SERVICE_NAME=""
KEEP_USER="0"

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
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

if [[ ${EUID:-0} -ne 0 ]]; then
  die "请以 root 运行：sudo bash $0"
fi

# defaults (may be overridden by install metadata, then by explicit CLI args)
DEFAULT_CONFIG_DIR="/etc/shadowsocks"
DEFAULT_BIN_PATH="/usr/local/bin/ssserver"
DEFAULT_SS_USER="shadowsocks"
DEFAULT_SERVICE_NAME="shadowsocks-server.service"

meta_config_dir="$CONFIG_DIR"
if [[ -z "$meta_config_dir" ]]; then
  meta_config_dir="$DEFAULT_CONFIG_DIR"
fi
META_PATH="${meta_config_dir%/}/install-meta.json"

if [[ -f "$META_PATH" ]]; then
  if command -v jq >/dev/null 2>&1; then
    log_info "检测到安装元数据：$META_PATH"

    meta_bin_path="$(jq -r '.ssserverPath // empty' "$META_PATH")"
    meta_config_dir="$(jq -r '.configDir // empty' "$META_PATH")"
    meta_ss_user="$(jq -r '.runUser // empty' "$META_PATH")"
    meta_service_name="$(jq -r '.serviceName // empty' "$META_PATH")"

    [[ "$EXPLICIT_BIN_PATH" == "1" ]] || BIN_PATH="$meta_bin_path"
    [[ "$EXPLICIT_CONFIG_DIR" == "1" ]] || CONFIG_DIR="$meta_config_dir"
    [[ "$EXPLICIT_SS_USER" == "1" ]] || SS_USER="$meta_ss_user"
    [[ "$EXPLICIT_SERVICE_NAME" == "1" ]] || SERVICE_NAME="$meta_service_name"
  else
    log_warn "未安装 jq，跳过 install-meta.json 解析"
  fi
fi

: "${CONFIG_DIR:=$DEFAULT_CONFIG_DIR}"
: "${BIN_PATH:=$DEFAULT_BIN_PATH}"
: "${SS_USER:=$DEFAULT_SS_USER}"
: "${SERVICE_NAME:=$DEFAULT_SERVICE_NAME}"

UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"

log_info "=== 开始卸载 Shadowsocks（shadowsocks-rust）==="
log_info "service=${SERVICE_NAME}, bin=${BIN_PATH}, configDir=${CONFIG_DIR}, user=${SS_USER}"

echo
log_warn "此操作将停止服务并删除以下内容："
echo "  - systemd 服务：${SERVICE_NAME}"
echo "  - 二进制：${BIN_PATH}"
echo "  - 配置目录：${CONFIG_DIR}"
[[ "$KEEP_USER" == "0" ]] && echo "  - 系统用户：${SS_USER}"
echo
read -rp "确认卸载？[y/N]: " _confirm
if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
  log_info "已取消卸载。"
  exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  log_info "停止并禁用服务：${SERVICE_NAME}"
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [[ -f "$UNIT_PATH" ]]; then
    log_info "移除 systemd unit：${UNIT_PATH}"
    rm -f "$UNIT_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
else
  log_warn "systemctl 不可用，跳过 service 卸载步骤"
fi

if [[ -d "$CONFIG_DIR" ]]; then
  log_info "移除配置目录：${CONFIG_DIR}"
  rm -rf "$CONFIG_DIR"
fi

if [[ -f "$BIN_PATH" ]]; then
  log_info "移除二进制：${BIN_PATH}"
  rm -f "$BIN_PATH"
fi

if [[ "$KEEP_USER" == "0" ]]; then
  if id -u "$SS_USER" >/dev/null 2>&1; then
    log_info "移除系统用户：${SS_USER}"
    userdel "$SS_USER" >/dev/null 2>&1 || true
  fi
else
  log_info "按参数要求保留用户：${SS_USER}"
fi

log_ok "卸载完成"
log_warn "提示：如果你之前手动放行过端口（云安全组/防火墙），需要你自行回收规则。"
