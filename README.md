# Begins

Begins 是一个面向 Debian VPS 的轻量服务器初始化与运维菜单工具。它把常用初始化、系统调优、证书工具、测速和状态检查集中到一个命令里，适合新服务器快速处理基础环境。

## 脚本列表

| 脚本 | 用途 |
|---|---|
| `install-begins.sh` | 安装 `begins` 命令到 `/usr/local/bin/begins`。 |
| `uninstall-begins.sh` | 卸载 `/usr/local/bin/begins`。 |
| `begins.sh` | Begins 主菜单脚本，输入 `begins` 后通过数字选择执行初始化、调优、测速、状态检查等操作。 |
| `host-ip.sh` | 将服务器 hostname 改成公网 IP 格式，并把终端提示符 `root@ip-*` 设置为红色。 |
| `init-server.sh` | Debian 新服务器初始化：更新系统、安装常用工具和 certbot、根据公网 IP 自动设置时区、开启 BBR、提高文件句柄和进程限制、写入 TCP/内核性能参数、限制 journald 日志大小、安装 hostname/IP 显示脚本。默认不安装 nginx、ufw、fail2ban，避免占用 443 或改变防火墙状态。 |
| `begins/xui-pgbouncer.sh` | 3X-UI PostgreSQL 前置/迁移工具：本机安装 PgBouncer，连接远程 PostgreSQL，并为 3X-UI 生成或迁移 `/etc/default/x-ui` 的本地 DSN。 |

## 安装 Begins

适用于 Debian 12 / Debian 系 VPS。建议在 `root` 用户下执行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/begins/main/install-begins.sh)
```

安装完成后输入：

```bash
begins
```

当前菜单包含：

- Debian 初始化 + 常用包 + certbot，不安装 nginx/ufw/fail2ban
- 修改 hostname 为公网 IP + 红色提示符
- 应用高并发/TCP/BBR 参数
- 根据公网 IP 设置时区
- 单独安装 certbot
- 安装 Speedtest
- 运行 Speedtest
- 安装 backtrace 回程测试
- 3X-UI PgBouncer 前置安装
- 3X-UI 现有远程 PostgreSQL 配置迁移到本机 PgBouncer
- 查看监听端口
- 查看系统状态
- 查看 begins 日志
- 更新 begins
- 卸载 begins

## 卸载 Begins

菜单内选择：

```text
13. 卸载 begins
```

或者直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/begins/main/uninstall-begins.sh)
```

## 一键初始化 Debian 服务器

不进入菜单，直接初始化也可以执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/begins/main/init-server.sh)
```

执行内容包括：

- 清理当前终端代理变量
- 根据公网 IP 自动识别并设置系统时区，识别失败时回退到 `America/Los_Angeles`
- 执行 `apt update` 和 `apt upgrade -y`
- 安装常用运维工具，例如 `curl`、`wget`、`aria2`、`vim`、`rsync`、`sqlite3`、`jq`、`yq`、`tmux`、`tcpdump`、`nmap`、`build-essential`、`certbot` 等
- 不默认安装 `nginx`、`ufw`、`fail2ban`，避免占用 `443` 或改变防火墙状态
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
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/begins/main/host-ip.sh)
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

## 3X-UI PgBouncer 工具

菜单中的 `3X-UI` 区块提供两个入口：

- `前置安装：PgBouncer + 本地 DB DSN`
  - 用在安装 3X-UI 面板之前。
  - 运行时输入真实远程 PostgreSQL DSN。
  - 脚本会安装 PgBouncer，写入 `/etc/pgbouncer/pgbouncer.ini` 和 `/etc/pgbouncer/userlist.txt`，测试 PgBouncer 到远程 DB 可连接，然后写入 `/etc/default/x-ui`。
  - 完成后可选择是否立即执行官方 3X-UI 安装脚本。

- `配置升级：迁移现有面板到 PgBouncer`
  - 用在已经安装 3X-UI 且 `/etc/default/x-ui` 当前直连远程 PostgreSQL 的服务器。
  - 脚本会先读取现有 `XUI_DB_DSN`，备份 `/etc/default/x-ui` 和 `/etc/pgbouncer`，安装并测试 PgBouncer，成功后再把 `XUI_DB_DSN` 改为本机 `127.0.0.1:6432` 并重启 `x-ui`。

脚本不会把真实 DSN、数据库密码或 Token 写入仓库；这些值只在服务器运行时输入或读取，并写入服务器本机受权限保护的运行配置。

脚本会修改系统 hostname，并写入 `/etc/hosts` 的 `127.0.1.1` 记录。`host-ip.sh` 使用 `ip-1-2-3-4` 格式，而不是直接使用 `1.2.3.4`，避免 Bash 提示符只显示第一个点前内容的问题。

脚本通过公网 IP 查询接口识别时区。如果接口不可用，会自动回退到 `America/Los_Angeles`。

脚本默认面向 Debian 系服务器。其他发行版不保证兼容。
