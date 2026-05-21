# server-scripts

轻量 Linux VPS 工具脚本，用于快速服务器配置和维护。

## 脚本列表

| 脚本 | 用途 |
|---|---|
| `install-begins.sh` | 安装 `begins` 命令到 `/usr/local/bin/begins`。 |
| `begins.sh` | 类似 3X-UI 的数字选择菜单，输入 `begins` 后可选择初始化、安装工具、调优、安装 certbot、安装 3x-ui、回程测试等操作。 |
| `host-ip.sh` | 将服务器 hostname 改成公网 IP 格式，并把终端提示符 `root@ip-*` 设置为红色。 |
| `init-server.sh` | Debian 新服务器初始化：更新系统、安装常用工具、根据公网 IP 自动设置时区、开启 BBR、提高文件句柄和进程限制、写入 TCP/内核性能参数、限制 journald 日志大小、安装 hostname/IP 显示脚本。默认不安装 nginx、ufw、fail2ban，避免占用 443 或影响 REALITY；默认安装 certbot 工具，但不会自动申请证书。 |

## 安装 begins 菜单

适用于 Debian 12 / Debian 系 VPS。建议在 `root` 用户下执行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/install-begins.sh)
```

安装完成后输入：

```bash
begins
```

菜单包含：

- Debian 初始化（REALITY 友好，不装 nginx）
- 修改 hostname 为公网 IP + 红色提示符
- 安装常用 apt 包（含 certbot，不含 nginx）
- 应用高并发/TCP/BBR 参数
- 根据公网 IP 设置时区
- 安装 certbot
- 安装 3x-ui
- 安装 backtrace 回程测试
- 查看监听端口
- 查看系统状态
- 查看 begins 日志
- 更新 begins

## 一键初始化 Debian 服务器

直接初始化也可以执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/init-server.sh)
```

执行内容包括：

- 清理当前终端代理变量
- 根据公网 IP 自动识别并设置系统时区，识别失败时回退到 `Asia/Shanghai`
- 执行 `apt update` 和 `apt upgrade -y`
- 安装常用运维工具，例如 `curl`、`wget`、`aria2`、`vim`、`rsync`、`sqlite3`、`jq`、`yq`、`tmux`、`tcpdump`、`nmap`、`build-essential`、`certbot` 等
- 不默认安装 `nginx`、`ufw`、`fail2ban`，避免占用 `443` 或改变防火墙状态，方便 REALITY 协议直接使用 443
- 启用 `cron`、`ssh`、`sysstat`、`vnstat`
- 开启 BBR，并写入较高并发 TCP 参数
- 将文件句柄和进程限制提高到 `1048576`
- 设置 systemd 默认 `NOFILE / NPROC` 限制
- 限制 systemd journald 日志占用空间
- 调用 `host-ip.sh` 设置 hostname 和红色终端提示符
- 控制台只输出简要状态，详细安装日志写入 `/var/log/init-server.log`

执行完成后建议重新登录 SSH，或者执行：

```bash
exec bash
```

部分 systemd 限制需要重新登录或重启后完全生效。需要完全应用时执行：

```bash
reboot
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

## 性能参数说明

`init-server.sh` 会写入 `/etc/sysctl.d/99-server-performance.conf`，主要包含：

- BBR：`net.ipv4.tcp_congestion_control=bbr`
- 队列：`net.core.default_qdisc=fq`
- 连接队列：`net.core.somaxconn=65535`
- SYN 队列：`net.ipv4.tcp_max_syn_backlog=65535`
- 本地端口范围：`net.ipv4.ip_local_port_range=1024 65535`
- TCP buffer：提高 `rmem / wmem` 上限
- TIME_WAIT：启用 `tcp_tw_reuse`，缩短 `tcp_fin_timeout`
- 文件句柄：`fs.file-max=2097152`、`fs.nr_open=2097152`

这些参数偏高并发 VPS 使用，不是保守默认配置。

## 注意事项

默认初始化不会安装 Web 服务器。需要 Nginx、防火墙或 Fail2ban 时，请后续手动安装。

默认会安装 `certbot` 工具，但不会自动申请证书，也不会占用 443。申请证书时请根据实际情况选择 standalone、webroot 或 DNS 方式。

脚本会修改系统 hostname，并写入 `/etc/hosts` 的 `127.0.1.1` 记录。`host-ip.sh` 使用 `ip-1-2-3-4` 格式，而不是直接使用 `1.2.3.4`，避免 Bash 提示符只显示第一个点前内容的问题。

脚本通过公网 IP 查询接口识别时区。如果接口不可用，会自动回退到 `Asia/Shanghai`。

脚本默认面向 Debian 系服务器。其他发行版不保证兼容。
