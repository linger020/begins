#!/usr/bin/env bash
set -euo pipefail

# begins universal system-level full tuning script.
# Scope:
# - systemd global default limits
# - PAM/security limits
# - sysctl TCP/network/VM tuning
# - best-effort NIC queue tuning
# - journald size limits
# It does NOT modify application configs, x-ui/xray/nginx/docker units, iptables/nftables,
# health checks, watchdogs, cron restart loops, or application lifecycle.

log() { echo "[begins-system-full-tune] $*"; }
warn() { echo "[begins-system-full-tune][WARN] $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 执行" >&2
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [ -e "$file" ]; then
    cp -a "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

apply_sysctl_file() {
  local file="$1"

  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    echo "$line" | grep -q '=' || continue

    key="$(echo "${line%%=*}" | sed 's/[[:space:]]*$//')"
    value="$(echo "${line#*=}" | sed 's/^[[:space:]]*//')"

    sysctl -w "$key=$value" >/dev/null 2>&1 || warn "unsupported or rejected sysctl: $key=$value"
  done < "$file"
}

remove_sysctl_conf_block() {
  local begin="$1"
  local end="$2"
  local file="/etc/sysctl.conf"
  [ -f "$file" ] || return 0

  if grep -qxF "$begin" "$file" 2>/dev/null; then
    backup_file "$file"
    awk -v begin="$begin" -v end="$end" '
      $0 == begin {skip=1; next}
      $0 == end {skip=0; next}
      skip != 1 {print}
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    log "已清理 /etc/sysctl.conf 托管块：$begin"
  fi
}

cleanup_legacy_sysctl_conf_blocks() {
  log "清理旧脚本写入 /etc/sysctl.conf 的强制托管块"
  remove_sysctl_conf_block "# BEGIN XUI SYSTEM FULL TUNE" "# END XUI SYSTEM FULL TUNE"
  remove_sysctl_conf_block "# BEGIN XUI PERFORMANCE BOOST" "# END XUI PERFORMANCE BOOST"
  remove_sysctl_conf_block "# BEGIN XUI EXTREME NETWORK" "# END XUI EXTREME NETWORK"
  remove_sysctl_conf_block "# BEGIN XUI SYSTEM NETWORK" "# END XUI SYSTEM NETWORK"
}

write_limits() {
  log "写入通用高并发 Limit"

  mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/systemd/user.conf.d

  cat > /etc/security/limits.d/99-begins-universal-limits.conf <<'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
EOF_LIMITS

  cat > /etc/systemd/system.conf.d/99-begins-universal-limits.conf <<'EOF_SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF_SYSTEMD

  cat > /etc/systemd/user.conf.d/99-begins-universal-limits.conf <<'EOF_SYSTEMD_USER'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF_SYSTEMD_USER
}

write_sysctl() {
  log "写入通用 TCP / IO / VM 参数"

  backup_file /etc/sysctl.d/99-begins-universal-tune.conf

  cat > /etc/sysctl.d/99-begins-universal-tune.conf <<'EOF_SYSCTL'
# begins universal system tuning

# File descriptors and process ids.
fs.file-max = 2097152
fs.nr_open = 2097152
kernel.pid_max = 4194304

# Queue and backlog.
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_max_syn_backlog = 65535

# Port range.
net.ipv4.ip_local_port_range = 1024 65535

# Socket buffers.
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# TCP behavior.
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
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 1

# VM behavior.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
EOF_SYSCTL

  apply_sysctl_file /etc/sysctl.d/99-begins-universal-tune.conf
}

write_netdev_tune() {
  log "写入通用网卡队列优化服务（oneshot，不管理应用进程）"

  cat > /usr/local/sbin/begins-netdev-tune.sh <<'EOF_NETDEV'
#!/usr/bin/env bash
set -euo pipefail

IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$IFACE" ] || exit 0
[ -d "/sys/class/net/$IFACE" ] || exit 0

CPU_COUNT="$(nproc 2>/dev/null || echo 1)"

if [ "$CPU_COUNT" -le 1 ]; then
  RPS_MASK="1"
elif [ "$CPU_COUNT" -lt 31 ]; then
  RPS_MASK="$(printf '%x\n' "$(( (1 << CPU_COUNT) - 1 ))")"
else
  RPS_MASK="ffffffff"
fi

for q in /sys/class/net/"$IFACE"/queues/rx-*; do
  [ -d "$q" ] || continue
  [ -w "$q/rps_cpus" ] && echo "$RPS_MASK" > "$q/rps_cpus" || true
  [ -w "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt" || true
done

if command -v ethtool >/dev/null 2>&1; then
  RX_MAX="$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/ {max=1; next} max && /RX:/ {print $2; exit}')"
  TX_MAX="$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/ {max=1; next} max && /TX:/ {print $2; exit}')"

  if [ -n "${RX_MAX:-}" ] && [ -n "${TX_MAX:-}" ]; then
    ethtool -G "$IFACE" rx "$RX_MAX" tx "$TX_MAX" 2>/dev/null || true
  else
    ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
  fi

  ethtool -C "$IFACE" adaptive-rx on adaptive-tx on 2>/dev/null || true
  ethtool -K "$IFACE" tso on gso on gro on 2>/dev/null || true
fi
EOF_NETDEV
  chmod +x /usr/local/sbin/begins-netdev-tune.sh

  cat > /etc/systemd/system/begins-netdev-tune.service <<'EOF_SERVICE'
[Unit]
Description=begins universal RPS/RFS and ethtool tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/begins-netdev-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

write_journald_limit() {
  log "写入 journald 日志上限"

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-begins-limit.conf <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
MaxRetentionSec=7day
EOF_JOURNAL
}

cleanup_old_xui_tune_artifacts() {
  log "清理旧 x-ui 专用优化残留（不影响应用配置）"

  rm -f /etc/cron.d/xui-health-check
  rm -f /usr/local/sbin/xui-health-check.sh
  rm -f /etc/systemd/system/xui-system-netdev-tune.service
  rm -f /usr/local/sbin/xui-system-netdev-tune.sh
  rm -f /etc/logrotate.d/x-ui-xray
  rm -f /etc/systemd/journald.conf.d/99-xui-limit.conf
  rm -f /etc/sysctl.d/99-xui-system-full.conf
  rm -f /etc/systemd/system.conf.d/99-xui-high-limits.conf
  rm -f /etc/security/limits.d/99-xui-high-performance.conf
}

main() {
  require_root

  log "开始通用系统暴力优化"
  log "说明：只改系统层参数；不改应用配置；不做 health check；不重启 x-ui/xray/nginx/docker；不改防火墙。"

  apt-get update -y || true
  apt-get install -y ethtool || true

  cleanup_old_xui_tune_artifacts
  cleanup_legacy_sysctl_conf_blocks
  write_limits
  write_sysctl
  write_netdev_tune
  write_journald_limit

  systemctl daemon-reexec || true
  systemctl daemon-reload || true
  systemctl enable --now begins-netdev-tune.service || true
  systemctl try-restart systemd-journald.service || true

  echo
  echo "===== begins 通用系统暴力优化完成 ====="
  echo "已修改：Limit / sysctl TCP-IO-VM / RPS-RFS / ethtool / journald"
  echo "未修改：应用配置、服务 Unit、iptables/nftables、health check、自动重启逻辑"
  echo "建议：重启服务器或重新登录 SSH 后，systemd 全局 Limit 完全生效。"
  echo
  echo "当前关键状态："
  echo "nofile: $(ulimit -n 2>/dev/null || echo unknown)"
}

main "$@"
