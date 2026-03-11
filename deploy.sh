#!/bin/bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Require .env before any deploy steps
if [ ! -f ".env" ]; then
  echo "Ошибка: файл .env не найден." >&2
  echo "Скопируйте .env_example в .env, заполните переменные и запустите deploy снова." >&2
  echo "Деплой остановлен." >&2
  exit 1
fi
set -a && source .env && set +a

INSTALL_DIR="/usr/local/bin/addip-to-ipset_nginx"

echo ""
echo "  deploy · addip-to-ipset_nginx"
echo "  ─────────────────────────────"

# Collect unique directories from paths in .env
dirs_to_create=()
log_dirs=()
for var in IPSET_LOGFILE OLD_IP_FILE IPSET_CONF NGINX_LOGFILE nginx_conf TGBOT; do
  val="${!var:-}"
  [ -z "$val" ] && continue
  dir="$(dirname "$val")"
  dirs_to_create+=("$dir")
  case "$var" in
    IPSET_LOGFILE|NGINX_LOGFILE) log_dirs+=("$dir") ;;
  esac
done

created_dirs=0
for dir in $(printf '%s\n' "${dirs_to_create[@]}" | sort -u); do
  if [ ! -d "$dir" ]; then
    if [ ! -w "$(dirname "$dir")" ] 2>/dev/null; then
      sudo mkdir -p "$dir" || { echo "Ошибка создания $dir" >&2; exit 1; }
    else
      mkdir -p "$dir" || { echo "Ошибка создания $dir" >&2; exit 1; }
    fi
    echo "  dir    $dir"
    created_dirs=$((created_dirs + 1))
  fi
done
[ "$created_dirs" -eq 0 ] && [ ${#dirs_to_create[@]} -gt 0 ] && echo "  dir    все каталоги на месте"

# Log dirs: owner = current user, chmod 755 (cron user can write log files)
for dir in $(printf '%s\n' "${log_dirs[@]}" | sort -u); do
  [ -d "$dir" ] || continue
  if [ -w "$dir" ]; then
    chmod 755 "$dir" 2>/dev/null || true
  else
    sudo chown "$USER:$(id -gn)" "$dir" 2>/dev/null
    sudo chmod 755 "$dir" 2>/dev/null || true
  fi
done

if ! command -v ipset &>/dev/null; then
  echo ""; echo "Ошибка: ipset не найден (apt install ipset / yum install ipset)." >&2
  exit 1
fi
echo "  ipset  найден"

if [ -n "${IPSET_LISTS:-}" ]; then
  read -ra IPSET_LISTS_ARR <<< "$IPSET_LISTS"
  if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: для создания наборов ipset нужен root (sudo $0)." >&2
    exit 1
  fi
  for name in "${IPSET_LISTS_ARR[@]}"; do
    [ -z "$name" ] && continue
    if ipset list -n 2>/dev/null | grep -qFx "$name"; then
      echo "  set    $name (есть)"
    else
      if ipset create "$name" hash:ip 2>/dev/null; then
        echo "  set    $name (создан)"
      else
        echo "Ошибка: не удалось создать набор $name (нужен root)." >&2
        exit 1
      fi
    fi
  done
  if [ -n "${IPSET_CONF:-}" ]; then
    dir_conf="$(dirname "$IPSET_CONF")"
    if [ -d "$dir_conf" ] && [ -w "$dir_conf" ]; then
      ipset save | tee "$IPSET_CONF" >/dev/null && echo "  ipset  конфиг сохранён" || echo "  ipset  не удалось сохранить конфиг" >&2
    fi
  fi
fi

echo "  install $INSTALL_DIR"
if [ ! -w "$(dirname "$INSTALL_DIR")" ] 2>/dev/null; then
  NEED_SUDO=1
else
  NEED_SUDO=0
fi

if [ "$NEED_SUDO" -eq 1 ]; then
  sudo mkdir -p "$INSTALL_DIR" || { echo "Ошибка создания $INSTALL_DIR" >&2; exit 1; }
  sudo chown "$USER:$(id -gn)" "$INSTALL_DIR"
else
  mkdir -p "$INSTALL_DIR" || { echo "Ошибка создания $INSTALL_DIR" >&2; exit 1; }
fi

for f in add_ip_to_ipset.sh add_ip_to_nginx.sh send_tg.sh .env; do
  if [ ! -f "$SCRIPT_DIR/$f" ]; then
    continue
  fi
  if [ "$NEED_SUDO" -eq 1 ]; then
    sudo cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
    sudo chown "$USER:$(id -gn)" "$INSTALL_DIR/$f"
  else
    cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
  fi
  echo "  copy   $f"
done

chmod 600 "$SCRIPT_DIR/.env" 2>/dev/null || true

if [ -f "$INSTALL_DIR/.env" ]; then
  if [ "$NEED_SUDO" -eq 1 ]; then
    sudo chmod 600 "$INSTALL_DIR/.env"
  else
    chmod 600 "$INSTALL_DIR/.env"
  fi
  if [ -f "$INSTALL_DIR/send_tg.sh" ] && command -v sed &>/dev/null; then
    if [ "$NEED_SUDO" -eq 1 ]; then
      sudo sed -i "s|^TGBOT=.*|TGBOT=$INSTALL_DIR/send_tg.sh|" "$INSTALL_DIR/.env"
    else
      sed -i "s|^TGBOT=.*|TGBOT=$INSTALL_DIR/send_tg.sh|" "$INSTALL_DIR/.env"
    fi
  fi
fi

for f in add_ip_to_ipset.sh add_ip_to_nginx.sh send_tg.sh; do
  if [ -f "$INSTALL_DIR/$f" ]; then
    [ "$NEED_SUDO" -eq 1 ] && sudo chmod +x "$INSTALL_DIR/$f" || chmod +x "$INSTALL_DIR/$f"
  fi
done

CRON1="*/5 * * * * $INSTALL_DIR/add_ip_to_ipset.sh"
CRON2="*/5 * * * * $INSTALL_DIR/add_ip_to_nginx.sh"
NEW_LINES="$CRON1
$CRON2"
CURRENT=$(crontab -l 2>/dev/null) || true
if echo "$CURRENT" | grep -qF "$INSTALL_DIR/add_ip_to_ipset.sh"; then
  echo "  cron   уже добавлен (каждые 5 мин)"
else
  (echo "$CURRENT"; echo "$NEW_LINES") | crontab -
  echo "  cron   добавлен, каждые 5 мин"
fi

echo "  ─────────────────────────────"
echo "  Скрипты: $INSTALL_DIR"
echo "  .env: chmod 600 (владелец/root)"
echo ""
