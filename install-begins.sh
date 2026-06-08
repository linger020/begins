#!/bin/bash
set -e

mkdir -p /usr/local/bin
curl -fsSL -o /usr/local/bin/begins https://raw.githubusercontent.com/linger020/begins/main/begins.sh
chmod +x /usr/local/bin/begins

echo "begins installed. Run: begins"
