#!/bin/bash
set -e

echo "==> 清理当前终端代理变量"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY || true

echo "==> 检查系统"
cat /etc/os-release || true
uname -a

echo "==> 更新软件源并安装基础网络工具"
apt update
apt install -y curl ca-certificates

echo "==> 根据公网 IP 自动设置时区"
TIMEZONE="$(curl -4 -fsS --max-time 8 https://ipapi.co/timezone 2>/dev/null || true)"

if [ -n "$TIMEZONE" ] && timedatectl list-timezones | grep -qx "$TIMEZONE"; then
  timedatectl set-timezone "$TIMEZONE"
  echo "已设置时区：$TIMEZONE"
else
  timedatectl set-timezone Asia/Shanghai || true
  echo "自动识别时区失败，已回退到：Asia/Shanghai"
fi

echo "==> 更新系统基础包"
apt upgrade -y

echo "==> 安装常用工具"
apt install -y \
  curl wget vim nano ca-certificates gnupg lsb-release \
  unzip zip tar gzip bzip2 xz-utils \
  htop btop iftop iotop nload \
  net-tools iproute2 dnsutils traceroute mtr-tiny whois \
  socat cron rsync sqlite3 jq \
  openssh-client openssh-server \
  ufw fail2ban \
  nginx certbot python3 python3-pip \
  lsof psmisc sudo screen tmux

echo "==> 启用 cron 和 ssh"
systemctl enable --now cron
systemctl enable --now ssh || systemctl enable --now sshd || true

echo "==> 开启 BBR"
cat > /etc/sysctl.d/99-bbr.conf <<SYSCTL
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL

sysctl --system

echo "==> 设置文件句柄限制"
cat > /etc/security/limits.d/99-server.conf <<LIMITS
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS

echo "==> 配置 journald 日志限制，避免日志撑爆磁盘"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-limit.conf <<JOURNALD
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
MaxRetentionSec=7day
JOURNALD

systemctl restart systemd-journald

echo "==> 安装 hostname/IP 显示脚本"
bash <(curl -fsSL https://raw.githubusercontent.com/linger020/server-scripts/main/host-ip.sh) || true

echo "==> 显示当前状态"
echo "公网 IPv4:"
curl -4 -fsS --max-time 8 https://ip.sb || true
echo
echo "当前时区:"
timedatectl | grep "Time zone" || true
echo
echo "BBR 状态:"
sysctl net.ipv4.tcp_congestion_control || true
echo
echo "监听端口:"
ss -tlnp || true
echo
echo "磁盘:"
df -h
echo
echo "内存:"
free -h

echo "==> 初始化完成。建议重新登录 SSH 或执行：exec bash"
