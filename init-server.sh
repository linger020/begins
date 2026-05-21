#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/init-server.log"
: > "$LOG_FILE"

step() {
  echo "==> $1"
}

run() {
  DESC="$1"
  shift
  step "$DESC"
  "$@" >> "$LOG_FILE" 2>&1
}

step "清理当前终端代理变量"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY || true

step "检查系统，详细日志写入 $LOG_FILE"
{
  cat /etc/os-release || true
  uname -a
} >> "$LOG_FILE" 2>&1

run "更新软件源并安装基础网络工具" apt update
run "安装基础网络工具" apt install -y curl ca-certificates

step "根据公网 IP 自动设置时区"
TIMEZONE="$(curl -4 -fsS --max-time 8 https://ipapi.co/timezone 2>>"$LOG_FILE" || true)"

if [ -n "$TIMEZONE" ] && timedatectl list-timezones | grep -qx "$TIMEZONE"; then
  timedatectl set-timezone "$TIMEZONE" >> "$LOG_FILE" 2>&1
  echo "已设置时区：$TIMEZONE"
else
  timedatectl set-timezone Asia/Shanghai >> "$LOG_FILE" 2>&1 || true
  echo "自动识别时区失败，已回退到：Asia/Shanghai"
fi

run "更新系统基础包" apt upgrade -y

step "安装常用工具和运维组件，不安装 nginx/certbot/ufw/fail2ban 等会占用端口或改变防火墙的服务"
apt install -y \
  curl wget aria2 axel vim nano ca-certificates gnupg lsb-release apt-transport-https \
  unzip zip tar gzip bzip2 xz-utils zstd p7zip-full \
  htop btop iftop iotop nload vnstat sysstat dstat \
  net-tools iproute2 iputils-ping dnsutils traceroute mtr-tiny whois tcpdump nmap netcat-openbsd telnet \
  socat cron rsync sqlite3 jq yq \
  openssh-client openssh-server \
  logrotate \
  python3 python3-pip python3-venv \
  build-essential cmake pkg-config autoconf automake libtool \
  openssl lsof psmisc sudo screen tmux tree file locales acl >> "$LOG_FILE" 2>&1

step "启用 cron、ssh 和常用统计服务"
{
  systemctl enable --now cron
  systemctl enable --now ssh || systemctl enable --now sshd || true
  systemctl enable --now sysstat || true
  systemctl enable --now vnstat || true
} >> "$LOG_FILE" 2>&1

step "写入高并发文件句柄和进程限制"
cat > /etc/security/limits.d/99-server-high-limit.conf <<LIMITS
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
LIMITS

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/99-high-limit.conf <<SYSTEMD_LIMITS
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD_LIMITS

cat > /etc/systemd/user.conf.d/99-high-limit.conf <<SYSTEMD_USER_LIMITS
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD_USER_LIMITS

ulimit -n 1048576 >> "$LOG_FILE" 2>&1 || true

step "写入 TCP/内核性能参数"
cat > /etc/sysctl.d/99-server-performance.conf <<SYSCTL
fs.file-max = 2097152
fs.nr_open = 2097152

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_tw_buckets = 2000000

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL

sysctl --system >> "$LOG_FILE" 2>&1 || true

step "配置 journald 日志限制，避免日志撑爆磁盘"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-limit.conf <<JOURNALD
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
MaxRetentionSec=7day
JOURNALD

{
  systemctl daemon-reexec || true
  systemctl restart systemd-journald
} >> "$LOG_FILE" 2>&1

step "安装 hostname/IP 显示脚本"
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/host-ip.sh) >> "$LOG_FILE" 2>&1 || true

step "输出简要状态"
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ip.sb 2>>"$LOG_FILE" || true)"
CURRENT_TZ="$(timedatectl 2>>"$LOG_FILE" | grep "Time zone" | sed 's/^[[:space:]]*//')"
BBR_STATUS="$(sysctl -n net.ipv4.tcp_congestion_control 2>>"$LOG_FILE" || true)"
NOFILE_LIMIT="$(ulimit -n 2>>"$LOG_FILE" || true)"

echo "公网 IPv4：${PUBLIC_IP:-unknown}"
echo "${CURRENT_TZ:-当前时区：unknown}"
echo "TCP 拥塞控制：${BBR_STATUS:-unknown}"
echo "当前 shell 文件句柄：${NOFILE_LIMIT:-unknown}"
echo "详细日志：$LOG_FILE"
echo "==> 初始化完成。默认未安装 nginx/certbot/ufw/fail2ban，避免占用 443 或影响 REALITY。"
echo "==> 部分 systemd 限制需要重新登录 SSH 或重启后完全生效。建议执行：exec bash，或直接 reboot"
