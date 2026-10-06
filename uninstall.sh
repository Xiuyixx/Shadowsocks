#!/usr/bin/env bash
set -euo pipefail

# Shared fixed lock with install.sh; never configurable in production.
SS_INSTALL_LOCK_PATH="/run/shadowsocks-installer/operation.lock"
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

# Check existing components, including ancestors of directories not created yet.
# A root-owned sticky ancestor (e.g. /tmp) cannot replace root-owned children.
validate_directory_chain() {
  local path="$1" target="$1" owner mode
  while :; do
    [[ ! -L "$path" ]] || die "Symlink directory component refused: $path"
    if [[ -e "$path" ]]; then
      [[ -d "$path" ]] || die "Not a directory: $path"
      owner="$(stat -c %u "$path")" || return 1
      mode="$(stat -c %a "$path")" || return 1
      [[ "$owner" == 0 ]] || die "Directory must be root-owned: $path"
      if (( (8#$mode & 0022) != 0 )); then
        if [[ "$path" == "$target" || $((8#$mode & 01000)) == 0 ]]; then
          die "Directory must not be group/world writable: $path"
        fi
      fi
    fi
    [[ "$path" != / ]] || break
    path="${path%/*}"; [[ -n "$path" ]] || path=/
  done
}


validate_install_inputs() {
  local bin_dir config_dir user="$3"
  bin_dir="$(normalize_path "$1")" || return 1
  config_dir="$(normalize_path "$2")" || return 1
  if ! safe_directory "$bin_dir" || ! safe_directory "$config_dir"; then die "Unsafe install directory"; fi
  validate_directory_chain "$1" || return 1
  validate_directory_chain "$2" || return 1
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid --user: $user"
  case "$user" in root|daemon|nobody|bin|sys|sync|www-data|sshd|systemd-*) die "Critical service user: $user" ;; esac
  if id -u "$user" >/dev/null 2>&1; then
    [[ "$(id -u "$user")" != 0 ]] || die "Cannot run as UID 0"
  fi
}

validate_uninstall_inputs() {
  [[ ! -L "$BIN_PATH" && ! -L "$CONFIG_DIR" ]] || die "Refusing symlink uninstall targets"
  validate_directory_chain "${BIN_PATH%/*}" || return 1
  validate_directory_chain "$CONFIG_DIR" || return 1
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
acquire_install_lock

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
validate_directory_chain "$meta_config_dir" || exit 1
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

command -v systemctl >/dev/null 2>&1 || die "systemctl required; refusing to delete a potentially running installation"
# Each backup lives beside its target, so staging/restoration uses same-filesystem
# renames. Keep backups until all reversible steps and userdel have succeeded.
declare -a targets=() stages=() staged=()
service_touched=0
user_delete_attempted=0
committed=0
was_active=0
if systemctl is-active --quiet "$SERVICE_NAME"; then
  was_active=1
else
  status=$?
  [[ "$status" == 3 || "$status" == 4 ]] || die "Cannot query service active state"
fi
was_enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)" || true
case "$was_enabled" in
  enabled|enabled-runtime|disabled|static|indirect|not-found) ;;
  *) die "Cannot safely restore service enable state: $was_enabled" ;;
esac

rollback_uninstall() {
  local failed=0 i
  log_warn "卸载失败；尝试恢复文件和服务状态"
  for ((i=${#targets[@]}-1; i>=0; i--)); do
    if [[ -e "${stages[i]}/original" ]]; then
      if [[ -e "${targets[i]}" || -L "${targets[i]}" ]] || ! mv -T -- "${stages[i]}/original" "${targets[i]}"; then
        log_warn "恢复失败：${targets[i]}；备份保留：${stages[i]}"
        failed=1
        continue
      fi
    elif [[ "${staged[i]}" == 1 || ! -f "${targets[i]}" || -L "${targets[i]}" ]]; then
      log_warn "恢复失败：${targets[i]}；必要备份丢失：${stages[i]}/original"
      failed=1
    fi
    rmdir -- "${stages[i]}" || { log_warn "备份目录清理失败：${stages[i]}"; failed=1; }
  done
  if [[ "$user_delete_attempted" == 1 ]] && ! id -u "$SS_USER" >/dev/null 2>&1; then
    log_warn "账号已不存在，删除不可逆；无法自动恢复账户和运行状态"
    failed=1
  fi
  if [[ "$service_touched" == 1 ]]; then
    systemctl daemon-reload || { log_warn "恢复时 daemon-reload 失败"; failed=1; }
    case "$was_enabled" in
      enabled) systemctl enable "$SERVICE_NAME" || { log_warn "恢复服务启用状态失败"; failed=1; } ;;
      enabled-runtime) systemctl enable --runtime "$SERVICE_NAME" || { log_warn "恢复服务启用状态失败"; failed=1; } ;;
      disabled) systemctl disable "$SERVICE_NAME" || { log_warn "恢复服务禁用状态失败"; failed=1; } ;;
    esac
    if [[ "$was_active" == 1 && "$failed" == 0 ]]; then
      systemctl start "$SERVICE_NAME" || { log_warn "恢复服务运行状态失败"; failed=1; }
    elif [[ "$was_active" == 0 ]]; then
      systemctl stop "$SERVICE_NAME" || { log_warn "恢复服务停止状态失败"; failed=1; }
    fi
  fi
  if [[ "$failed" == 1 ]]; then
    log_warn "回滚不完整，可能处于半卸载状态；请根据上述备份路径和错误手动恢复"
  else
    log_info "已恢复卸载前的文件和服务状态"
  fi
}
uninstall_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "$committed" == 0 ]]; then
    rollback_uninstall
    [[ "$status" != 0 ]] || status=1
  fi
  exit "$status"
}
trap uninstall_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for target in "$UNIT_PATH" "$CONFIG_DIR/config.json" "$META_PATH" "$BIN_PATH"; do
  [[ -e "$target" ]] || continue
  [[ -f "$target" && ! -L "$target" ]] || die "Unsafe uninstall file: $target"
  stage="$(mktemp -d "${target%/*}/.ss-uninstall.XXXXXX")" || die "Cannot stage uninstall target: $target"
  targets+=("$target"); stages+=("$stage"); staged+=(0)
  [[ "$(stat -c %d -- "$target")" == "$(stat -c %d -- "$stage")" ]] || die "Uninstall staging must use the same filesystem: $target"
done
service_touched=1
log_info "停止并禁用服务：${SERVICE_NAME}"
systemctl stop "$SERVICE_NAME" || die "Failed to stop service"
systemctl disable --now "$SERVICE_NAME" || die "Failed to disable service"
for i in "${!targets[@]}"; do
  mv -T -- "${targets[i]}" "${stages[i]}/original" || die "Failed to stage uninstall target: ${targets[i]}"
  staged[i]=1
done
systemctl daemon-reload || die "Failed to reload systemd after uninstall"

if [[ "$KEEP_USER" == "0" && "$CREATED_USER" == true ]]; then
  if id -u "$SS_USER" >/dev/null 2>&1; then
    log_info "移除系统用户：${SS_USER}"
    user_delete_attempted=1
    userdel "$SS_USER" || die "Failed to delete service user; attempting rollback"
  fi
else
  log_info "保留用户：${SS_USER}"
fi
# Account deletion cannot be undone; never roll files back after this boundary.
committed=1
cleanup_failed=0
for stage in "${stages[@]}"; do
  if ! rm -f -- "$stage/original" || ! rmdir -- "$stage"; then
    log_warn "卸载已提交，但备份清理失败（可能含敏感配置）：$stage"
    cleanup_failed=1
  fi
done
[[ "$cleanup_failed" == 0 ]] || die "Uninstall backup cleanup incomplete"
if [[ -d "$CONFIG_DIR" ]]; then
  rmdir -- "$CONFIG_DIR" 2>/dev/null || log_info "保留非空或无法移除的配置目录：${CONFIG_DIR}"
fi
log_ok "卸载完成"
log_warn "提示：如果你之前手动放行过端口（云安全组/防火墙），需要你自行回收规则。"
