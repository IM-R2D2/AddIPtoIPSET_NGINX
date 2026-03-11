#!/bin/bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env
if [ ! -f ".env" ]; then
  echo "Ошибка: файл .env не найден. Скопируйте .env_example в .env и заполните переменные." >&2
  exit 1
fi
set -a && source .env && set +a

echo "=== Проверка и создание директорий ==="

# Collect unique directories from paths in .env
dirs_to_create=()
for var in IPSET_LOGFILE OLD_IP_FILE IPSET_CONF NGINX_LOGFILE nginx_conf TGBOT; do
  val="${!var:-}"
  [ -z "$val" ] && continue
  dir="$(dirname "$val")"
  dirs_to_create+=("$dir")
done

# Create directories (no duplicates)
for dir in $(printf '%s\n' "${dirs_to_create[@]}" | sort -u); do
  if [ ! -d "$dir" ]; then
    echo "  Создаю: $dir"
    mkdir -p "$dir" || { echo "Ошибка создания $dir" >&2; exit 1; }
  else
    echo "  OK: $dir"
  fi
done

echo ""
echo "=== Проверка ipset ==="

if ! command -v ipset &>/dev/null; then
  echo "Ошибка: ipset не найден. Установите пакет ipset (apt install ipset / yum install ipset)." >&2
  echo "Скрипты add_ip_to_ipset.sh не смогут выполняться без ipset." >&2
  exit 1
fi
echo "  OK: ipset установлен"

# Check/create ipset lists (only if variables are set)
if [ -n "${IPSET_LISTS:-}" ]; then
  read -ra IPSET_LISTS_ARR <<< "$IPSET_LISTS"
  echo ""
  echo "=== Проверка списков ipset (IPSET_LISTS) ==="

  if [ "$EUID" -ne 0 ]; then
    echo "Внимание: создание наборов ipset требует root. Запустите: sudo $0" >&2
    exit 1
  fi

  for name in "${IPSET_LISTS_ARR[@]}"; do
    [ -z "$name" ] && continue
    if ipset list -n 2>/dev/null | grep -qFx "$name"; then
      echo "  OK: набор [$name] существует"
    else
      echo "  Создаю набор: $name (hash:ip)"
      if ipset create "$name" hash:ip 2>/dev/null; then
        echo "  Создан: $name"
      else
        echo "Ошибка: не удалось создать набор [$name]. Проверьте права (нужен root)." >&2
        exit 1
      fi
    fi
  done

  if [ -n "${IPSET_CONF:-}" ]; then
    dir_conf="$(dirname "$IPSET_CONF")"
    if [ -d "$dir_conf" ] && [ -w "$dir_conf" ]; then
      echo ""
      echo "Сохранение конфигурации ipset в $IPSET_CONF"
      ipset save | tee "$IPSET_CONF" >/dev/null && echo "  OK" || echo "  Предупреждение: не удалось сохранить в $IPSET_CONF" >&2
    fi
  fi
fi

# Install to /usr/local/bin/addip-to-ipset_nginx and add cron
INSTALL_DIR="/usr/local/bin/addip-to-ipset_nginx"
echo ""
echo "=== Установка в $INSTALL_DIR ==="

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
    echo "  Пропуск (нет файла): $f"
    continue
  fi
  if [ "$NEED_SUDO" -eq 1 ]; then
    sudo cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
    sudo chown "$USER:$(id -gn)" "$INSTALL_DIR/$f"
  else
    cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
  fi
  echo "  Скопирован: $f"
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

echo ""
echo "=== Cron (каждые 5 минут) ==="

CRON1="*/5 * * * * $INSTALL_DIR/add_ip_to_ipset.sh"
CRON2="*/5 * * * * $INSTALL_DIR/add_ip_to_nginx.sh"
NEW_LINES="$CRON1
$CRON2"
CURRENT=$(crontab -l 2>/dev/null) || true
if echo "$CURRENT" | grep -qF "$INSTALL_DIR/add_ip_to_ipset.sh"; then
  echo "  Задания для $INSTALL_DIR уже есть в crontab."
else
  (echo "$CURRENT"; echo "$NEW_LINES") | crontab -
  echo "  Добавлены задания:"
  echo "    $CRON1"
  echo "    $CRON2"
fi

echo ""
echo "=== Готово ==="
echo "  Скрипты: $INSTALL_DIR"
echo "  .env: только владелец и root (chmod 600)"
echo "  Cron: crontab -l"
