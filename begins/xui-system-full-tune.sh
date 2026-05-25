#!/usr/bin/env bash
set -euo pipefail

# x-ui / 3x-ui / Xray system-only full tuning script.
# This script only changes system-level settings:
# - systemd resource limits
# - system global limits
# - sysctl network stack
# - RPS/RFS and ethtool best-effort tuning
# - journald/logrotate limits
# - x-ui/xray health check
# - swap fallback
# It does NOT modify Xray JSON, 3x-ui inbounds, iptables, nftables, or multi-instance routing.

log() { echo "[xui-system-full-tune] $*"; }
warn() { echo "[xui-system-full-tune][WARN] $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

apply_sysctl_file() {
  local file="$1"
  modprobe tcp_bbr 2>/dev/null || true

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

write_sysctl_conf_tail_block() {
  local managed_file="$1"
  local begin="# BEGIN XUI SYSTEM FULL TUNE"
  local end="# END XUI SYSTEM FULL TUNE"

  touch /etc/sysctl.conf
  cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"

  awk -v begin="$begin" -v end="$end" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    skip != 1 {print}
  ' /etc/sysctl.conf > /etc/sysctl.conf.tmp

  {
    cat /etc/sysctl.conf.tmp
    echo
    echo "$begin"
    cat "$managed_file"
    echo "$end"
  } > /etc/sysctl.conf

  rm -f /etc/sysctl.conf.tmp
}

require_root

log "[1/9] Installing base tools..."
apt-get update -y || true
apt-get install -y ethtool || true

log "[2/9] Writing x-ui systemd performance override..."
MEM_MIB="$(awk '/MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)"

if [ "$MEM_MIB" -ge 4096 ]; then
  GOGC_VALUE=400
  GOMEMLIMIT_LINE="Environment=GOMEMLIMIT=$((MEM_MIB * 75 / 100))MiB"
elif [ "$MEM_MIB" -ge 2048 ]; then
  GOGC_VALUE=300
  GOMEMLIMIT_LINE=""
else
  GOGC_VALUE=150
  GOMEMLIMIT_LINE=""
fi

mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf <<EOF_OVERRIDE
[Unit]
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Restart=always
RestartSec=3s

LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity

CPUQuota=
MemoryMax=infinity
MemoryHigh=infinity

CPUWeight=10000
IOWeight=10000
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-500

Environment=GOGC=$GOGC_VALUE
$GOMEMLIMIT_LINE
EOF_OVERRIDE

log "[3/9] Writing system-wide limits..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-xui-high-limits.conf <<'EOF_LIMITS'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF_LIMITS

cat > /etc/security/limits.d/99-xui-high-performance.conf <<'EOF_SECURITY_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
EOF_SECURITY_LIMITS

log "[4/9] Removing old fragmented x-ui sysctl files to avoid conflicts..."
rm -f \
  /etc/sysctl.d/99-xui-tw-kill.conf \
  /etc/sysctl.d/99-xui-mem-lock.conf \
  /etc/sysctl.d/99-xui-tfo.conf \
  /etc/sysctl.d/99-xui-network-performance.conf \
  /etc/sysctl.d/99-xui-system-network.conf \
  /etc/sysctl.d/99-xui-extreme-network.conf \
  /etc/sysctl.d/99-xui-performance.conf

log "[5/9] Writing unified sysctl network tuning..."
cat > /etc/sysctl.d/99-xui-system-full.conf <<'EOF_SYSCTL'
# ===== x-ui / Xray system full tuning =====

# File descriptors.
fs.file-max = 2097152
fs.nr_open = 2097152
kernel.pid_max = 4194304

# BBR / fq.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Network queues.
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 500000
net.core.rps_sock_flow_entries = 32768

# TCP / UDP buffers.
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536

# Port range.
net.ipv4.ip_local_port_range = 1024 65535

# SYN backlog.
net.ipv4.tcp_max_syn_backlog = 65535

# TIME_WAIT / FIN recycling.
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# TCP keepalive. Remove dead connections earlier.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# TCP window and MTU probing.
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1

# TCP Fast Open.
net.ipv4.tcp_fastopen = 3

# Orphan socket control.
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 1

# High concurrency tuning.
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# TCP buffers.
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728

# TCP / UDP memory pressure lines. Suitable for around 2 GiB VPS memory.
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144

# UDP minimum buffers.
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# VM.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF_SYSCTL

write_sysctl_conf_tail_block /etc/sysctl.d/99-xui-system-full.conf
apply_sysctl_file /etc/sysctl.d/99-xui-system-full.conf

log "[6/9] Writing RPS/RFS + ethtool netdev tune service..."
cat > /usr/local/sbin/xui-system-netdev-tune.sh <<'EOF_NETDEV'
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
chmod +x /usr/local/sbin/xui-system-netdev-tune.sh

cat > /etc/systemd/system/xui-system-netdev-tune.service <<'EOF_NETDEV_SERVICE'
[Unit]
Description=x-ui system-level RPS/RFS and ethtool tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xui-system-netdev-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_NETDEV_SERVICE

log "[7/9] Writing journald and x-ui/Xray log rotation limits..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-xui-limit.conf <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
MaxRetentionSec=7day
EOF_JOURNAL

cat > /etc/logrotate.d/x-ui-xray <<'EOF_LOGROTATE'
/usr/local/x-ui/bin/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF_LOGROTATE

log "[8/9] Writing x-ui/xray health check..."
cat > /usr/local/sbin/xui-health-check.sh <<'EOF_HEALTH'
#!/usr/bin/env bash
set -euo pipefail

if ! systemctl is-active --quiet x-ui; then
  systemctl restart x-ui
  exit 0
fi

if ! pgrep -f 'xray' >/dev/null 2>&1; then
  systemctl restart x-ui
  exit 0
fi
EOF_HEALTH
chmod +x /usr/local/sbin/xui-health-check.sh

cat > /etc/cron.d/xui-health-check <<'EOF_HEALTH_CRON'
*/2 * * * * root /usr/local/sbin/xui-health-check.sh >/dev/null 2>&1
EOF_HEALTH_CRON

log "[9/9] Applying swap fallback and restarting services..."
if ! swapon --show | grep -q '/swapfile'; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon /swapfile || true
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now xui-system-netdev-tune.service || true
systemctl restart systemd-journald || true
systemctl restart x-ui || true

echo
echo "===== x-ui systemd ====="
systemctl show x-ui \
  -p Restart \
  -p RestartSec \
  -p LimitNOFILE \
  -p LimitNPROC \
  -p TasksMax \
  -p CPUQuotaPerSecUSec \
  -p CPUWeight \
  -p IOWeight \
  -p MemoryMax \
  -p MemoryHigh \
  -p Nice \
  -p OOMScoreAdjust \
  -p Environment || true

echo
echo "===== sysctl ====="
sysctl \
  net.core.netdev_max_backlog \
  net.ipv4.tcp_window_scaling \
  net.ipv4.tcp_tw_reuse \
  net.ipv4.tcp_fin_timeout \
  net.ipv4.tcp_keepalive_time \
  net.ipv4.tcp_keepalive_intvl \
  net.ipv4.tcp_keepalive_probes \
  net.ipv4.tcp_max_orphans \
  net.ipv4.tcp_orphan_retries \
  net.core.rmem_max \
  net.core.wmem_max \
  net.ipv4.tcp_mem \
  net.ipv4.udp_mem \
  net.ipv4.tcp_fastopen \
  net.ipv4.tcp_congestion_control \
  net.core.default_qdisc 2>/dev/null || true

echo
echo "===== RPS/RFS ====="
IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
echo "iface=$IFACE"
if [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ]; then
  for f in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do [ -f "$f" ] && echo "$f=$(cat "$f")"; done
  for f in /sys/class/net/$IFACE/queues/rx-*/rps_flow_cnt; do [ -f "$f" ] && echo "$f=$(cat "$f")"; done
fi

echo
echo "===== ethtool ====="
if command -v ethtool >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
  ethtool -g "$IFACE" 2>/dev/null || echo "current VPS NIC does not support ring buffer display"
  ethtool -c "$IFACE" 2>/dev/null || echo "current VPS NIC does not support coalescing display"
fi

echo
echo "===== x-ui status ====="
systemctl status x-ui --no-pager -l || true

echo
echo "===== memory / disk ====="
free -h || true
df -h / || true

echo
echo "Done. Integrated TIME-WAIT, FIN_TIMEOUT, keepalive, tcp_mem, udp_mem, TFO, RPS/RFS, ethtool, and systemd resource tuning."
echo "No Xray JSON changes. No 3x-ui inbound changes. No iptables/nftables routing changes."
