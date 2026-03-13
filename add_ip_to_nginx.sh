#!/bin/bash
# VER: 2026-03 — поиск и замена IP в файлах include (ip-allow); при отсутствии маркера/неизменённом IP — тихий выход
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_LOADED=
for env in "$SCRIPT_DIR/.env" ".env"; do
  if [ -f "$env" ]; then
    set -a && source "$env" && set +a
    ENV_LOADED=1
    break
  fi
done
if [ -z "${ENV_LOADED:-}" ]; then
  echo "Ошибка: файл .env не найден. Создайте .env из .env_example." >&2
  exit 1
fi

# Директория с include-файлами (например /etc/nginx/ip-allow); в каждом — строка allow IP; #MARKER
INCLUDE_DIR="${NGINX_IP_ALLOW_DIR:-${NGINX_SITES_AVAILABLE:-}}"
for var in DNS_RECORD host LOGFILE TGBOT NGINX_ALLOW_MARKER; do
  [ -z "${!var}" ] && echo "Ошибка: в .env не задано: $var" >&2 && exit 1
done
[ -z "$INCLUDE_DIR" ] && echo "Ошибка: в .env задайте NGINX_IP_ALLOW_DIR (директория с include-файлами)." >&2 && exit 1

LOGFILE="$NGINX_LOGFILE"
MARKER="$NGINX_ALLOW_MARKER"

case "$LOGFILE" in
  /*) ;;
  *) LOGFILE="$SCRIPT_DIR/$LOGFILE" ;;
esac
case "$INCLUDE_DIR" in
  /*) ;;
  *) INCLUDE_DIR="$SCRIPT_DIR/$INCLUDE_DIR" ;;
esac

mkdir -p "$(dirname "$LOGFILE")"

if [ ! -d "$INCLUDE_DIR" ]; then
  echo "$(date): Ошибка: Директория include $INCLUDE_DIR не существует" >> "$LOGFILE"
  exit 1
fi
if [ ! -r "$INCLUDE_DIR" ] || [ ! -w "$INCLUDE_DIR" ]; then
  echo "$(date): Ошибка: Нет прав на чтение/запись $INCLUDE_DIR" >> "$LOGFILE"
  exit 1
fi

send_telegram() {
  $TGBOT "$1"
}

# Получаем IP из DNS (не падаем при отсутствии ответа)
NEW_IP=$(dig +short "$DNS_RECORD" 2>/dev/null | grep -m1 -E '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)

if [ -z "$NEW_IP" ]; then
  msg="$(date): [$host] ERROR: DNS не вернул IP для $DNS_RECORD"
  echo "$msg" >> "$LOGFILE"
  send_telegram "$msg"
  exit 1
fi

if [[ "$NEW_IP" =~ ^127\. ]]; then
  # Локальный IP — не обновляем конфиг, выходим тихо
  exit 0
fi

changed_files=()
changed_backups=()

for f in "$INCLUDE_DIR"/*; do
  [ -f "$f" ] || continue
  [ -w "$f" ] || continue

  line=$(grep -F "$MARKER" "$f" 2>/dev/null | head -n1)
  [ -z "$line" ] && continue

  CURRENT_IP=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  [ -z "$CURRENT_IP" ] && continue

  if [ "$CURRENT_IP" = "$NEW_IP" ]; then
    continue
  fi

  temp_backup=$(mktemp)
  cp "$f" "$temp_backup"
  if sed -i '\|'"$MARKER"'| s|allow .*|allow '"$NEW_IP"'; '"$MARKER"'|' "$f" 2>/dev/null; then
    changed_files+=("$f")
    changed_backups+=("$temp_backup")
  else
    rm -f "$temp_backup"
  fi
done

# Ничего не поменялось — тихий выход (ни лог, ни Telegram)
[ ${#changed_files[@]} -eq 0 ] && exit 0

if ! nginx -t 2>/dev/null; then
  msg="$(date): [$host] ERROR: nginx -t не прошёл после правки"
  echo "$msg" >> "$LOGFILE"
  send_telegram "$msg"
  for i in "${!changed_files[@]}"; do
    mv "${changed_backups[$i]}" "${changed_files[$i]}"
  done
  exit 1
fi

if ! systemctl reload nginx 2>/dev/null; then
  msg="$(date): [$host] ERROR: не удалось перезагрузить nginx"
  echo "$msg" >> "$LOGFILE"
  send_telegram "$msg"
  for i in "${!changed_files[@]}"; do
    mv "${changed_backups[$i]}" "${changed_files[$i]}"
  done
  exit 1
fi

for b in "${changed_backups[@]}"; do rm -f "$b"; done

msg="$(date): [$host] IP обновился для $DNS_RECORD
Новый IP: $NEW_IP
Файлы: ${changed_files[*]}"
echo "$msg" >> "$LOGFILE"
send_telegram "$msg"
