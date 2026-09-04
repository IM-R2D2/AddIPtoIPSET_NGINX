#!/bin/bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_env

LOGFILE="$IPSET_LOGFILE"
read -ra IPSET_LISTS <<< "$IPSET_LISTS"

# Normalize paths to be relative to script directory if they are not absolute
case "$LOGFILE" in
  /*) ;;
  *) LOGFILE="$SCRIPT_DIR/$LOGFILE" ;;
esac
case "${OLD_IP_FILE:-}" in
  /*|"") ;;
  *) OLD_IP_FILE="$SCRIPT_DIR/$OLD_IP_FILE" ;;
esac
case "${IPSET_CONF:-}" in
  /*|"") ;;
  *) IPSET_CONF="$SCRIPT_DIR/$IPSET_CONF" ;;
esac

for var in DNS_RECORD host LOGFILE TGBOT OLD_IP_FILE IPSET_CONF; do
  [ -z "${!var}" ] && echo "Ошибка: в .env не задано: $var" >&2 && exit 1
done
[ ${#IPSET_LISTS[@]} -eq 0 ] && echo "Ошибка: в .env не задано: IPSET_LISTS" >&2 && exit 1

mkdir -p "$(dirname "$LOGFILE")"

if ! get_dns_ips "$DNS_RECORD"; then
  log_to "$LOGFILE" "Не удалось получить ни одного валидного IP для $DNS_RECORD"
  send_telegram "[$host] ERROR: DNS не вернул валидных IP для $DNS_RECORD"
  exit 1
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
    log_to "$LOGFILE" "Набор $ipset_name не существует"
    send_telegram "[$host] ERROR:
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
  if ipset list "$ipset_name" | grep -qxF "$ip"; then
    return 0
  fi
  return 1
}

# Add one IP to all sets (for init)
add_one_ip_to_all_sets() {
  local ip=$1
  local init_success=true
  local changes_made=false

  for ipset_name in "${IPSET_LISTS[@]}"; do
    if ! check_ipset_exists "$ipset_name"; then
      init_success=false
      continue
    fi
    if check_ip_in_ipset "$ipset_name" "$ip"; then
      continue
    fi
    log_to "$LOGFILE" "IP $ip отсутствует в наборе $ipset_name, добавляем"
    if ! ipset add "$ipset_name" "$ip"; then
      log_to "$LOGFILE" "Ошибка при добавлении IP $ip в набор $ipset_name"
      init_success=false
    else
      log_to "$LOGFILE" "Добавлен IP $ip в набор $ipset_name"
      changes_made=true
    fi
  done

  if $changes_made; then
    if ipset save | tee "$IPSET_CONF" > /dev/null; then
      log_to "$LOGFILE" "Конфигурация ipset сохранена после инициализации"
    else
      init_success=false
    fi
  fi
  $init_success
}

# Add all IPs to sets on first run
initialize_ipset_lists() {
  local -n ips_ref=$1
  local init_success=true
  local any_added=false

  for ip in "${ips_ref[@]}"; do
    if add_one_ip_to_all_sets "$ip"; then
      : # ok
    else
      init_success=false
    fi
  done

  for ipset_name in "${IPSET_LISTS[@]}"; do
    if ! check_ipset_exists "$ipset_name"; then
      log_to "$LOGFILE" "Набор $ipset_name не существует"
      init_success=false
    fi
  done

  if ! $init_success; then
    send_telegram "[$host] ERROR:
        Ошибка при инициализации IP для хоста $DNS_RECORD"
    return 1
  fi
  send_telegram "[$host] INFO:
        IP(ы) [${ips_ref[*]}] добавлены в списки для хоста $DNS_RECORD"
  return 0
}

# First run: add all NEW_IPS to sets, save state (one IP per line)
if [ ! -f "$OLD_IP_FILE" ] || [ ! -s "$OLD_IP_FILE" ]; then
  log_to "$LOGFILE" "Первый запуск или пустой файл $OLD_IP_FILE"
  if initialize_ipset_lists NEW_IPS; then
    printf '%s\n' "${NEW_IPS[@]}" > "$OLD_IP_FILE"
    exit 0
  else
    rm -f "$OLD_IP_FILE"
    exit 1
  fi
fi

# Read previous IP list (one per line); ensure they are in sets (e.g. after manual removal)
mapfile -t OLD_IPS < <(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$OLD_IP_FILE" 2>/dev/null || true)
for ip in "${OLD_IPS[@]}"; do
  add_one_ip_to_all_sets "$ip" || true
done

# Exit if old and new IP lists are the same
OLD_SORTED=$(printf '%s\n' "${OLD_IPS[@]}" | sort)
NEW_SORTED=$(printf '%s\n' "${NEW_IPS[@]}" | sort)
if [ "$OLD_SORTED" = "$NEW_SORTED" ]; then
  exit 0
fi

# IPs to remove (were in state, no longer in DNS)
to_remove=()
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  to_remove+=("$ip")
done < <(comm -23 <(printf '%s\n' "${OLD_IPS[@]}" | sort -u) <(printf '%s\n' "${NEW_IPS[@]}" | sort -u))
# IPs to add (new in DNS)
to_add=()
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  to_add+=("$ip")
done < <(comm -13 <(printf '%s\n' "${OLD_IPS[@]}" | sort -u) <(printf '%s\n' "${NEW_IPS[@]}" | sort -u))

log_to "$LOGFILE" "[$host] INFO: Обнаружено изменение списка IP для $DNS_RECORD. Было: ${OLD_IPS[*]:-ни одного} Стало: ${NEW_IPS[*]} Удаляем: ${to_remove[*]:-—} Добавляем: ${to_add[*]:-—}"

update_success=true
for ipset_name in "${IPSET_LISTS[@]}"; do
  if ! check_ipset_exists "$ipset_name"; then
    update_success=false
    continue
  fi
  for ip in "${to_remove[@]}"; do
    if check_ip_in_ipset "$ipset_name" "$ip"; then
      if ! ipset del "$ipset_name" "$ip" 2>>"$LOGFILE"; then
        log_to "$LOGFILE" "Ошибка удаления IP $ip из $ipset_name"
        update_success=false
      else
        log_to "$LOGFILE" "Удален IP $ip из набора $ipset_name"
      fi
    fi
  done
  for ip in "${to_add[@]}"; do
    if ! check_ip_in_ipset "$ipset_name" "$ip"; then
      if ! ipset add "$ipset_name" "$ip" 2>>"$LOGFILE"; then
        log_to "$LOGFILE" "Ошибка добавления IP $ip в $ipset_name"
        update_success=false
      else
        log_to "$LOGFILE" "Добавлен IP $ip в набор $ipset_name"
      fi
    fi
  done
done

if $update_success; then
  if ipset save | tee "$IPSET_CONF" > /dev/null; then
    log_to "$LOGFILE" "Изменения сохранены в $IPSET_CONF"
    send_telegram "[$host] SUCCESS:
Список IP для хоста $DNS_RECORD обновлен.
Было: ${OLD_IPS[*]:-—}
Стало: ${NEW_IPS[*]}"
    printf '%s\n' "${NEW_IPS[@]}" > "$OLD_IP_FILE"
  else
    log_to "$LOGFILE" "Ошибка при сохранении конфигурации ipset"
    send_telegram "[$host] ERROR: Ошибка при сохранении конфигурации ipset"
  fi
else
  log_to "$LOGFILE" "Произошли ошибки при обновлении наборов ipset"
  send_telegram "[$host] ERROR:
Ошибка при обновлении IP в наборах ipset для хоста $DNS_RECORD.
Было: ${OLD_IPS[*]:-—}
Стало: ${NEW_IPS[*]}"
fi