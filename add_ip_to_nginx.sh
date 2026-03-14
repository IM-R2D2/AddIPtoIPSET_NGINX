#!/bin/bash
# Update allow IP in include files by marker; silent exit if unchanged or no marker
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_env

# Include dir (e.g. /etc/nginx/ip-allow); files contain "allow IP; #MARKER"
INCLUDE_DIR="${NGINX_IP_ALLOW_DIR:-${NGINX_SITES_AVAILABLE:-}}"
for var in DNS_RECORD host NGINX_LOGFILE TGBOT NGINX_ALLOW_MARKER; do
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
  log_to "$LOGFILE" "Ошибка: Директория include $INCLUDE_DIR не существует"
  exit 1
fi
if [ ! -r "$INCLUDE_DIR" ] || [ ! -w "$INCLUDE_DIR" ]; then
  log_to "$LOGFILE" "Ошибка: Нет прав на чтение/запись $INCLUDE_DIR"
  exit 1
fi

if ! get_dns_ips "$DNS_RECORD"; then
  msg="[$host] ERROR: DNS не вернул ни одного IP для $DNS_RECORD"
  log_to "$LOGFILE" "$msg"
  send_telegram "$msg"
  exit 1
fi

# Extract IPs from lines containing MARKER in file
current_ips_in_file() {
  local f=$1
  grep -F "$MARKER" "$f" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
}

# Replace "allow ... MARKER" block with one allow per NEW_IPS
rewrite_allow_block() {
  local f=$1
  local replaced=false
  local tmpf
  tmpf=$(mktemp)
  while IFS= read -r line; do
    if [[ "$line" =~ allow[[:space:]].*$MARKER ]]; then
      if ! $replaced; then
        for ip in "${NEW_IPS[@]}"; do
          echo "allow $ip; $MARKER"
        done
        replaced=true
      fi
      continue
    fi
    echo "$line"
  done < "$f" > "$tmpf"
  if $replaced; then
    cat "$tmpf" > "$f"
  fi
  rm -f "$tmpf"
  $replaced
}

changed_files=()
changed_backups=()

for f in "$INCLUDE_DIR"/*; do
  [ -f "$f" ] || continue
  [ -w "$f" ] || continue

  line=$(grep -F "$MARKER" "$f" 2>/dev/null | head -n1)
  [ -z "$line" ] && continue

  CURRENT_IPS_SORTED=$(current_ips_in_file "$f" | sort)
  NEW_IPS_SORTED=$(printf '%s\n' "${NEW_IPS[@]}" | sort)
  if [ "$CURRENT_IPS_SORTED" = "$NEW_IPS_SORTED" ]; then
    continue
  fi

  temp_backup=$(mktemp)
  cp "$f" "$temp_backup"
  if rewrite_allow_block "$f"; then
    changed_files+=("$f")
    changed_backups+=("$temp_backup")
  else
    rm -f "$temp_backup"
  fi
done

# No changes: exit silently (no log, no Telegram)
[ ${#changed_files[@]} -eq 0 ] && exit 0

if ! nginx -t 2>/dev/null; then
  msg="$(date): [$host] ERROR: nginx -t не прошёл после правки"
  log_to "$LOGFILE" "[$host] ERROR: nginx -t не прошёл после правки"
  send_telegram "$msg"
  for i in "${!changed_files[@]}"; do
    mv "${changed_backups[$i]}" "${changed_files[$i]}"
  done
  exit 1
fi

if ! systemctl reload nginx 2>/dev/null; then
  msg="$(date): [$host] ERROR: не удалось перезагрузить nginx"
  log_to "$LOGFILE" "[$host] ERROR: не удалось перезагрузить nginx"
  send_telegram "$msg"
  for i in "${!changed_files[@]}"; do
    mv "${changed_backups[$i]}" "${changed_files[$i]}"
  done
  exit 1
fi

for b in "${changed_backups[@]}"; do rm -f "$b"; done

msg="$(date): [$host] IP обновился для $DNS_RECORD
Список IP: ${NEW_IPS[*]}
Файлы: ${changed_files[*]}"
log_to "$LOGFILE" "[$host] IP обновился для $DNS_RECORD. Список IP: ${NEW_IPS[*]}. Файлы: ${changed_files[*]}"
send_telegram "$msg"
