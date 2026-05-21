# server-scripts

轻量 Linux VPS 工具脚本，用于快速服务器配置和维护。

## 脚本列表

| 脚本 | 用途 |
|---|---|
| `host-ip.sh` | 将服务器 hostname 改成公网 IP 格式，并把终端提示符 `root@ip-*` 设置为红色。 |
| `init-server.sh` | Debian 新服务器初始化：更新系统、安装常用工具、设置时区、开启 BBR、限制 journald 日志大小、安装 hostname/IP 显示脚本。 |

## 一键初始化 Debian 服务器

适用于 Debian 12 / Debian 系 VPS。建议在 `root` 用户下执行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/init-server.sh)
```

执行内容包括：

- 清理当前终端代理变量
- 设置时区为 `Asia/Shanghai`
- 执行 `apt update` 和 `apt upgrade -y`
- 安装常用运维工具，例如 `curl`、`wget`、`vim`、`rsync`、`sqlite3`、`jq`、`nginx`、`certbot`、`tmux` 等
- 启用 `cron` 和 `ssh`
- 开启 BBR
- 设置文件句柄限制
- 限制 systemd journald 日志占用空间
- 调用 `host-ip.sh` 设置 hostname 和红色终端提示符
- 输出公网 IP、BBR 状态、监听端口、磁盘和内存状态

执行完成后建议重新登录 SSH，或者执行：

```bash
exec bash
```

## 单独修改 hostname 为公网 IP

只想把服务器提示符从类似：

```text
root@racknerd-xxxx:~#
```

改成类似：

```text
root@ip-154-21-94-9:~#
```

执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/host-ip.sh)
exec bash
```

## 注意事项

`init-server.sh` 会安装 `nginx`、`certbot`、`fail2ban`、`ufw` 等常用组件，但不会自动启用防火墙，避免误锁 SSH。

脚本会修改系统 hostname，并写入 `/etc/hosts` 的 `127.0.1.1` 记录。`host-ip.sh` 使用 `ip-1-2-3-4` 格式，而不是直接使用 `1.2.3.4`，避免 Bash 提示符只显示第一个点前内容的问题。

脚本默认面向 Debian 系服务器。其他发行版不保证兼容。
