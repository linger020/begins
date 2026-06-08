#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="xui-pgbouncer"
PGB_CONF="/etc/pgbouncer/pgbouncer.ini"
PGB_USERS="/etc/pgbouncer/userlist.txt"
XUI_DEFAULT="/etc/default/x-ui"
LOCAL_PGBOUNCER_HOST="127.0.0.1"
LOCAL_PGBOUNCER_PORT="6432"
INSTALL_3XUI_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
export PSQL_PAGER=cat

cleanup_temp_secrets() {
  rm -f \
    /tmp/begins-xui-local-dsn \
    /tmp/begins-xui-db-password \
    /tmp/begins-xui-db-user \
    /tmp/begins-xui-db-name \
    /tmp/begins-xui-remote-summary
}

trap cleanup_temp_secrets EXIT

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s][WARN] %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s][ERR] %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 执行"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

backup_runtime_files() {
  local backup_dir
  backup_dir="/root/begins-xui-pgbouncer-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"

  if [ -f "$XUI_DEFAULT" ]; then
    cp -a "$XUI_DEFAULT" "$backup_dir/x-ui.default.bak"
  fi
  if [ -d /etc/pgbouncer ]; then
    cp -a /etc/pgbouncer "$backup_dir/pgbouncer.etc.bak"
  fi

  log "已备份现有配置到：$backup_dir"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  if command_exists pgbouncer && command_exists psql; then
    log "已检测到 PgBouncer 和 psql，跳过安装。"
    return 0
  fi

  if ! command_exists apt-get; then
    die "未检测到 apt-get，目前脚本仅支持 Debian/Ubuntu 系统。"
  fi

  log "安装 PgBouncer 和 PostgreSQL 客户端..."
  apt-get update
  apt-get install -y pgbouncer postgresql-client ca-certificates curl
}

read_remote_dsn() {
  local prompt="${1:-请输入真实远程 PostgreSQL DSN}"
  local dsn
  echo >&2
  echo "$prompt" >&2
  echo "示例：postgres://xui:密码@远程IP:5432/xui?sslmode=disable" >&2
  read -r -s -p "DSN: " dsn
  echo >&2
  [ -n "$dsn" ] || die "DSN 不能为空"
  printf '%s' "$dsn"
}

read_xui_default_dsn() {
  [ -f "$XUI_DEFAULT" ] || die "未找到 $XUI_DEFAULT，无法读取现有 XUI_DB_DSN。"
  local dsn
  dsn="$(grep -E '^XUI_DB_DSN=' "$XUI_DEFAULT" | tail -n 1 | cut -d= -f2- || true)"
  [ -n "$dsn" ] || die "$XUI_DEFAULT 中未找到 XUI_DB_DSN。"
  printf '%s' "$dsn"
}

