#!/usr/bin/env bash
# begins menu script to install latest BBR v3 from byJoey
# Usage: bash install-bbr-v3.sh

set -euo pipefail

log() { echo "[begins-bbr-v3] $*"; }

log "开始安装 BBR v3（byJoey/Actions-bbr-v3）..."

bash <(curl -L -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh)

log "BBR v3 安装完成，建议重启服务器或重新加载网络模块。"