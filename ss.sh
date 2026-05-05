#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Shadowsocks-X"
APP_VERSION="1.0.0"
CONFIG_BASE="/etc/shadowsocks"
BIN_PATH="/usr/local/bin/ssserver"
SERVICE_PREFIX="ss-node"
RUN_USER="shadowsocks"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

info() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }
note() { echo -e "${BLUE}[信息]${NC} $*"; }

pause() {
  echo
  read -rp "按回车继续..." _
}

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

run_menu_action() {
  hash -r 2>/dev/null || true
  "$@" || true
}

check_cmd() {
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]]
}

require_root() {
  if [[ -n "$SUDO" ]] && ! check_cmd sudo; then
    error "请使用 root 运行，或安装 sudo 后再执行 ss。"
    return 1
  fi
}

ensure_dirs() {
  ${SUDO} mkdir -p "$CONFIG_BASE"
  ${SUDO} chmod 750 "$CONFIG_BASE"
}

get_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) error "暂不支持的架构：$arch"; return 1 ;;
  esac
}

github_api() {
  local url="$1"
  curl -fsSL \
    --connect-timeout 5 \
    --max-time 20 \
    --retry 3 \
    --retry-delay 1 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: Shadowsocks-X' \
    "$url"
}

get_latest_version() {
  local tag
  tag="$(github_api "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r '.tag_name')"
  [[ -n "$tag" && "$tag" != "null" ]] || return 1
  echo "$tag"
}

ensure_runtime_dependencies() {
  local missing=()
  local cmd

  for cmd in curl tar xz systemctl openssl awk sed grep jq; do
    check_cmd "$cmd" || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  note "正在安装依赖：${missing[*]}"
  if check_cmd apt-get; then
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y curl tar xz-utils systemd openssl iproute2 coreutils jq
  elif check_cmd dnf; then
    ${SUDO} dnf install -y curl tar xz systemd openssl iproute coreutils jq
  elif check_cmd yum; then
    ${SUDO} yum install -y curl tar xz systemd openssl iproute coreutils jq
  else
    error "无法自动安装依赖，请手动安装：${missing[*]}"
    return 1
  fi
}

ensure_run_user() {
  if ! getent group "$RUN_USER" >/dev/null 2>&1; then
    ${SUDO} groupadd --system "$RUN_USER" >/dev/null 2>&1 || true
  fi

  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    note "正在创建系统用户：$RUN_USER"
    ${SUDO} useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$RUN_USER" "$RUN_USER" 2>/dev/null \
      || ${SUDO} useradd --system --no-create-home --shell /sbin/nologin --gid "$RUN_USER" "$RUN_USER"
  fi
}

current_ssserver_version() {
  if [[ -x "$BIN_PATH" ]]; then
    "$BIN_PATH" --version 2>&1 | head -n1
  else
    echo ""
  fi
}

version_gt() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}

random_string() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '=\n'
}

validate_ss2022_password() {
  local method="$1"
  local password="$2"
  local required_bytes=0
  local padded
  local decoded_len

  case "$method" in
    2022-blake3-aes-128-gcm) required_bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) required_bytes=32 ;;
    *) return 0 ;;
  esac

  [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ || "$password" =~ ^[A-Za-z0-9+/]+$ ]] || return 1
  padded="$(pad_base64 "$password")" || return 1
  decoded_len="$(printf '%s' "$padded" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  [[ "$decoded_len" == "$required_bytes" ]]
}

pad_base64() {
  local value="$1"
  local remainder=$(( ${#value} % 4 ))

  case "$remainder" in
    0) printf '%s' "$value" ;;
    2) printf '%s==' "$value" ;;
    3) printf '%s=' "$value" ;;
    *) return 1 ;;
  esac
}

generate_password() {
  local method="$1"
  case "$method" in
    2022-blake3-aes-128-gcm) random_string 16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) random_string 32 ;;
    *) random_string 24 ;;
  esac
}

port_in_use() {
  local port="$1"
  ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$"
}

random_free_port() {
  local port attempt=0
  while (( attempt < 200 )); do
    port="$((10000 + (0x$(openssl rand -hex 4) % 50001)))"
    if ! port_in_use "$port"; then
      echo "$port"
      return 0
    fi
    ((attempt++))
  done

  error "随机端口分配失败，请手动指定端口。"
  return 1
}

