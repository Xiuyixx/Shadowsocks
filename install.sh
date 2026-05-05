#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Xiuyixx/Shadowsocks.git"
INSTALL_DIR="/opt/Shadowsocks"
TARGET_BIN="/usr/local/bin/ss"
NO_RUN="0"

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

get_script_dir() {
  local src=""

  if [[ ${BASH_SOURCE[0]-} != "" ]]; then
    src="${BASH_SOURCE[0]}"
  else
    src="$0"
  fi

  if [[ -n "$src" ]] && [[ -e "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    pwd
  fi
}

has_local_ss() {
  local script_dir
  script_dir="$(get_script_dir)"
  [[ -f "${script_dir}/ss.sh" ]]
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  echo "[INFO] 未检测到 git，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    if ! ${SUDO} apt-get update; then
      echo "[ERROR] apt-get update 失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
    if ! ${SUDO} apt-get install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! ${SUDO} dnf install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! ${SUDO} yum install -y git; then
      echo "[ERROR] git 安装失败。请检查网络连接、软件源状态或稍后重试。"
      exit 1
    fi
  else
    echo "[ERROR] 无法自动安装 git，请手动安装后重试。"
    exit 1
  fi
}

install_local() {
  local script_dir
  script_dir="$(get_script_dir)"

  if [[ ! -f "${script_dir}/ss.sh" ]]; then
    echo "[ERROR] ss.sh not found in ${script_dir}"
    exit 1
  fi

  chmod +x "${script_dir}/ss.sh" "${script_dir}/install.sh"
  [[ -f "${script_dir}/uninstall.sh" ]] && chmod +x "${script_dir}/uninstall.sh"

  ${SUDO} mkdir -p "$INSTALL_DIR"
  ${SUDO} cp -f "${script_dir}/install.sh" "$INSTALL_DIR/install.sh"
  ${SUDO} cp -f "${script_dir}/ss.sh" "$INSTALL_DIR/ss.sh"
  if [[ -f "${script_dir}/uninstall.sh" ]]; then
    ${SUDO} cp -f "${script_dir}/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
  fi
  if [[ -f "${script_dir}/README.md" ]]; then
    ${SUDO} cp -f "${script_dir}/README.md" "$INSTALL_DIR/README.md"
  fi

  ${SUDO} chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/ss.sh"
  [[ -f "$INSTALL_DIR/uninstall.sh" ]] && ${SUDO} chmod +x "$INSTALL_DIR/uninstall.sh"

  ${SUDO} mkdir -p "$(dirname "$TARGET_BIN")"
  ${SUDO} install -m 0755 "$INSTALL_DIR/ss.sh" "$TARGET_BIN"

  echo "[OK] Installed. You can now run: ss"

  if [[ "$NO_RUN" != "1" && -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Shadowsocks-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      exec "$TARGET_BIN"
    fi
  fi
}

bootstrap_install() {
  echo "[INFO] 开始一键安装 Shadowsocks-X..."

  install_git_if_needed

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] 检测到已安装目录，正在更新到最新版本..."
    if ! ${SUDO} git -C "$INSTALL_DIR" pull --ff-only; then
      echo "[ERROR] 拉取最新代码失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  elif [[ -e "$INSTALL_DIR" ]]; then
    echo "[WARN] 目标目录已存在，但不是 Git 仓库：$INSTALL_DIR"
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
    echo "[INFO] 已清理旧目录，重新克隆仓库到 $INSTALL_DIR"
    if ! ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR"; then
      echo "[ERROR] 克隆仓库失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  else
    echo "[INFO] 克隆仓库到 $INSTALL_DIR"
    if ! ${SUDO} git clone "$REPO_URL" "$INSTALL_DIR"; then
      echo "[ERROR] 克隆仓库失败。请检查网络连接、GitHub 可达性，或稍后重试。"
      exit 1
    fi
  fi

  # 直接执行安装，不递归调用 install.sh（避免同路径 cp 报错）
  ${SUDO} chmod +x "$INSTALL_DIR/ss.sh" "$INSTALL_DIR/install.sh"
  [[ -f "$INSTALL_DIR/uninstall.sh" ]] && ${SUDO} chmod +x "$INSTALL_DIR/uninstall.sh"

  ${SUDO} mkdir -p "$(dirname "$TARGET_BIN")"
  ${SUDO} install -m 0755 "$INSTALL_DIR/ss.sh" "$TARGET_BIN"

  echo "[OK] 安装完成。可以运行：ss"

  if [[ -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Shadowsocks-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      echo "[OK] 正在启动 Shadowsocks-X..."
      exec "$TARGET_BIN"
    fi
  fi
}

for arg in "$@"; do
  case "$arg" in
    --no-run)
      NO_RUN="1"
      ;;
  esac
done

if has_local_ss; then
  install_local
else
  bootstrap_install
fi
