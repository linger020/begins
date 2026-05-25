#!/usr/bin/env bash
set -euo pipefail

# x-ui / 3x-ui / Xray performance and stability booster
# Target: Debian / Ubuntu servers running /etc/systemd/system/x-ui.service
# Run as root: bash begins/xui-performance-boost.sh

SCRIPT_NAME="xui-performance-boost"
SYSCTL_MANAGED_FILE="/etc/sysctl.d/99-xui-performance.conf"
SYSCTL_CONF="/etc/sysctl.conf"
SYSCTL_BEGIN="# BEGIN XUI PERFORMANCE BOOST"
SYSCTL_END="# END XUI PERFORMANCE BOOST"
XUI_OVERRIDE_DIR="/etc/systemd/system/x-ui.service.d"
XUI_OVERRIDE_FILE="${XUI_OVERRIDE_DIR}/override.conf"
SYSTEM_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEM_LIMITS_FILE="${SYSTEM_LIMITS_DIR}/99-xui-high-limits.conf"
SECURITY_LIMITS_FILE="/etc/security/limits.d/99-xui-high-performance.conf"
JOURNAL_LIMIT_DIR="/etc/systemd/journald.conf.d"
JOURNAL_LIMIT_FILE="${JOURNAL_LIMIT_DIR}/99-xui-limit.conf"
LOGROTATE_FILE="/etc/logrotate.d/x-ui-xray"
RPS_SCRIPT="/usr/local/sbin/xui-rps-ethtool-tune.sh"
RPS_SERVICE="/etc/systemd/system/xui-rps-ethtool-tune.service"
HEALTH_SCRIPT="/usr/local/sbin/xui-health-check.sh"
HEALTH_CRON="/etc/cron.d/xui-health-check"
SWAP_FILE="/swapfile"
SWAP_SIZE="2G"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

warn() {
  printf '[%s][WARN] %s\n' "${SCRIPT_NAME}" "$*" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_ethtool_if_possible() {
  if command_exists ethtool; then
    return 0
  fi

  if command_exists apt-get; then
    log "Installing ethtool..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y ethtool || true
  fi

  if ! command_exists ethtool; then
    warn "ethtool is not available. NIC ring/coalescing tuning will be skipped."
  fi
}

get_total_mem_mib() {
  awk '/MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo
}

select_gogc() {
  local mem_mib
  mem_mib="$(get_total_mem_mib)"
  if [ "${mem_mib}" -ge 4096 ]; then
    echo "400"
  elif [ "${mem_mib}" -ge 2048 ]; then
    echo "300"
  else
    echo "150"
  fi
}

select_gomemlimit_line() {
  local mem_mib limit_mib
  mem_mib="$(get_total_mem_mib)"
  if [ "${mem_mib}" -ge 4096 ]; then
    limit_mib=$((mem_mib * 75 / 100))
    echo "Environment=GOMEMLIMIT=${limit_mib}MiB"
  else
    echo ""
  fi
}

configure_systemd_xui() {
  local gogc gomemlimit_line
  gogc="$(select_gogc)"
  gomemlimit_line="$(select_gomemlimit_line)"

  if ! systemctl list-unit-files | awk '{print $1}' | grep -qx 'x-ui.service'; then
    warn "x-ui.service not found in systemd unit list. The override file will still be written."
  fi

  mkdir -p "${XUI_OVERRIDE_DIR}"
  cat > "${XUI_OVERRIDE_FILE}" <<EOF
[Unit]
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Restart=always
RestartSec=3s

# Raise process, thread, task and file descriptor ceilings.
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity

# Do not cap CPU or memory through systemd.
CPUQuota=
MemoryMax=infinity
MemoryHigh=infinity

# Prefer x-ui/Xray over ordinary services without using real-time scheduling.
CPUWeight=10000
IOWeight=10000
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-500

# Go runtime tuning. Higher GOGC reduces GC frequency and CPU jitter on larger machines.
Environment=GOGC=${gogc}
${gomemlimit_line}
EOF

  systemctl daemon-reload
  systemctl restart x-ui || warn "systemctl restart x-ui failed. Check: systemctl status x-ui --no-pager -l"
}

configure_global_limits() {
  mkdir -p "${SYSTEM_LIMITS_DIR}"
  cat > "${SYSTEM_LIMITS_FILE}" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF

  cat > "${SECURITY_LIMITS_FILE}" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
}

write_sysctl_file() {
  cat > "${SYSCTL_MANAGED_FILE}" <<'EOF'
# x-ui / Xray performance and stability tuning.
# This file is safe for common VPS kernels. Unsupported keys are ignored by the installer.
fs.file-max = 2097152
fs.nr_open = 2097152
kernel.pid_max = 4194304

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 500000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.rps_sock_flow_entries = 32768

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 65536 131072 262144

vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
}

install_sysctl_managed_block_to_sysctl_conf() {
  touch "${SYSCTL_CONF}"
  cp -a "${SYSCTL_CONF}" "${SYSCTL_CONF}.bak.$(date +%Y%m%d%H%M%S)"

  awk -v begin="${SYSCTL_BEGIN}" -v end="${SYSCTL_END}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    skip != 1 {print}
  ' "${SYSCTL_CONF}" > "${SYSCTL_CONF}.tmp"

  {
    cat "${SYSCTL_CONF}.tmp"
    echo ""
    echo "${SYSCTL_BEGIN}"
    cat "${SYSCTL_MANAGED_FILE}"
    echo "${SYSCTL_END}"
  } > "${SYSCTL_CONF}"

  rm -f "${SYSCTL_CONF}.tmp"
}

apply_sysctl_key() {
  local key value
  key="$1"
  value="$2"
  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    return 0
  fi
  warn "sysctl key unsupported or rejected: ${key}=${value}"
  return 0
}

apply_sysctl_runtime() {
  modprobe tcp_bbr 2>/dev/null || true

  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "${line}" ] && continue
    [ "${line#*=}" = "${line}" ] && continue
    local key value
    key="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//')"
    value="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')"
    apply_sysctl_key "${key}" "${value}"
  done < "${SYSCTL_MANAGED_FILE}"
}