write_generated_files() {
  local remote_dsn="$1"
  local mode="$2"

  mkdir -p /etc/pgbouncer
  chmod 0755 /etc/pgbouncer

  REMOTE_DSN="$remote_dsn" MODE="$mode" LOCAL_HOST="$LOCAL_PGBOUNCER_HOST" LOCAL_PORT="$LOCAL_PGBOUNCER_PORT" python3 - <<'PY'
import os
import pathlib
import urllib.parse

remote_dsn = os.environ["REMOTE_DSN"].strip().strip('"').strip("'")
mode = os.environ.get("MODE", "")
local_host = os.environ.get("LOCAL_HOST", "127.0.0.1")
local_port = os.environ.get("LOCAL_PORT", "6432")

parsed = urllib.parse.urlparse(remote_dsn)
if parsed.scheme not in {"postgres", "postgresql"}:
    raise SystemExit("remote DSN must start with postgres:// or postgresql://")
if not parsed.hostname:
    raise SystemExit("remote DSN missing host")
if not parsed.username:
    raise SystemExit("remote DSN missing user")
if not parsed.password:
    raise SystemExit("remote DSN missing password")

dbname = parsed.path.lstrip("/")
if not dbname:
    raise SystemExit("remote DSN missing database name")

host = parsed.hostname
port = parsed.port or 5432
user = urllib.parse.unquote(parsed.username)
password = urllib.parse.unquote(parsed.password)

if mode == "preinstall" and host in {"127.0.0.1", "localhost", "::1"} and str(port) == local_port:
    raise SystemExit("preinstall requires the real remote DB DSN, not the local PgBouncer DSN")

safe_user = user.replace("\\", "\\\\").replace('"', '\\"')
safe_password = password.replace("\\", "\\\\").replace('"', '\\"')

pgbouncer_ini = "\n".join([
    "[databases]",
    f"{dbname} = host={host} port={port} dbname={dbname} user={user}",
    "",
    "[pgbouncer]",
    "listen_addr = 127.0.0.1",
    f"listen_port = {local_port}",
    "unix_socket_dir = /var/run/postgresql",
    "",
    "auth_type = plain",
    "auth_file = /etc/pgbouncer/userlist.txt",
    "",
    "pool_mode = session",
    "max_client_conn = 200",
    "default_pool_size = 8",
    "reserve_pool_size = 4",
    "reserve_pool_timeout = 3",
    "",
    "server_connect_timeout = 5",
    "server_login_retry = 3",
    "query_timeout = 0",
    "client_idle_timeout = 300",
    "server_idle_timeout = 60",
    "server_tls_sslmode = disable",
    "ignore_startup_parameters = extra_float_digits",
    "",
    f"admin_users = postgres, {user}",
    f"stats_users = postgres, {user}",
    "",
    "log_connections = 1",
    "log_disconnections = 1",
    "log_pooler_errors = 1",
    "",
])

pathlib.Path("/etc/pgbouncer/pgbouncer.ini").write_text(pgbouncer_ini, encoding="utf-8")
pathlib.Path("/etc/pgbouncer/userlist.txt").write_text(f'"{safe_user}" "{safe_password}"\n', encoding="utf-8")

local_netloc = f"{urllib.parse.quote(user, safe='')}:{urllib.parse.quote(password, safe='')}@{local_host}:{local_port}"
local_dsn = urllib.parse.urlunparse((parsed.scheme, local_netloc, f"/{dbname}", "", "sslmode=disable", ""))
pathlib.Path("/tmp/begins-xui-local-dsn").write_text(local_dsn + "\n", encoding="utf-8")
pathlib.Path("/tmp/begins-xui-db-user").write_text(user + "\n", encoding="utf-8")
pathlib.Path("/tmp/begins-xui-db-name").write_text(dbname + "\n", encoding="utf-8")
pathlib.Path("/tmp/begins-xui-db-password").write_text(password + "\n", encoding="utf-8")
pathlib.Path("/tmp/begins-xui-remote-summary").write_text(
    f"remote_host={host}\nremote_port={port}\ndatabase={dbname}\nuser={user}\nlocal_host={local_host}\nlocal_port={local_port}\n",
    encoding="utf-8",
)
PY

  chown postgres:postgres "$PGB_CONF" "$PGB_USERS"
  chmod 0640 "$PGB_CONF"
  chmod 0600 "$PGB_USERS"
  chmod 0600 /tmp/begins-xui-local-dsn /tmp/begins-xui-db-password /tmp/begins-xui-db-user /tmp/begins-xui-db-name
}

start_pgbouncer() {
  log "启动 PgBouncer..."
  systemctl enable pgbouncer >/dev/null 2>&1 || true
  systemctl restart pgbouncer
  sleep 1
  systemctl is-active --quiet pgbouncer || {
    systemctl status pgbouncer --no-pager -l || true
    die "PgBouncer 启动失败"
  }
  log "PgBouncer 已运行：127.0.0.1:${LOCAL_PGBOUNCER_PORT}"
}

test_pgbouncer() {
  local db_user db_name db_password
  db_user="$(cat /tmp/begins-xui-db-user)"
  db_name="$(cat /tmp/begins-xui-db-name)"
  db_password="$(cat /tmp/begins-xui-db-password)"

  log "测试 PgBouncer 到远程数据库..."
  PGPASSWORD="$db_password" psql \
    "host=${LOCAL_PGBOUNCER_HOST} port=${LOCAL_PGBOUNCER_PORT} dbname=${db_name} user=${db_user} sslmode=disable connect_timeout=5" \
    -Atc "select 1" >/dev/null
  log "PgBouncer 数据库连通测试通过。"
}

write_xui_default_file() {
  local local_dsn
  local_dsn="$(cat /tmp/begins-xui-local-dsn)"

  if [ -f "$XUI_DEFAULT" ]; then
    cp -a "$XUI_DEFAULT" "${XUI_DEFAULT}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  {
    echo "XUI_DB_TYPE=postgres"
    echo "XUI_DB_DSN=${local_dsn}"
  } > "$XUI_DEFAULT"
  chmod 0644 "$XUI_DEFAULT"

  log "已写入 $XUI_DEFAULT"
  echo
  echo "给 3X-UI 使用的本地 PostgreSQL DSN 已写入："
  sed -E 's#postgres://([^:]+):[^@]+@#postgres://\1:***@#' "$XUI_DEFAULT"
}