node_dir() {
  echo "${CONFIG_BASE}/node-$1"
}

node_config_path() {
  echo "$(node_dir "$1")/config.json"
}

node_meta_path() {
  echo "$(node_dir "$1")/meta.env"
}

service_name() {
  echo "${SERVICE_PREFIX}-$1.service"
}

service_unit_path() {
  echo "/etc/systemd/system/$(service_name "$1")"
}

mode_to_label() {
  case "$1" in
    tcp_and_udp) echo "TCP + UDP" ;;
    tcp_only) echo "仅 TCP" ;;
    udp_only) echo "仅 UDP" ;;
    *) echo "$1" ;;
  esac
}

service_state() {
  local name="$1"
  if systemctl is-active --quiet "$(service_name "$name")"; then
    echo "running"
  else
    echo "stopped"
  fi
}

load_node_meta() {
  local name="$1"
  local meta_file
  meta_file="$(node_meta_path "$name")"
  [[ -f "$meta_file" ]] || return 1
  # shellcheck disable=SC1090
  . "$meta_file"
}

list_nodes() {
  local dir
  for dir in "$CONFIG_BASE"/node-*; do
    [[ -d "$dir" ]] || continue
    basename "$dir" | sed 's/^node-//'
  done | sort
}

get_public_ip() {
  local ip source
  for source in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com" "https://ipinfo.io/ip"; do
    ip="$(curl -fsSL --max-time 5 "$source" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  done
  warn "公网 IP 获取失败，请手动确认服务器地址。"
  echo "<YOUR_SERVER_IP>"
}

base64_url() {
  printf '%s' "$1" | base64 | tr -d '=\n' | tr '+/' '-_'
}

generate_ss_link() {
  local method="$1"
  local password="$2"
  local host="$3"
  local port="$4"
  local name="$5"
  local userinfo
  local encoded_name
  userinfo="$(base64_url "${method}:${password}")"
  encoded_name="$(jq -nr --arg v "$name" '$v|@uri')"
  echo "ss://${userinfo}@${host}:${port}#${encoded_name}"
}

write_node_config() {
  local name="$1"
  local port="$2"
  local password="$3"
  local method="$4"
  local mode="$5"
  local dir config_path tmp meta_path meta_tmp

  dir="$(node_dir "$name")"
  config_path="$(node_config_path "$name")"
  meta_path="$(node_meta_path "$name")"
  tmp="$(mktemp)"
  meta_tmp="$(mktemp)"

  ${SUDO} mkdir -p "$dir"
  jq -n \
    --arg server "::" \
    --argjson server_port "$port" \
    --arg password "$password" \
    --arg method "$method" \
    --arg mode "$mode" \
    '{
      server: $server,
      server_port: $server_port,
      password: $password,
      method: $method,
      mode: $mode,
      timeout: 300,
      fast_open: false,
      nameserver: "1.1.1.1"
    }' > "$tmp"
  ${SUDO} install -m 0640 -o root -g "$RUN_USER" "$tmp" "$config_path"
  rm -f "$tmp"

  printf 'NODE_NAME=%q\nNODE_PORT=%q\nNODE_PASSWORD=%q\nNODE_METHOD=%q\nNODE_MODE=%q\n' \
    "$name" "$port" "$password" "$method" "$mode" > "$meta_tmp"
  ${SUDO} install -m 0600 -o root -g root "$meta_tmp" "$meta_path"
  rm -f "$meta_tmp"
}

write_node_service() {
  local name="$1"
  local unit_path
  unit_path="$(service_unit_path "$name")"

  ${SUDO} tee "$unit_path" >/dev/null <<EOF
[Unit]
Description=Shadowsocks Node ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${BIN_PATH} -c $(node_config_path "$name")
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$(node_dir "$name")
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
}