configure_network_sysctl() {
  write_sysctl_file
  install_sysctl_managed_block_to_sysctl_conf
  apply_sysctl_runtime
}

cpu_rps_mask() {
  local cpus mask
  cpus="$(nproc 2>/dev/null || echo 1)"
  if [ "${cpus}" -le 1 ]; then
    echo "1"
  elif [ "${cpus}" -lt 31 ]; then
    printf '%x\n' "$(( (1 << cpus) - 1 ))"
  else
    echo "ffffffff"
  fi
}

create_rps_ethtool_tune_script() {
  cat > "${RPS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() { printf '[xui-rps-ethtool-tune] %s\n' "$*"; }
warn() { printf '[xui-rps-ethtool-tune][WARN] %s\n' "$*" >&2; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

default_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

cpu_rps_mask() {
  local cpus
  cpus="$(nproc 2>/dev/null || echo 1)"
  if [ "${cpus}" -le 1 ]; then
    echo "1"
  elif [ "${cpus}" -lt 31 ]; then
    printf '%x\n' "$(( (1 << cpus) - 1 ))"
  else
    echo "ffffffff"
  fi
}

set_rps_rfs() {
  local iface mask queue
  iface="$1"
  mask="$(cpu_rps_mask)"

  for queue in /sys/class/net/${iface}/queues/rx-*; do
    [ -d "${queue}" ] || continue
    [ -w "${queue}/rps_cpus" ] && echo "${mask}" > "${queue}/rps_cpus" || true
    [ -w "${queue}/rps_flow_cnt" ] && echo 4096 > "${queue}/rps_flow_cnt" || true
  done
}

set_ethtool() {
  local iface rx_max tx_max
  iface="$1"
  command_exists ethtool || return 0

  rx_max="$(ethtool -g "${iface}" 2>/dev/null | awk '/Pre-set maximums:/ {max=1; next} max && /RX:/ {print $2; exit}')"
  tx_max="$(ethtool -g "${iface}" 2>/dev/null | awk '/Pre-set maximums:/ {max=1; next} max && /TX:/ {print $2; exit}')"

  if [ -n "${rx_max:-}" ] && [ -n "${tx_max:-}" ]; then
    ethtool -G "${iface}" rx "${rx_max}" tx "${tx_max}" 2>/dev/null || true
  fi

  ethtool -C "${iface}" adaptive-rx on adaptive-tx on 2>/dev/null || true
  ethtool -K "${iface}" tso on gso on gro on 2>/dev/null || true
}

main() {
  local iface
  iface="$(default_iface)"
  if [ -z "${iface}" ] || [ ! -d "/sys/class/net/${iface}" ]; then
    warn "default interface not found"
    exit 0
  fi

  set_rps_rfs "${iface}"
  set_ethtool "${iface}"
  log "applied for interface ${iface}"
}

main "$@"
EOF
  chmod +x "${RPS_SCRIPT}"

  cat > "${RPS_SERVICE}" <<EOF
[Unit]
Description=x-ui RPS/RFS and NIC tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RPS_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now xui-rps-ethtool-tune.service || warn "failed to enable/start xui-rps-ethtool-tune.service"
}

configure_swap() {
  if swapon --show | awk '{print $1}' | grep -qx "${SWAP_FILE}"; then
    log "swap already active: ${SWAP_FILE}"
    return 0
  fi

  if [ -e "${SWAP_FILE}" ]; then
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}" >/dev/null 2>&1 || true
    swapon "${SWAP_FILE}" || warn "failed to enable existing ${SWAP_FILE}"
  else
    log "creating ${SWAP_SIZE} swapfile at ${SWAP_FILE}"
    if command_exists fallocate; then
      fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
    else
      dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=2048 status=progress
    fi
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    swapon "${SWAP_FILE}"
  fi

  grep -q "^${SWAP_FILE} " /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
}

configure_logs() {
  mkdir -p "${JOURNAL_LIMIT_DIR}"
  cat > "${JOURNAL_LIMIT_FILE}" <<'EOF'
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
MaxRetentionSec=7day
EOF
  systemctl restart systemd-journald || true

  cat > "${LOGROTATE_FILE}" <<'EOF'
/usr/local/x-ui/bin/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

configure_health_check() {
  cat > "${HEALTH_SCRIPT}" <<'EOF'
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
EOF
  chmod +x "${HEALTH_SCRIPT}"

  cat > "${HEALTH_CRON}" <<EOF
*/2 * * * * root ${HEALTH_SCRIPT} >/dev/null 2>&1
EOF
}

print_status() {
  log "systemd x-ui resource settings:"
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
    -p OOMScoreAdjust || true

  log "network settings:"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.somaxconn net.core.netdev_max_backlog 2>/dev/null || true

  log "memory and disk:"
  free -h || true
  df -h / || true

  log "x-ui status:"
  systemctl status x-ui --no-pager -l || true
}

main() {
  require_root
  install_ethtool_if_possible
  configure_systemd_xui
  configure_global_limits
  configure_network_sysctl
  create_rps_ethtool_tune_script
  configure_swap
  configure_logs
  configure_health_check
  systemctl restart x-ui || true
  print_status
  log "done"
}

main "$@"
