# Shadowsocks-X

一个交互式的 Shadowsocks 管理工具，适合在服务器上用菜单方式完成 `ssserver` 安装、节点创建、状态查看和卸载。

## 功能特性

- 交互式主菜单管理
- 一键安装 / 升级 `shadowsocks-rust` 的 `ssserver`
- 多节点管理：新增、删除、查看详情、启停、重启
- 每个节点独立配置目录：`/etc/shadowsocks/node-<name>/config.json`
- 自动生成 SS 链接
- systemd 服务管理：`ss-node-<name>.service`
- 支持常见 AEAD 与 SS2022 加密方式

## 安装方式

一键安装：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Shadowsocks/main/install.sh)"
```

## 安装后运行

安装完成后，直接执行：

```bash
ss
```

## 默认安装位置

- 项目目录：`/opt/Shadowsocks`
- 菜单命令：`/usr/local/bin/ss`
- 服务端二进制：`/usr/local/bin/ssserver`
- 节点配置目录：`/etc/shadowsocks`

## 菜单结构

主菜单：

- 安装 / 升级 ssserver
- 节点管理
- 查看服务状态
- 卸载

节点管理支持：

- 查看所有节点
- 新增节点
- 删除节点
- 查看节点详情 / SS 链接
- 启动 / 停止 / 重启节点

## 说明

- 新增节点时可选择自动随机端口或手动指定端口
- SS2022 方法会校验密码格式和长度
- 所有节点均由 systemd 托管，便于开机自启和故障自动拉起