download_and_install_ssserver() {
  local version="$1"
  local arch release_json tar_url tar_name tmp_dir latest installed_version

  ensure_runtime_dependencies
  ensure_run_user

  arch="$(get_arch)" || return 1
  installed_version="$(current_ssserver_version)"

  if [[ -x "$BIN_PATH" ]]; then
    warn "检测到已安装 ssserver：${installed_version:-未知版本}"
    if ! confirm "是否继续升级 / 重装？"; then
      info "已取消。"
      return 0
    fi
  fi

  if [[ "$version" == "latest" ]]; then
    latest="$(get_latest_version)" || {
      error "获取最新版本失败。"
      return 1
    }
    version="$latest"
  fi

  note "目标版本：$version"
  release_json="$(github_api "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/tags/${version}")" || {
    error "获取版本元数据失败：$version"
    return 1
  }

  tar_url="$(jq -r --arg arch "$arch" '.assets[]? | select(.name | test("\\." + $arch + "\\.tar\\.xz$")) | .browser_download_url' <<<"$release_json" | head -n1)"
  tar_name="$(jq -r --arg arch "$arch" '.assets[]? | select(.name | test("\\." + $arch + "\\.tar\\.xz$")) | .name' <<<"$release_json" | head -n1)"

  if [[ -z "$tar_url" || -z "$tar_name" ]]; then
    error "未找到适用于当前架构的发布包：$arch"
    return 1
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir:-}"' RETURN

  note "正在下载：$tar_name"
  curl -fL --retry 3 --retry-delay 1 -o "$tmp_dir/$tar_name" "$tar_url"

  local sha_url expected actual sha_file
  sha_url="$(jq -r '.assets[]? | select(.name | endswith(".sha256")) | .browser_download_url' <<<"$release_json" | head -n1)"
  if [[ -n "$sha_url" ]]; then
    sha_file="$tmp_dir/${tar_name}.sha256"
    if curl -fsSL "$sha_url" -o "$sha_file"; then
      expected="$(awk -v n="$tar_name" '$2==n || $2=="*"n || $2=="./"n || $NF==n {print $1; exit}' "$sha_file")"
      if [[ -n "$expected" ]]; then
        actual="$(sha256sum "$tmp_dir/$tar_name" | awk '{print $1}')"
        if [[ "$expected" != "$actual" ]]; then
          error "sha256 校验失败。"
          return 1
        fi
        info "sha256 校验通过。"
      else
        warn "sha256 文件中未找到目标文件条目，已跳过校验。"
      fi
    else
      warn "sha256 文件下载失败，已跳过校验。"
    fi
  else
    warn "上游未提供 sha256 文件，已跳过校验。"
  fi

  tar -C "$tmp_dir" -xJf "$tmp_dir/$tar_name"
  [[ -f "$tmp_dir/ssserver" ]] || {
    error "发布包中未找到 ssserver。"
    return 1
  }

  ${SUDO} install -m 0755 "$tmp_dir/ssserver" "$BIN_PATH"
  info "ssserver 已安装到：$BIN_PATH"
  info "当前版本：$($BIN_PATH --version 2>&1 | head -n1)"
  return 0
}

install_or_upgrade() {
  local version
  version="latest"
  if [[ -x "$BIN_PATH" ]]; then
    note "当前已安装版本：$(current_ssserver_version)"
    read -rp "请输入目标版本（默认 latest，可填 v1.22.0 之类）: " version
    [[ -z "$version" ]] && version="latest"
  fi
  run_menu_action download_and_install_ssserver "$version"
}

show_node_row() {
  local name="$1"
  local NODE_PORT NODE_PASSWORD NODE_METHOD NODE_MODE
  if ! load_node_meta "$name"; then
    warn "节点 $name 元数据缺失，已跳过。"
    return 0
  fi
  printf '%-18s %-8s %-30s %-10s\n' "$name" "$NODE_PORT" "$NODE_METHOD" "$(service_state "$name")"
}

view_all_nodes() {
  local nodes=()
  mapfile -t nodes < <(list_nodes)

  if [[ ${#nodes[@]} -eq 0 ]]; then
    warn "暂无节点"
    return 0
  fi

  printf '%-18s %-8s %-30s %-10s\n' "节点名" "端口" "加密方式" "状态"
  printf '%-18s %-8s %-30s %-10s\n' "------" "----" "--------" "----"
  local node
  for node in "${nodes[@]}"; do
    show_node_row "$node"
  done
}

choose_method() {
  local choice method
  while true; do
    echo "请选择加密方式:" >&2
    echo "  1) aes-128-gcm        （推荐，兼容性好）" >&2
    echo "  2) aes-256-gcm" >&2
    echo "  3) chacha20-ietf-poly1305  （推荐，移动端友好）" >&2
    echo "  4) 2022-blake3-aes-128-gcm  （SS2022，需客户端支持）" >&2
    echo "  5) 2022-blake3-aes-256-gcm  （SS2022）" >&2
    echo "  6) 2022-blake3-chacha20-poly1305  （SS2022）" >&2
    echo "  7) 自定义输入" >&2
    read -rp "请选择 [1-7]: " choice
    case "$choice" in
      1) method="aes-128-gcm" ;;
      2) method="aes-256-gcm" ;;
      3) method="chacha20-ietf-poly1305" ;;
      4) method="2022-blake3-aes-128-gcm" ;;
      5) method="2022-blake3-aes-256-gcm" ;;
      6) method="2022-blake3-chacha20-poly1305" ;;
      7)
        read -rp "请输入自定义加密方式: " method
        ;;
      *) echo "无效输入，请输入 1-7。" >&2; continue ;;
    esac
    [[ -n "$method" ]] || { echo "加密方式不能为空。" >&2; continue; }
    echo "$method"
    return 0
  done
}

