#!/bin/bash
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

LOGFILE="$NGINX_LOGFILE"
# Mode: directory (all configs) or single file
if [ -n "${NGINX_SITES_AVAILABLE:-}" ]; then
  MODE="dir"
  NGINX_DIR="$NGINX_SITES_AVAILABLE"
elif [ -n "${nginx_conf:-}" ]; then
  MODE="file"
else
  echo "Ошибка: в .env задайте NGINX_SITES_AVAILABLE (директория) или nginx_conf (один файл)." >&2
  exit 1
fi

for var in DNS_RECORD host LOGFILE TGBOT NGINX_ALLOW_MARKER; do
  [ -z "${!var}" ] && echo "Ошибка: в .env не задано: $var" >&2 && exit 1
done
MARKER="$NGINX_ALLOW_MARKER"

mkdir -p "$(dirname "$LOGFILE")"

# Check directory or file
if [ "$MODE" = "dir" ]; then
  if [ ! -d "$NGINX_DIR" ]; then
    echo "$(date): Ошибка: Директория $NGINX_DIR не существует" >> "$LOGFILE"
    exit 1
  fi
  if [ ! -r "$NGINX_DIR" ]; then
    echo "$(date): Ошибка: Нет прав на чтение $NGINX_DIR" >> "$LOGFILE"
    exit 1
  fi
else
  if [ ! -f "$nginx_conf" ]; then
    echo "$(date): Ошибка: Файл $nginx_conf не существует" >> "$LOGFILE"
    exit 1
  fi
  if [ ! -w "$nginx_conf" ]; then
    echo "$(date): Ошибка: Нет прав на запись в $nginx_conf" >> "$LOGFILE"
    exit 1
  fi
fi

# Resolve IP from DNS
NEW_IP=$(dig +short "$DNS_RECORD" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | head -n1) || true

if [ -z "$NEW_IP" ]; then
  message="$(date): [$host] ERROR! Не удалось получить IP для $DNS_RECORD"
  echo "$message" >> "$LOGFILE"
  $TGBOT "$message"
  exit 1
fi

if [[ "$NEW_IP" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  message="$(date): Получен локальный IP ($NEW_IP) для $DNS_RECORD. Возможно, проблема с локальным DNS bind. Пропускаем обновление."
  echo "$message" >> "$LOGFILE"
  $TGBOT "$message"
  exit 0
fi

# Update IP in one file (by marker from .env); return 0 if replacement was made
update_one_file() {
  local f="$1"
  local current_ip
  current_ip=$(grep -F "$MARKER" "$f" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | head -n1)
  if [ -z "$current_ip" ]; then
    return 1
  fi
  if [ "$current_ip" = "$NEW_IP" ]; then
    return 2
  fi
  sed -i '\|'"$MARKER"'| s|allow .*|allow '"$NEW_IP"'; '"$MARKER"'|' "$f"
}

if [ "$MODE" = "dir" ]; then
  # Iterate over all configs in directory
  modified_files=()
  modified_backups=()
  need_update=false
  for f in "$NGINX_DIR"/*; do
    [ -f "$f" ] || continue
    [ -w "$f" ] || continue
    grep -qF "$MARKER" "$f" 2>/dev/null || continue
    temp_backup=$(mktemp)
    cp "$f" "$temp_backup"
    ret=0; update_one_file "$f" || ret=$?
    if [ "$ret" -eq 0 ]; then
      modified_files+=("$f")
      modified_backups+=("$temp_backup")
      need_update=true
    else
      rm -f "$temp_backup"
    fi
  done

  if [ "$need_update" = false ]; then
    echo "$(date): IP не изменился или нет конфигов с маркером [$MARKER]. Обновление не требуется." >> "$LOGFILE"
    exit 0
  fi

  if ! nginx -t 2>/dev/null; then
    message="$(date): [$host] ALARM! Ошибка в конфигурации nginx после правки"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    for i in "${!modified_files[@]}"; do
      mv "${modified_backups[$i]}" "${modified_files[$i]}"
    done
    exit 1
  fi

  if systemctl reload nginx; then
    message="$(date): [$host] ALARM! Обновился IP для $DNS_RECORD в конфигах.
Новый IP: $NEW_IP
Файлы: ${modified_files[*]}"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    for b in "${modified_backups[@]}"; do rm -f "$b"; done
  else
    message="$(date): [$host] ALARM! Ошибка при перезагрузке nginx"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    for i in "${!modified_files[@]}"; do
      mv "${modified_backups[$i]}" "${modified_files[$i]}"
    done
    exit 1
  fi

else
  # Single file mode
  CURRENT_IP=$(grep -F "$MARKER" "$nginx_conf" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | head -n1)

  if [ -z "$CURRENT_IP" ]; then
    message="$(date): [$host] ERROR! Не найдена строка с маркером [$MARKER] в $nginx_conf"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    exit 1
  fi

  if [ "$NEW_IP" = "$CURRENT_IP" ]; then
    echo "$(date): IP не изменился ($CURRENT_IP). Обновление не требуется." >> "$LOGFILE"
    exit 0
  fi

  temp_conf=$(mktemp)
  cp "$nginx_conf" "$temp_conf"

  if ! sed -i '\|'"$MARKER"'| s|allow .*|allow '"$NEW_IP"'; '"$MARKER"'|' "$nginx_conf"; then
    message="$(date): [$host] ERROR! Ошибка при обновлении конфигурации"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    mv "$temp_conf" "$nginx_conf"
    exit 1
  fi

  if nginx -t 2>/dev/null; then
    if systemctl reload nginx; then
      message="$(date): [$host] ALARM! Обновился IP для $DNS_RECORD.
Старый IP: $CURRENT_IP
Новый IP: $NEW_IP"
      echo "$message" >> "$LOGFILE"
      $TGBOT "$message"
      rm -f "$temp_conf"
    else
      message="$(date): [$host] ALARM! Ошибка при перезагрузке nginx"
      echo "$message" >> "$LOGFILE"
      $TGBOT "$message"
      mv "$temp_conf" "$nginx_conf"
      exit 1
    fi
  else
    message="$(date): [$host] ALARM! Ошибка в конфигурации nginx"
    echo "$message" >> "$LOGFILE"
    $TGBOT "$message"
    mv "$temp_conf" "$nginx_conf"
    exit 1
  fi
fi
