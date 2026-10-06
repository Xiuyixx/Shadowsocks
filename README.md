# Shadowsocks 一键安装（默认：aes-128-gcm）

一个尽量“克制”的 **curl | bash** 一键安装脚本，用于部署 **Shadowsocks（shadowsocks-rust）** 服务端。

- 默认加密：`aes-128-gcm`
- 默认端口：`8388`
- 默认从 GitHub Releases 安装（默认取最新版本）
- 使用 systemd 管理，并以最小权限系统用户运行（带基础 hardening）
- **当前定位是单节点 / 单实例脚本**，重复执行表示升级或覆盖当前节点，不是新增多个节点

> 如果你更在意可复现/安全性，建议使用 `--version vX.Y.Z` 固定版本，而不是永远安装 latest。

## 支持系统

- Debian / Ubuntu（使用 `apt`）
- CentOS / RHEL / Rocky / AlmaLinux / Fedora（使用 `dnf` / `yum`）
- 架构：`x86_64`、`aarch64`
- 初始化：`systemd`

## 快速开始

### 安装最新版本（默认）

推荐写法：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash
```

### 自定义端口与密码安装

推荐写法：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --port 12345 --password 'YOUR_STRONG_PASSWORD'
```

如需只走 TCP（不启用 UDP）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --port 12345 --password 'YOUR_STRONG_PASSWORD' --mode tcp_only
```

### 使用环境变量替代参数

```bash
sudo SS_PORT=12345 SS_PASSWORD='YOUR_STRONG_PASSWORD' bash <(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh)
```

如果你所在环境不支持 `bash <(...)`，改用下面这种更通用的写法：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo env SS_PORT=12345 SS_PASSWORD='YOUR_STRONG_PASSWORD' bash
```

### 固定指定版本（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --version v1.22.0 --port 12345 --password 'YOUR_STRONG_PASSWORD'
```

## 参数说明

查看帮助：

```bash
bash install.sh --help
```

常用参数：

- `--port` / `SS_PORT`
- `--password` / `SS_PASSWORD`
- `--method` / `SS_METHOD`（默认 `aes-128-gcm`）
- `--version` / `SS_VERSION`（`latest` 或 `v1.22.0` 这种 tag）
- `--mode`：传输模式（`tcp_and_udp` / `tcp_only` / `udp_only`）
- `SS_MODE`：通过环境变量设置传输模式
- `--no-udp`：禁用 UDP（等价于 `--mode tcp_only`）
- `--mode udp_only`：只启用 UDP

说明：
- `bash install.sh --help` 和 `bash uninstall.sh --help` 可直接查看帮助，不要求 root。
- 如果像 `--port` 这类参数漏了值，脚本现在会直接给出友好的报错，而不是抛出 shell 变量错误。

## 其它加密方法（含 SS2022）

本脚本安装的是 `shadowsocks-rust`（`ssserver`），它支持多种加密方法。你可以通过 `--method` 切换。

SS2022 常用示例（请确保你的客户端也支持对应 method）：

新安装或显式切换 method 且未传入 `--password` 时，安装器按所选方法生成新密钥；不改变 method 的升级保留原密码。SS2022 密钥会在启动服务前校验。

- `2022-blake3-aes-128-gcm`（建议密码用 16 字节 key 的 base64）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --port 12345 --method 2022-blake3-aes-128-gcm --password "$(openssl rand -base64 16)"
```

- `2022-blake3-aes-256-gcm`（建议密码用 32 字节 key 的 base64）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --port 12345 --method 2022-blake3-aes-256-gcm --password "$(openssl rand -base64 32)"
```

## 安装后要做什么

### 1) 放行防火墙 / 安全组

你必须在 VPS / 云厂商安全组里放行你选择的端口。

`ufw` 示例：

```bash
sudo ufw allow 12345/tcp
sudo ufw allow 12345/udp
```

### 2) 查看服务状态

```bash
systemctl status shadowsocks-server.service --no-pager
journalctl -u shadowsocks-server.service -e --no-pager
```

## 升级 / 重跑

重复运行会先下载校验并暂存文件，备份现有二进制、配置、unit 和元数据，再逐文件原子替换并启动/重启服务。只有 systemd MainPID 保持稳定、属于该服务 cgroup，且所需 TCP/UDP 监听由 MainPID 或该服务精确 cgroup / 后代 cgroup 内的进程持有，并连续通过 4 次（间隔 0.5 秒）探测才视为成功。支持 systemd cgroup v1 / v2；无关进程、相似 PID 或 cgroup 名称不能代替服务就绪。

普通错误及 INT/TERM/HUP 会触发 EXIT 回滚：还原旧文件、配置目录权限、服务启用/运行状态；失败诊断及回滚异常写入 stderr；回滚不完整时保留备份目录并打印路径，供手动恢复。文件替换是逐文件原子的，不是跨文件原子事务；SIGKILL、断电、磁盘损坏不在自动回滚保证内，包管理器依赖安装也不回滚。

> 注意：当前仓库是**单节点 / 单实例**模型。重复执行安装脚本的语义是**升级或覆盖当前节点**，不是“新增第二个节点”。

智能升级行为：
- 保留已有合法 JSON 的全部其它字段（包括 server、plugin、自定义字段）；仅修改所选 port/password/method/mode，缺失项补默认值。非法 JSON 或不兼容的核心字段会报错，不会静默重置。
- 保留 plugin 字段不代表通用插件支持：不负责安装/配置插件，插件仍须兼容上游版本、unit hardening 和传输模式。允许服务 cgroup 内的插件子进程持有所需监听；无插件的普通安装保持原有行为。
- 这意味着你可以直接执行不带参数的安装命令来“只升级版本”，不会把 SS2022 配置重置成默认 `aes-128-gcm`。
- 如果你之前使用过自定义 `--config-dir` / `--bin-dir` / `--user`，后续升级时建议继续传相同参数，以确保脚本定位到原安装位置。

- 升级到最新版本：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash
```