choose_port() {
  local choice port
  while true; do
    echo "端口设置:" >&2
    echo "  1) 自动生成随机端口（10000-60000）" >&2
    echo "  2) 手动输入端口" >&2
    read -rp "请选择 [1-2]: " choice
    case "$choice" in
      1)
        port="$(random_free_port)"
        echo "已生成随机端口：$port" >&2
        echo "$port"
        return 0
        ;;
      2)
        while true; do
          read -rp "请输入端口（10000-60000）: " port
          [[ "$port" =~ ^[0-9]+$ ]] || { echo "端口必须是数字。" >&2; continue; }
          (( port >= 10000 && port <= 60000 )) || { echo "端口超出范围。" >&2; continue; }
          if port_in_use "$port"; then
            echo "端口 $port 已被占用，请重新输入。" >&2
            continue
          fi
          echo "$port"
          return 0
        done
        ;;
      *) echo "无效输入，请输入 1 或 2。" >&2 ;;
    esac
  done
}

choose_password() {
  local method="$1"
  local choice password
  while true; do
    echo "密码设置:" >&2
    echo "  1) 自动生成随机密码" >&2
    echo "  2) 手动输入密码" >&2
    read -rp "请选择 [1-2]: " choice
    case "$choice" in
      1)
        password="$(generate_password "$method")"
        echo "已自动生成密码。" >&2
        echo "$password"
        return 0
        ;;
      2)
        read -rp "请输入密码: " password
        [[ -n "$password" ]] || { echo "密码不能为空。" >&2; continue; }
        if [[ "$method" == 2022-* ]]; then
          if ! validate_ss2022_password "$method" "$password"; then
            echo "SS2022 密码必须是对应长度的 base64 字符串。" >&2
            case "$method" in
              2022-blake3-aes-128-gcm) echo "可用命令：openssl rand -base64 16" >&2 ;;
              2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo "可用命令：openssl rand -base64 32" >&2 ;;
            esac
            continue
          fi
        fi
        echo "$password"
        return 0
        ;;
      *) echo "无效输入，请输入 1 或 2。" >&2 ;;
    esac
  done
}

choose_mode() {
  local choice mode
  while true; do
    echo "传输模式:" >&2
    echo "  1) TCP + UDP（默认）" >&2
    echo "  2) 仅 TCP" >&2
    echo "  3) 仅 UDP" >&2
    read -rp "请选择 [1-3]: " choice
    case "$choice" in
      1|"") mode="tcp_and_udp" ;;
      2) mode="tcp_only" ;;
      3) mode="udp_only" ;;
      *) echo "无效输入，请输入 1-3。" >&2; continue ;;
    esac
    echo "$mode"
    return 0
  done
}

