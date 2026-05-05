#!/usr/bin/env bash
set -euo pipefail

CONFIG_BASE="/etc/shadowsocks"
BIN_PATH="/usr/local/bin/ssserver"
TARGET_BIN="/usr/local/bin/ss"
INSTALL_DIR="/opt/Shadowsocks"
SERVICE_PREFIX="ss-node"
RUN_USER="shadowsocks"

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

list_nodes() {
  local dir
  for dir in "$CONFIG_BASE"/node-*; do
    [[ -d "$dir" ]] || continue
    basename "$dir" | sed 's/^node-//'
  done
}

remove_all_nodes() {
  local node
  for node in $(list_nodes); do
    systemctl disable --now "${SERVICE_PREFIX}-${node}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SERVICE_PREFIX}-${node}.service"
  done
  rm -rf "$CONFIG_BASE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[错误] 请使用 root 执行卸载。"
  exit 1
fi

echo "[信息] Shadowsocks-X 卸载脚本"
echo "1) 卸载所有节点（保留 ssserver 二进制）"
echo "2) 完全卸载（节点 + ssserver + 用户 + ss 命令）"
read -rp "请选择 [1-2]: " choice

case "$choice" in
  1)
    if confirm "确认卸载所有节点？" && confirm "请再次确认：该操作会删除所有节点配置。"; then
      remove_all_nodes
      echo "[成功] 所有节点已卸载，ssserver 二进制已保留。"
    else
      echo "[信息] 已取消。"
    fi
    ;;
  2)
    if confirm "确认完全卸载 Shadowsocks-X？" && confirm "请再次确认：该操作会删除节点、二进制、用户和快捷命令。"; then
      remove_all_nodes
      rm -f "$BIN_PATH" "$TARGET_BIN"
      rm -rf "$INSTALL_DIR"
      userdel "$RUN_USER" >/dev/null 2>&1 || true
      groupdel "$RUN_USER" >/dev/null 2>&1 || true
      echo "[成功] 已完成完全卸载。"
    else
      echo "[信息] 已取消。"
    fi
    ;;
  *)
    echo "[错误] 无效选择。"
    exit 1
    ;;
esac
