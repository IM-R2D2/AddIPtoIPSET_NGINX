#!/bin/bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Load .env (script dir or current dir)
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

# Variables from .env only
LOGFILE="$IPSET_LOGFILE"
read -ra IPSET_LISTS <<< "$IPSET_LISTS"

for var in DNS_RECORD host LOGFILE TGBOT OLD_IP_FILE IPSET_CONF; do
  [ -z "${!var}" ] && echo "Ошибка: в .env не задано: $var" >&2 && exit 1
done
[ ${#IPSET_LISTS[@]} -eq 0 ] && echo "Ошибка: в .env не задано: IPSET_LISTS" >&2 && exit 1

mkdir -p "$(dirname "$LOGFILE")"

# Resolve current IP from DNS
NEW_IP=$(dig +short "$DNS_RECORD" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)

# Ensure IP is present and valid
if [ -z "$NEW_IP" ]; then
  echo "$(date): Не удалось получить IP для $DNS_RECORD" >> "$LOGFILE"
  exit 1
fi

if ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
   ! [[ $(echo "$NEW_IP" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255') ]]; then
  echo "$(date): Получен некорректный IP ($NEW_IP) для $DNS_RECORD" >> "$LOGFILE"
  $TGBOT "[$host] ERROR:
    Получен некорректный IP [$NEW_IP] для $DNS_RECORD"
  exit 1
fi

# Skip 127.0.0.0/24 (local)
if [[ "$NEW_IP" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "$(date): Получен локальный IP ($NEW_IP) для $DNS_RECORD. Возможно, проблема с локальным DNS bind. Пропускаем обновление." >> "$LOGFILE"
  exit 0
fi

# Valid ipset names: alphanumeric, underscore, hyphen only
check_ipset_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Check if ipset exists
check_ipset_exists() {
  local ipset_name=$1
  check_ipset_name "$ipset_name" || return 1
  if ! ipset list -n | grep -qFx "$ipset_name"; then
    echo "$(date): Набор $ipset_name не существует" >> "$LOGFILE"
    $TGBOT "[$host] ERROR:
        Набор ipset [$ipset_name] не существует!"
    return 1
  fi
  return 0
}

# Check if IP is in set
check_ip_in_ipset() {
  local ipset_name=$1
  local ip=$2
  check_ipset_name "$ipset_name" || return 1
  if ipset list "$ipset_name" | grep -qF "$ip"; then
    return 0
  fi
  return 1
}

# Check IP in all sets
check_ip_in_all_ipsets() {
  local ip=$1
  local found=false

  for ipset_name in "${IPSET_LISTS[@]}"; do
    if check_ipset_exists "$ipset_name"; then
      if check_ip_in_ipset "$ipset_name" "$ip"; then
        found=true
      fi
    fi
  done

  if ! $found; then
    echo "$(date): IP $ip не найден ни в одном из списков" >> "$LOGFILE"
  fi
  return $found
}

# Update IP in one ipset
update_ipset() {
  local ipset_name=$1
  local new_ip=$2
  local old_ip=$3
  local success=true

  if ! check_ipset_exists "$ipset_name"; then
    $TGBOT "[$host] ERROR: Набор ipset [$ipset_name] не существует!"
    return 1
  fi

  if check_ip_in_ipset "$ipset_name" "$old_ip"; then
    if ! ipset del "$ipset_name" "$old_ip"; then
      echo "$(date): Ошибка при удалении IP $old_ip из набора $ipset_name" >> "$LOGFILE"
      success=false
    else
      echo "$(date): Удален IP $old_ip из набора $ipset_name" >> "$LOGFILE"
    fi
  fi

  if $success; then
    if ! check_ip_in_ipset "$ipset_name" "$new_ip"; then
      echo "$(date): Пытаюсь добавить IP $new_ip в набор $ipset_name" >> "$LOGFILE"
      if ! ipset add "$ipset_name" "$new_ip" 2>>"$LOGFILE"; then
        echo "$(date): Ошибка при добавлении IP $new_ip в набор $ipset_name (stderr выше)" >> "$LOGFILE"
        ipset list "$ipset_name" | head -20 >> "$LOGFILE"
        success=false
      else
        echo "$(date): Добавлен IP $new_ip в набор $ipset_name" >> "$LOGFILE"
      fi
    else
      echo "$(date): IP $new_ip уже присутствует в наборе $ipset_name, добавление не требуется" >> "$LOGFILE"
      return 2  # exit code for 'already present'
    fi
  fi

  return $success
}

# Add IP to sets on first run
initialize_ipset_lists() {
  local ip=$1
  local init_success=true
  local changes_made=false

  for ipset_name in "${IPSET_LISTS[@]}"; do
    if ! check_ipset_exists "$ipset_name"; then
      echo "$(date): Набор $ipset_name не существует" >> "$LOGFILE"
      init_success=false
      continue
    fi
    if check_ip_in_ipset "$ipset_name" "$ip"; then
      continue
    fi
    echo "$(date): IP $ip отсутствует в наборе $ipset_name, добавляем" >> "$LOGFILE"
    if ! ipset add "$ipset_name" "$ip"; then
      echo "$(date): Ошибка при добавлении IP $ip в набор $ipset_name" >> "$LOGFILE"
      init_success=false
    else
      echo "$(date): Добавлен IP $ip в набор $ipset_name" >> "$LOGFILE"
      changes_made=true
    fi
  done

  if $changes_made; then
    if ipset save | tee "$IPSET_CONF" > /dev/null; then
      echo "$(date): Конфигурация ipset сохранена после инициализации" >> "$LOGFILE"
      $TGBOT "[$host] INFO:
            IP [$ip] добавлен в отсутствующие списки для хоста $DNS_RECORD"
      return 0
    else
      init_success=false
    fi
  fi

  if ! $init_success; then
    $TGBOT "[$host] ERROR:
        Ошибка при инициализации IP [$ip] для хоста $DNS_RECORD"
    return 1
  fi
  return 0
}

# First run or empty/corrupt state file
if [ ! -f "$OLD_IP_FILE" ] || [ ! -s "$OLD_IP_FILE" ]; then
  echo "$(date): Первый запуск или пустой файл $OLD_IP_FILE" >> "$LOGFILE"

  if [ -z "$NEW_IP" ] || ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$(date): Некорректный IP при первом запуске: $NEW_IP" >> "$LOGFILE"
    $TGBOT "[$host] ERROR:
        Некорректный IP [$NEW_IP] при первом запуске скрипта"
    exit 1
  fi

  if initialize_ipset_lists "$NEW_IP"; then
    echo "$NEW_IP" > "$OLD_IP_FILE"
    exit 0
  else
    rm -f "$OLD_IP_FILE"
    exit 1
  fi
fi

OLD_IP=$(cat "$OLD_IP_FILE")
[ -z "$OLD_IP" ] && rm -f "$OLD_IP_FILE" && exit 1

# Ensure IP is in all sets, add if missing
initialize_ipset_lists "$OLD_IP"

if [ "$NEW_IP" = "$OLD_IP" ]; then
  exit 0
fi

# IP changed — update all ipsets
echo "[$host] $(date) INFO:
Обнаружено изменение IP.
Старый: $OLD_IP, Новый: $NEW_IP" >> "$LOGFILE"

PREV_IP="$OLD_IP"
check_ip_in_all_ipsets "$PREV_IP"

update_success=true
for ipset_name in "${IPSET_LISTS[@]}"; do
  update_ipset "$ipset_name" "$NEW_IP" "$PREV_IP"
  status=$?
  if [ "$status" -eq 2 ]; then
    echo "$(date): IP $NEW_IP уже присутствует в наборе $ipset_name, продолжаем." >> "$LOGFILE"
  elif [ "$status" -ne 0 ]; then
    echo "$(date): Ошибка при обновлении $ipset_name" >> "$LOGFILE"
    update_success=false
  fi
done

if $update_success; then
  if ipset save | tee "$IPSET_CONF" > /dev/null; then
    echo "$(date): Изменения сохранены в $IPSET_CONF" >> "$LOGFILE"
    $TGBOT "[$host] SUCCESS:
IP для хоста $DNS_RECORD обновлен.
Старый IP: [$PREV_IP]
Новый IP: [$NEW_IP]"
    echo "$NEW_IP" > "$OLD_IP_FILE"
  else
    echo "$(date): Ошибка при сохранении конфигурации ipset" >> "$LOGFILE"
    $TGBOT "[$host] ERROR: Ошибка при сохранении конфигурации ipset"
  fi
else
  echo "$(date): Произошли ошибки при обновлении наборов ipset" >> "$LOGFILE"
  $TGBOT "[$host] ERROR:
Ошибка при обновлении IP в наборах ipset для хоста $DNS_RECORD.
Старый IP: [$PREV_IP]
Новый IP: [$NEW_IP]"
fi