select_node_interactive() {
  local prompt="$1"
  local nodes=() choice idx
  mapfile -t nodes < <(list_nodes)

  if [[ ${#nodes[@]} -eq 0 ]]; then
    warn "暂无节点"
    return 1
  fi

  local i=1
  for idx in "${!nodes[@]}"; do
    echo "  $i) ${nodes[$idx]}" >&2
    ((i++))
  done

  while true; do
    read -rp "$prompt" choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "请输入编号。" >&2; continue; }
    (( choice >= 1 && choice <= ${#nodes[@]} )) || { echo "编号超出范围。" >&2; continue; }
    echo "${nodes[$((choice-1))]}"
    return 0
  done
}

add_node() {
  local name method port password mode public_ip link
  local NODE_PORT NODE_PASSWORD NODE_METHOD NODE_MODE

  [[ -x "$BIN_PATH" ]] || {
    error "未检测到 ssserver，请先执行 [1) 安装 / 升级 ssserver]。"
    return 1
  }

  while true; do
    read -rp "请输入节点名称（字母/数字/下划线）: " name
    [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || { warn "节点名称只能包含字母、数字、下划线。"; continue; }
    [[ ! -d "$(node_dir "$name")" ]] || { warn "节点名称已存在，请重新输入。"; continue; }
    break
  done

  method="$(choose_method)"
  port="$(choose_port)"
  password="$(choose_password "$method")"
  mode="$(choose_mode)"

  echo
  note "请确认以下信息："
  echo "节点名称：$name"
  echo "加密方式：$method"
  echo "端口：$port"
  echo "密码：$password"
  echo "传输模式：$(mode_to_label "$mode")"

  if ! confirm "确认创建该节点？"; then
    info "已取消创建。"
    return 0
  fi

  write_node_config "$name" "$port" "$password" "$method" "$mode"
  write_node_service "$name"

  if ! ${SUDO} systemctl daemon-reload; then
    error "systemctl daemon-reload 失败。"
    return 1
  fi
  if ! ${SUDO} systemctl enable --now "$(service_name "$name")"; then
    error "节点 $name 启动失败，请检查配置或日志。"
    return 1
  fi

  public_ip="$(get_public_ip)"
  link="$(generate_ss_link "$method" "$password" "$public_ip" "$port" "$name")"

  info "节点创建完成。"
  echo "节点名称：$name"
  echo "服务器地址：$public_ip"
  echo "端口：$port"
  echo "加密方式：$method"
  echo "密码：$password"
  echo "传输模式：$(mode_to_label "$mode")"
  echo "SS链接：$link"
}

delete_node() {
  local name
  echo "请选择要删除的节点："
  name="$(select_node_interactive "输入编号: ")" || return 1

  if ! confirm "确认删除节点 $name 吗？"; then
    info "已取消删除。"
    return 0
  fi

  ${SUDO} systemctl disable --now "$(service_name "$name")" >/dev/null 2>&1 || true
  ${SUDO} rm -f "$(service_unit_path "$name")"
  ${SUDO} rm -rf "$(node_dir "$name")"
  ${SUDO} systemctl daemon-reload >/dev/null 2>&1 || true
  info "节点 $name 已删除。"
}

show_node_details() {
  local name public_ip link
  local NODE_PORT NODE_PASSWORD NODE_METHOD NODE_MODE

  echo "请选择要查看的节点："
  name="$(select_node_interactive "输入编号: ")" || return 1
  load_node_meta "$name" || {
    error "读取节点元数据失败。"
    return 1
  }

  public_ip="$(get_public_ip)"
  link="$(generate_ss_link "$NODE_METHOD" "$NODE_PASSWORD" "$public_ip" "$NODE_PORT" "$name")"

  echo "节点名称：$name"
  echo "服务器地址：$public_ip"
  echo "端口：$NODE_PORT"
  echo "加密方式：$NODE_METHOD"
  echo "密码：$NODE_PASSWORD"
  echo "传输模式：$(mode_to_label "$NODE_MODE")"
  echo "服务状态：$(service_state "$name")"
  echo "SS链接：$link"
}

control_node() {
  local name action
  echo "请选择节点："
  name="$(select_node_interactive "输入编号: ")" || return 1

  echo "1) 启动"
  echo "2) 停止"
  echo "3) 重启"
  read -rp "请选择操作: " action

  case "$action" in
    1)
      if ${SUDO} systemctl start "$(service_name "$name")"; then
        info "节点 $name 已启动。"
      else
        error "节点 $name 启动失败。"
        return 1
      fi
      ;;
    2)
      if ${SUDO} systemctl stop "$(service_name "$name")"; then
        info "节点 $name 已停止。"
      else
        error "节点 $name 停止失败。"
        return 1
      fi
      ;;
    3)
      if ${SUDO} systemctl restart "$(service_name "$name")"; then
        info "节点 $name 已重启。"
      else
        error "节点 $name 重启失败。"
        return 1
      fi
      ;;
    *)
      warn "无效输入。"
      ;;
  esac
}

node_menu() {
  while true; do
    clear
    echo "节点管理"
    echo "========================================"
    echo "1) 查看所有节点"
    echo "2) 新增节点"
    echo "3) 删除节点"
    echo "4) 查看节点详情 / SS 链接"
    echo "5) 启动 / 停止 / 重启节点"
    echo "0) 返回主菜单"
    echo "========================================"
    read -rp "请选择功能: " choice

    case "$choice" in
      1) run_menu_action view_all_nodes; pause ;;
      2) run_menu_action add_node; pause ;;
      3) run_menu_action delete_node; pause ;;
      4) run_menu_action show_node_details; pause ;;
      5) run_menu_action control_node; pause ;;
      0) return 0 ;;
      *) warn "无效输入，请输入 0-5。"; pause ;;
    esac
  done
}