- 升级/固定到指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh | sudo bash -s -- --version v1.22.0
```

## 安全说明（建议阅读）

- `curl | bash` 天生有风险：你是在以 root 身份执行远程代码。更稳妥的做法是先下载 `install.sh` 审计后再运行。
- 更安全/可复现的方式是用 `--version vX.Y.Z` 固定版本。
- 安装器使用上游的 Linux musl 静态构建，不依赖目标系统的 glibc 版本。
- 默认严格 SHA256 校验：对应 `.sha256` 缺失、下载失败、格式错误或摘要不匹配均终止。支持纯 64 位十六进制摘要及标准文件名条目；只有显式 `--skip-sha256` 才跳过。摘要与二进制同源，不能替代独立签名认证。
- API、资产及摘要请求均有连接/总时限和有限重试；API 不可用、元数据无效、空资产或缺少目标架构时回退至官方 Release 页面。
- 不更改 BBR、TFO 或任何 sysctl 参数；保留已有配置中的 fast_open 值。
- 路径先规范化并拒绝关键宽泛目录，固定服务名；元数据要求 root 拥有、0600、受支持 schema 且路径/用户关联匹配。
- 安装/卸载共享固定 `/run/shadowsocks-installer/operation.lock` 非阻塞 flock；在读取安装状态、安装依赖之前获取，持有至退出/回滚结束。并发操作立即报错，不自动等待。锁目录要求 root:0700、锁文件 root:0600，拒绝符号链接，不接受环境变量改锁路径；锁不传给服务/后台进程。`flock`（util-linux）须已存在；不要删除正在使用的锁文件。
- 端口仅接受十进制 1–65535，允许前导零，无整数溢出转换。服务使用账户实际主 GID（不假设存在同名组），配置及目录与 unit 使用同一 GID；保留用户创建/回滚所有权记录。
- 建议用防火墙做 allowlist（只允许你的固定 IP 连接）。

## 卸载

推荐直接使用本仓库的卸载脚本（停止服务并清理 unit/配置/二进制；仅删除元数据明确记录为本安装器创建的用户）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/uninstall.sh | sudo bash
```

如需手动卸载，可参考 `uninstall.sh`。

支持卸载参数（适合自定义安装路径）：

- `--bin-path <path>`
- `--config-dir <dir>`
- `--user <name>`
- `--service <name>`
- `--keep-user`
- `--yes`（无人值守确认）

说明：
- 默认从 `/dev/tty` 读取确认，支持 `curl | bash`；无终端必须显式 `--yes`，不会从脚本输入流读取确认。
- 升级保留 `createdUser` 所有权；旧版/无元数据时保守保留用户，避免删除预先存在的账户。用户参数若与元数据不一致则拒绝卸载。
- 如果存在 `install-meta.json`，卸载脚本会优先读取它来自动识别安装信息。
- 如果你显式传了上面的参数，必须与经过验证的 metadata 一致，否则拒绝卸载。无 metadata 的旧安装必须能验证 unit 的 ExecStart/User 与配置结构；只删除安装器已知文件，保留目录中的其他文件。

## 开发与验证

CI 固定 `ubuntu-24.04`，执行 Bash 语法、ShellCheck 及 `tests/test_*.sh`。这些回归测试使用隔离路径、mock service/user 命令，**不是真实 systemd 集成测试**；包含真正同时运行的安装/卸载进程锁测试、端口边界、不同主组、v1/v2 cgroup 和事务回滚。

另提供 `tests/integration_systemd_vm.sh`：仅供**全新、独占、可销毁 VM**，root + systemd PID 1，且必须显式确认。禁止在本机、生产服务器、共享 CI runner 或特权容器中运行；普通 CI 不执行。检查条件只能防误操作，不能证明 VM 没有重要数据，请人工确认隔离（不要挂载宿主系统目录）。先在该 VM 安装 `python3 jq iproute2 util-linux shellcheck curl openssl xz-utils`，再运行：

```bash
sudo env SS_DISPOSABLE_VM_ACK=I_ACCEPT_DISPOSABLE_VM_DESTRUCTION bash tests/integration_systemd_vm.sh
```

该 harness 会真实创建测试账户/组及固定服务，测试 differently-named 主组配置访问、子进程监听、hardening、失败升级回滚及卸载，退出时清理。使用本地 Python listener fixture，不下载上游，不验证 Shadowsocks 协议或任意插件。没有隔离 VM 时只提交 harness，不声称已实测真实 systemd。

## License

本仓库已包含 `LICENSE`（MIT）。