replace_xui_default_dsn() {
  local local_dsn
  local_dsn="$(cat /tmp/begins-xui-local-dsn)"

  [ -f "$XUI_DEFAULT" ] || die "未找到 $XUI_DEFAULT"
  cp -a "$XUI_DEFAULT" "${XUI_DEFAULT}.bak.$(date +%Y%m%d-%H%M%S)"

  if grep -q '^XUI_DB_DSN=' "$XUI_DEFAULT"; then
    sed -i "s#^XUI_DB_DSN=.*#XUI_DB_DSN=${local_dsn}#" "$XUI_DEFAULT"
  else
    echo "XUI_DB_DSN=${local_dsn}" >> "$XUI_DEFAULT"
  fi
  if grep -q '^XUI_DB_TYPE=' "$XUI_DEFAULT"; then
    sed -i 's#^XUI_DB_TYPE=.*#XUI_DB_TYPE=postgres#' "$XUI_DEFAULT"
  else
    sed -i '1iXUI_DB_TYPE=postgres' "$XUI_DEFAULT"
  fi
  chmod 0644 "$XUI_DEFAULT"

  log "已迁移 $XUI_DEFAULT 到本机 PgBouncer。"
  sed -E 's#postgres://([^:]+):[^@]+@#postgres://\1:***@#' "$XUI_DEFAULT"
}

restart_xui_if_present() {
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'x-ui.service'; then
    log "检测到 x-ui.service，正在重启..."
    systemctl daemon-reload
    systemctl restart x-ui
    sleep 3
    systemctl is-active --quiet x-ui || {
      systemctl status x-ui --no-pager -l || true
      die "x-ui 重启失败，请使用备份回滚 $XUI_DEFAULT"
    }
    log "x-ui 已重启并处于 active。"
  else
    log "未检测到 x-ui.service，跳过重启。"
  fi
}

show_pgbouncer_pools() {
  local db_user db_password
  db_user="$(cat /tmp/begins-xui-db-user)"
  db_password="$(cat /tmp/begins-xui-db-password)"
  echo
  echo "PgBouncer pools："
  PGPASSWORD="$db_password" psql \
    "host=${LOCAL_PGBOUNCER_HOST} port=${LOCAL_PGBOUNCER_PORT} dbname=pgbouncer user=${db_user} sslmode=disable connect_timeout=5" \
    -P pager=off \
    -c "SHOW POOLS;" || true
}

maybe_run_3xui_installer() {
  local answer
  echo
  read -r -p "是否现在执行官方 3X-UI 安装脚本？[y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      bash <(curl -Ls "$INSTALL_3XUI_URL")
      ;;
    *)
      echo
      echo "你可以稍后手动执行："
      echo "bash <(curl -Ls ${INSTALL_3XUI_URL})"
      ;;
  esac
}

preinstall() {
  require_root
  local remote_dsn
  remote_dsn="$(read_remote_dsn "请输入 3X-UI 将使用的真实远程 PostgreSQL DSN")"

  backup_runtime_files
  install_packages
  write_generated_files "$remote_dsn" "preinstall"
  start_pgbouncer
  test_pgbouncer
  write_xui_default_file

  echo
  echo "前置安装完成。远程数据库摘要："
  cat /tmp/begins-xui-remote-summary
  maybe_run_3xui_installer
}

migrate_existing() {
  require_root
  local current_dsn
  current_dsn="$(read_xui_default_dsn)"
  if printf '%s' "$current_dsn" | grep -q "@${LOCAL_PGBOUNCER_HOST}:${LOCAL_PGBOUNCER_PORT}/"; then
    die "当前 XUI_DB_DSN 已经指向本机 PgBouncer：${LOCAL_PGBOUNCER_HOST}:${LOCAL_PGBOUNCER_PORT}"
  fi

  backup_runtime_files
  install_packages
  write_generated_files "$current_dsn" "migrate"
  start_pgbouncer
  test_pgbouncer
  replace_xui_default_dsn
  restart_xui_if_present
  show_pgbouncer_pools

  echo
  echo "迁移完成。后续可观察："
  echo "journalctl -u x-ui --since '24 hours ago' --no-pager | grep -Ei 'dial tcp .*5432|idle-in-transaction|timeout|deadlock'"
  echo "journalctl -u pgbouncer --since '24 hours ago' --no-pager | grep -Ei 'error|timeout|pooler|failed'"
}

show_usage() {
  cat <<'EOF'
用法：
  xui-pgbouncer.sh preinstall   # 3X-UI 安装前：输入远程 DB DSN，安装 PgBouncer，写 /etc/default/x-ui
  xui-pgbouncer.sh migrate      # 已安装 3X-UI：读取 /etc/default/x-ui，迁移到本机 PgBouncer
EOF
}

main() {
  case "${1:-}" in
    preinstall)
      preinstall
      ;;
    migrate)
      migrate_existing
      ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