service_status() {
  local nodes=()
  local node NODE_PORT NODE_PASSWORD NODE_METHOD NODE_MODE listen_state active_state
  mapfile -t nodes < <(list_nodes)

  if [[ ${#nodes[@]} -eq 0 ]]; then
    warn "暂无节点"
    return 0
  fi

  printf '%-18s %-10s %-10s %-10s\n' "节点名" "systemd" "监听" "端口"
  printf '%-18s %-10s %-10s %-10s\n' "------" "-------" "----" "----"
  for node in "${nodes[@]}"; do
    load_node_meta "$node" || continue
    if systemctl is-active --quiet "$(service_name "$node")"; then
      active_state="active"
    elif systemctl is-failed --quiet "$(service_name "$node")"; then
      active_state="failed"
    else
      active_state="inactive"
    fi

    if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$NODE_PORT$"; then
      listen_state="listening"
    else
      listen_state="closed"
    fi

    printf '%-18s %-10s %-10s %-10s\n' "$node" "$active_state" "$listen_state" "$NODE_PORT"
  done
}

uninstall_all_nodes() {
  local nodes=() node
  mapfile -t nodes < <(list_nodes)
  for node in "${nodes[@]}"; do
    ${SUDO} systemctl disable --now "$(service_name "$node")" >/dev/null 2>&1 || true
    ${SUDO} rm -f "$(service_unit_path "$node")"
  done
  ${SUDO} rm -rf "$CONFIG_BASE"
  ${SUDO} systemctl daemon-reload >/dev/null 2>&1 || true
}

uninstall_menu() {
  local choice
  while true; do
    clear
    echo "卸载选项:"
    echo "  1) 卸载所有节点（保留 ssserver 二进制）"
    echo "  2) 完全卸载（节点 + ssserver + 用户）"
    echo "  0) 返回"
    read -rp "请选择功能: " choice

    case "$choice" in
      1)
        if confirm "确认卸载所有节点？" && confirm "请再次确认：该操作会删除所有节点配置。"; then
          uninstall_all_nodes
          info "所有节点已卸载，ssserver 二进制已保留。"
        else
          info "已取消卸载。"
        fi
        pause
        ;;
      2)
        if confirm "确认完全卸载 Shadowsocks-X？" && confirm "请再次确认：该操作会删除节点、二进制和系统用户。"; then
          uninstall_all_nodes
          ${SUDO} rm -f "$BIN_PATH"
          if id -u "$RUN_USER" >/dev/null 2>&1; then
            ${SUDO} userdel "$RUN_USER" >/dev/null 2>&1 || true
          fi
          info "已完成完全卸载。"
        else
          info "已取消卸载。"
        fi
        pause
        ;;
      0) return 0 ;;
      *) warn "无效输入，请输入 0-2。"; pause ;;
    esac
  done
}

banner() {
  clear
  echo "${APP_NAME} v${APP_VERSION}"
  echo "========================================"
}

main_menu() {
  echo "1) 安装 / 升级 ssserver"
  echo "2) 节点管理"
  echo "3) 查看服务状态"
  echo "4) 卸载"
  echo "0) 退出"
  echo "========================================"
}

main() {
  require_root || exit 1
  ensure_dirs

  while true; do
    banner
    main_menu
    read -rp "请选择功能: " choice

    case "$choice" in
      1) run_menu_action install_or_upgrade; pause ;;
      2) node_menu ;;
      3) run_menu_action service_status; pause ;;
      4) uninstall_menu ;;
      0) info "已退出 ${APP_NAME}。"; exit 0 ;;
      *) warn "无效输入，请输入主菜单编号（0-4）。"; pause ;;
    esac
  done
}

main
