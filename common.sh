#!/bin/bash
# Shared lib: .env load, logging, Telegram, DNS resolve. Use: source "$SCRIPT_DIR/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- .env ---
load_env() {
  local ENV_LOADED=
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
}

# --- Logging: log_to "$LOGFILE" "message" ---
log_to() {
  local f=$1
  shift
  echo "$(date): $*" >> "$f"
}

# --- Telegram: send_telegram "message" ---
send_telegram() {
  "${TGBOT:-:}" "$1"
}

# DNS: resolve A records to valid IPv4 (exclude 127.x, validate octets).
# Drops any IP listed in DNS_IGNORE_IPS (space-separated). Sets global NEW_IPS.
get_dns_ips() {
  local record="${1:-}"
  NEW_IPS=()
  [ -z "$record" ] && return 1
  local raw
  raw=($(dig +short "$record" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true))
  local ip
  for ip in "${raw[@]}"; do
    [[ -z "$ip" ]] && continue
    [[ "$ip" =~ ^127\. ]] && continue
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ! [[ $(echo "$ip" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255') ]]; then
      continue
    fi
    NEW_IPS+=("$ip")
  done
  # Filter out ignored IPs (e.g. CDN/proxy that must not be allowed)
  if [ -n "${DNS_IGNORE_IPS:-}" ]; then
    read -ra IGNORE_ARR <<< "$DNS_IGNORE_IPS"
    local filtered=()
    local skip
    for ip in "${NEW_IPS[@]}"; do
      skip=
      for ig in "${IGNORE_ARR[@]}"; do
        [[ "$ip" == "$ig" ]] && { skip=1; break; }
      done
      [[ -z "$skip" ]] && filtered+=("$ip")
    done
    NEW_IPS=("${filtered[@]}")
  fi
  [ ${#NEW_IPS[@]} -gt 0 ]
}
