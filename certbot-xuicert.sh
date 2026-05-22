#!/bin/bash
set -euo pipefail

CERT_DIR="/root/xuicert"
LOG_FILE="/var/log/certbot-xuicert.log"

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
  fi
}

is_domain() {
  local value="$1"
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

install_certbot() {
  if ! command -v certbot >/dev/null 2>&1; then
    echo "==> 安装 certbot"
    apt update
    apt install -y certbot ca-certificates curl
  fi
}

show_port_80() {
  if ss -tlnp 2>/dev/null | grep -qE '(:80\s)'; then
    echo "[WARN] 检测到 80 端口已被占用，certbot standalone 可能失败："
    ss -tlnp | grep -E '(:80\s)' || true
    echo
    echo "请先停止占用 80 端口的服务，或改用 webroot/DNS 方式。"
    echo "常见命令：systemctl stop nginx apache2 caddy 2>/dev/null || true"
    echo
  fi
}

issue_cert() {
  local domain="$1"
  echo "==> 为域名申请证书：$domain"
  echo "==> 确保域名 A/AAAA 记录已指向当前服务器，并且 80 端口可被公网访问"

  certbot certonly \
    --standalone \
    --preferred-challenges http \
    -d "$domain" \
    --agree-tos \
    --register-unsafely-without-email \
    --non-interactive
}

link_cert() {
  local domain="$1"
  local live_dir="/etc/letsencrypt/live/$domain"

  if [ ! -f "$live_dir/privkey.pem" ] || [ ! -f "$live_dir/fullchain.pem" ]; then
    echo "[ERR] 未找到证书文件：$live_dir"
    exit 1
  fi

  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"

  ln -sfn "$live_dir/privkey.pem" "$CERT_DIR/privkey.pem"
  ln -sfn "$live_dir/fullchain.pem" "$CERT_DIR/fullchain.pem"

  echo "==> 已创建软链接"
  echo "私钥：$CERT_DIR/privkey.pem -> $live_dir/privkey.pem"
  echo "证书：$CERT_DIR/fullchain.pem -> $live_dir/fullchain.pem"
}

main() {
  need_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  local domain="${1:-}"
  if [ -z "$domain" ]; then
    read -r -p "请输入要申请证书的域名：" domain
  fi

  domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | xargs)"

  if ! is_domain "$domain"; then
    echo "[ERR] 域名格式不正确：$domain"
    exit 1
  fi

  install_certbot
  show_port_80
  issue_cert "$domain" 2>&1 | tee -a "$LOG_FILE"
  link_cert "$domain" | tee -a "$LOG_FILE"

  echo
  echo "完成。3x-ui / x-ui 证书路径可填写："
  echo "$CERT_DIR/fullchain.pem"
  echo "$CERT_DIR/privkey.pem"
}

main "$@"
