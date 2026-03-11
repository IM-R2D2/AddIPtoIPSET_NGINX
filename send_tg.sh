#!/bin/bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Load .env (script dir or current dir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for env in "$SCRIPT_DIR/.env" ".env"; do
  if [ -f "$env" ]; then
    set -a && source "$env" && set +a
    break
  fi
done

for var in TG_TOKEN TG_CHAT_ID; do
  [ -z "${!var}" ] && echo "Ошибка: в .env не задано: $var" >&2 && exit 1
done

URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
MESSAGE="${1:-}"

curl -s -X POST "$URL" \
  --data-urlencode "chat_id=$TG_CHAT_ID" \
  --data-urlencode "text=$MESSAGE"
