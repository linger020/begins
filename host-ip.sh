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

BASHRC="/root/.bashrc"
START_MARK="# >>> host-ip red prompt"
END_MARK="# <<< host-ip red prompt"

if [ -f "$BASHRC" ]; then
  sed -i "/$START_MARK/,/$END_MARK/d" "$BASHRC"
else
  touch "$BASHRC"
fi

cat >> "$BASHRC" <<'PROMPT_EOF'

# >>> host-ip red prompt
export PS1='\[\033[31m\]\u@\h\[\033[0m\]:\w\$ '
# <<< host-ip red prompt
PROMPT_EOF

echo "已改为：$NAME"
echo "root@hostname 已设置为红色"
echo "执行 exec bash 或重新登录 SSH 生效"
