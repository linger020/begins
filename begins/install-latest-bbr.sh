#!/usr/bin/env bash
# begins script to install latest BBR from byJoey/Actions-bbr-v3
# Usage: bash install-latest-bbr.sh

set -euo pipefail

log() { echo "[begins-bbr] $*"; }

log "开始安装最新 BBR..."

bash <(curl -L -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh)

log "BBR 安装完成，建议重启服务器或重新加载网络模块以生效。"