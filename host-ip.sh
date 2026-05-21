#!/bin/bash
set -e

IP=$(curl -4 -fsS --max-time 8 https://ip.sb || curl -4 -fsS --max-time 8 https://ifconfig.me)

if [ -z "$IP" ]; then
  echo "获取公网 IP 失败"
  exit 1
fi

NAME="ip-${IP//./-}"

hostnamectl set-hostname "$NAME"

if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1 $NAME/" /etc/hosts
else
  echo "127.0.1.1 $NAME" >> /etc/hosts
fi

echo "已改为：$NAME"
echo "执行 exec bash 或重新登录 SSH 生效"
