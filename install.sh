#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Xiuyixx/Shadowsocks.git"
INSTALL_DIR="/opt/Shadowsocks"
TARGET_BIN="/usr/local/bin/ss"

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  echo "[ERROR] 需要 root 权限或可用的 sudo。请使用 root 运行，或先安装 sudo。"
  exit 1
fi

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] 未检测到 git，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    ${SUDO} apt-get update -y || { echo "[ERROR] apt-get update 失败。"; exit 1; }
    ${SUDO} apt-get install -y git || { echo "[ERROR] git 安装失败。"; exit 1; }
  elif command -v dnf >/dev/null 2>&1; then
    ${SUDO} dnf install -y git || { echo "[ERROR] git 安装失败。"; exit 1; }
  elif command -v yum >/dev/null 2>&1; then
    ${SUDO} yum install -y git || { echo "[ERROR] git 安装失败。"; exit 1; }
  else
    echo "[ERROR] 无法自动安装 git，请手动安装后重试。"
    exit 1
  fi
}

# 将 INSTALL_DIR 中的文件安装到系统（chmod + 创建 /usr/local/bin/ss）
do_install_from_dir() {
  ${SUDO} chmod +x "$INSTALL_DIR/ss.sh" "$INSTALL_DIR/install.sh"
  [[ -f "$INSTALL_DIR/uninstall.sh" ]] && ${SUDO} chmod +x "$INSTALL_DIR/uninstall.sh"

  ${SUDO} mkdir -p "$(dirname "$TARGET_BIN")"
  ${SUDO} install -m 0755 "$INSTALL_DIR/ss.sh" "$TARGET_BIN"

  echo "[OK] 安装完成，可以运行：ss"
}

maybe_launch() {
  if [[ -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Shadowsocks-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      exec "$TARGET_BIN"
    fi
  fi
}

# ── 本地安装（从仓库目录直接执行 bash install.sh）──────────────────────────
# 判断依据：脚本文件本身存在于磁盘（BASH_SOURCE[0] 可解析为真实文件）
# 且其同级目录下有 ss.sh（说明是在克隆目录里执行）
local_install() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ ! -f "$script_dir/ss.sh" ]]; then
    echo "[ERROR] ss.sh 未找到：$script_dir"
    exit 1
  fi

  # 源目录与目标目录不同时才需要 cp
  if [[ "$(realpath "$script_dir")" != "$(realpath "$INSTALL_DIR" 2>/dev/null || echo __none__)" ]]; then
    ${SUDO} mkdir -p "$INSTALL_DIR"
    ${SUDO} cp -f "$script_dir/ss.sh"      "$INSTALL_DIR/ss.sh"
    ${SUDO} cp -f "$script_dir/install.sh" "$INSTALL_DIR/install.sh"
    [[ -f "$script_dir/uninstall.sh" ]] && ${SUDO} cp -f "$script_dir/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
    [[ -f "$script_dir/README.md"    ]] && ${SUDO} cp -f "$script_dir/README.md"    "$INSTALL_DIR/README.md"
  fi

  do_install_from_dir
  maybe_launch
}

# ── Bootstrap 安装（curl | bash 或 bash -c "$(curl ...)"）─────────────────
bootstrap_install() {
  echo "[INFO] 开始一键安装 Shadowsocks-X..."

  install_git_if_needed

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] 检测到已安装目录，正在更新到最新版本..."
    if ! ${SUDO} git -C "$INSTALL_DIR" pull --ff-only; then
      echo "[ERROR] 拉取最新代码失败。请检查网络或稍后重试。"
      exit 1
    fi
  elif [[ -e "$INSTALL_DIR" ]]; then
    echo "[WARN] 目标目录已存在但不是 Git 仓库：$INSTALL_DIR"
    if [[ -t 0 && -t 1 ]]; then
      if ! confirm "是否清空该目录并重新安装？"; then
        echo "[INFO] 已取消安装。"
        exit 0
      fi
    else
      echo "[ERROR] 非交互模式下不会自动删除已有目录，请先手动清理：$INSTALL_DIR"
      exit 1
    fi
    ${SUDO} rm -rf "$INSTALL_DIR"
    echo "[INFO] 重新克隆仓库到 $INSTALL_DIR"
    ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR" || { echo "[ERROR] 克隆仓库失败。"; exit 1; }
  else
    echo "[INFO] 克隆仓库到 $INSTALL_DIR"
    ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR" || { echo "[ERROR] 克隆仓库失败。"; exit 1; }
  fi

  do_install_from_dir
  maybe_launch
}

# ── 入口判断 ──────────────────────────────────────────────────────────────
# curl|bash 执行时 BASH_SOURCE[0] 为空或为 "bash"，无法解析为真实文件 → bootstrap
# 本地 bash install.sh 执行时 BASH_SOURCE[0] 为真实路径 → local_install
_src="${BASH_SOURCE[0]-}"
if [[ -n "$_src" && -f "$_src" ]]; then
  local_install
else
  bootstrap_install
fi
