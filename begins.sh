#!/bin/bash
set -e

BASE_URL="https://raw.githubusercontent.com/linger020/server-scripts/main"
LOG_FILE="/var/log/begins.log"

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
  fi
}

pause() {
  echo
  read -r -p "按 Enter 返回菜单..." _
}

run_cmd() {
  echo "==> $1"
  shift
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

show_status() {
  echo "公网 IPv4: $(curl -4 -fsS --max-time 5 https://ip.sb 2>/dev/null || echo unknown)"
  echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
  timedatectl 2>/dev/null | grep "Time zone" || true
  echo "TCP 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "当前文件句柄: $(ulimit -n 2>/dev/null || echo unknown)"
  echo
  df -h
  echo
  free -h
}

apply_tuning() {
  echo "==> 写入高并发限制和 TCP 参数"
  cat > /etc/security/limits.d/99-server-high-limit.conf <<'LIMITS'
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
  cat > /etc/systemd/system.conf.d/99-high-limit.conf <<'SYSTEMD_LIMITS'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD_LIMITS

  cat > /etc/systemd/user.conf.d/99-high-limit.conf <<'SYSTEMD_USER_LIMITS'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD_USER_LIMITS

  cat > /etc/sysctl.d/99-server-performance.conf <<'SYSCTL'
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

  sysctl --system | tee -a "$LOG_FILE"
  systemctl daemon-reexec || true
  echo "已写入。建议重启或重新登录 SSH 让 systemd 限制完全生效。"
}

set_timezone_by_ip() {
  apt update >/dev/null 2>&1 || true
  apt install -y curl ca-certificates >/dev/null 2>&1 || true
  TZ_NAME="$(curl -4 -fsS --max-time 8 https://ipapi.co/timezone 2>/dev/null || true)"
  if [ -n "$TZ_NAME" ] && timedatectl list-timezones | grep -qx "$TZ_NAME"; then
    timedatectl set-timezone "$TZ_NAME"
    echo "已设置时区：$TZ_NAME"
  else
    timedatectl set-timezone America/Los_Angeles || true
    echo "识别失败，已回退到 America/Los_Angeles"
  fi
}

install_speedtest() {
  apt update
  apt install -y curl ca-certificates
  curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
  apt install -y speedtest
}

run_speedtest() {
  if ! command -v speedtest >/dev/null 2>&1; then
    echo "未检测到 speedtest，先安装。"
    install_speedtest
  fi
  speedtest
}

run_backtrace() {
  if ! command -v backtrace >/dev/null 2>&1; then
    echo "未检测到 backtrace，先安装。"
    curl -fsSL https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh | bash
  fi
  backtrace
}

run_xuicert() {
  bash <(curl -fsSL "$BASE_URL/certbot-xuicert.sh")
}

run_xui_system_full_tune() {
  bash <(curl -fsSL "$BASE_URL/begins/xui-system-full-tune.sh")
}

uninstall_begins() {
  rm -f /usr/local/bin/begins
  echo "begins 已卸载。"
  exit 0
}

show_menu() {
  clear
  echo "╔────────────────────────────────────────────────╗"
  echo "│   Begins Server Management Script              │"
  echo "│   0. Exit Script                               │"
  echo "│────────────────────────────────────────────────│"
  echo "│   1. Debian 初始化 + 常用包 + certbot          │"
  echo "│      REALITY 友好，不装 nginx/ufw/fail2ban     │"
  echo "│   2. 修改 hostname 为公网 IP + 红色提示符      │"
  echo "│   3. 应用高并发/TCP/BBR 参数                  │"
  echo "│   4. 根据公网 IP 设置时区                      │"
  echo "│────────────────────────────────────────────────│"
  echo "│   5. 单独安装 certbot                          │"
  echo "│   6. 申请证书并软链接到 /root/xuicert          │"
  echo "│   7. 安装 Speedtest                            │"
  echo "│   8. 运行 Speedtest                            │"
  echo "│   9. 测试网络回程                              │"
  echo "│────────────────────────────────────────────────│"
  echo "│  10. 查看监听端口                              │"
  echo "│  11. 查看系统状态                              │"
  echo "│  12. 查看 begins 日志                          │"
  echo "│  13. 更新 begins                               │"
  echo "│  14. 卸载 begins                               │"
  echo "│────────────────────────────────────────────────│"
  echo "│  15. 3X-UI/Xray 系统层暴力优化                 │"
  echo "│      只改系统，不改 Xray/入站/iptables         │"
  echo "╚────────────────────────────────────────────────╝"
  echo
  echo "Reality mode: nginx not installed by default, 443 reserved"
  echo
}

need_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

while true; do
  show_menu
  read -r -p "Please enter your selection [0-15]: " choice
  case "$choice" in
    0) exit 0 ;;
    1) bash <(curl -fsSL "$BASE_URL/init-server.sh"); pause ;;
    2) bash <(curl -fsSL "$BASE_URL/host-ip.sh"); pause ;;
    3) apply_tuning; pause ;;
    4) set_timezone_by_ip; pause ;;
    5) apt update && apt install -y certbot; pause ;;
    6) run_xuicert; pause ;;
    7) install_speedtest; pause ;;
    8) run_speedtest; pause ;;
    9) run_backtrace; pause ;;
    10) ss -tlnp; pause ;;
    11) show_status; pause ;;
    12) tail -n 120 "$LOG_FILE" 2>/dev/null || true; pause ;;
    13) curl -fsSL -o /usr/local/bin/begins "$BASE_URL/begins.sh" && chmod +x /usr/local/bin/begins && echo "begins 已更新"; pause ;;
    14) uninstall_begins ;;
    15) run_xui_system_full_tune; pause ;;
    *) echo "[ERR] Please enter the correct number [0-15]"; sleep 1 ;;
  esac
done