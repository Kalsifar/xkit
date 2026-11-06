#!/bin/bash
#==============================================================================
#  XRAY MESH MANAGER  v3.2.1
#  Мастер-узел: nginx (TLS, скрытие) + 3X-UI + группы выхода на удалённых нодах
#
#  Архитектура:
#   [клиент] --TLS 443--> [nginx мастер-узла] --127.0.0.1--> [xmesh@группа]
#                                                          или [3X-UI inbound]
#   [xmesh@группа] --VLESS+Reality--> [нода: xray, выход в интернет]
#
#  Ключевые принципы:
#   - "Группа = страна = один вход": выходной IP пользователя НЕ меняется сам
#     (sticky). Переключение ноды происходит ТОЛЬКО при смерти ноды (failover),
#     с гистерезисом; авто-ротация внутри группы стран запрещена.
#   - Панель 3X-UI отвечает только за пользователей/подписки прямого выхода.
#     Слой нод живёт в ОТДЕЛЬНЫХ xray-инстансах (xmesh@<группа>) и в панельных
#     рестартах не участвует: перезапуск ядра панели соединения нод не рвёт.
#   - Демон xmesh-watch мониторит ноды (TCP + глубокая проверка выхода через
#     socks-пробу) и при смерти ноды переключает группу на резерв той же
#     группы. Рестарт затрагивает только один маленький инстанс одной группы.
#   - Подписки генерирует сам скрипт и раздаёт через nginx (/sub/<токен>),
#     поэтому ссылки всегда корректны (через 443, с реальными путями).
#
#  Запуск:  bash xray-mesh.sh           - меню
#           bash xray-mesh.sh --selftest - самопроверка валидаторов и сборщиков
#
#  ИЗМЕНЕНИЯ v3.1 (аудит №2 от xkit-команды):
#   - full_install: дефолтный сайт nginx (sites-enabled/default) сносится только
#     ПОСЛЕ успешного nginx -t + restart — при ошибке конфига nginx больше не
#     остаётся без единого server{} на хосте
#   - backup_create: проверка tar exit-code + размера + `tar tzf`; битые/пустые
#     архивы удаляются, а не отдаются как «успешный бэкап»
#   - установщик 3X-UI: mktemp вместо фикс-пути в /tmp
#
#  ИЗМЕНЕНИЯ v3.2 (аудит №3 + Xkit v4.6):
#   - БЕЗОПАСНОСТЬ: TCP-пробы /dev/tcp переведены на безопасный
#     bash -c '..."$1"...' _ host port — хост/порт больше не интерполируются в
#     командную строку (инъекция при ручной правке JSON ноды)
#   - node_add: SSH-пользователь валидируется ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ —
#     кавычка/пробел в sshuser больше не ломают JSON реестра (писался printf'ом)
#   - EOF в меню больше не валит скрипт с set -u (unbound variable): все меню и
#     критичные вводы обрабатывают неудачу read (Ctrl-D — чистый выход/отмена)
#   - install_self: успех cp/chmod проверяется — «доступен командой xray-mesh»
#     печатается только при реальной установке
#   - backup_restore: архив проверяется на ../ и абсолютные пути до tar xzf;
#     распаковка с --no-same-owner --no-overwrite-dir — владельцы/права
#     существующих каталогов не тащатся из архива (сужение поверхности)
#   - node_add: EOF (Ctrl-D) на вводах с дефолтом (SSH-порт/пользователь,
#     Reality-порт, SNI) — отмена, а не молчаливое продолжение с дефолтом
#   - мёртвая функция xray_test_config удалена (тест встроен в group_apply);
#     read -p везде с -r; в xmesh-watch имена local_g/local_gj -> watch_g/watch_gj
#     (это глобальные переменные демона, «local-» вводил в заблуждение);
#     в install_3xui задокументирован осознанный отказ от XUI_NONINTERACTIVE
#
#  ИЗМЕНЕНИЯ v3.2.1 (ревью UX v4.7):
#   - deps_install со спиннером: apt-get update/install больше не «молчат»
#     20-40 секунд (спиннер только при живом терминале; XMESH_NO_ANIM=1 —
#     отключить; при не-TTY вывод команды проходит как есть)
#==============================================================================

set -u -o pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK]   $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err()  { echo -e "${RED}[ERR ] $*${NC}" >&2; }
die()  { err "$*"; exit 1; }
hr()   { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }

CERTBOT_MIN_IP="5.3"   # минимальная версия certbot для --ip-address

#=========================== ПУТИ =============================================
XMESH_DIR="/etc/xmesh"
XMESH_ENV="$XMESH_DIR/xmesh.env"
XMESH_SSH_DIR="$XMESH_DIR/ssh"
XMESH_NODES_DIR="$XMESH_DIR/nodes"
XMESH_GROUPS_DIR="$XMESH_DIR/groups"     # <имя>.json + <имя>.clients.json + <имя>/config.json
XMESH_USERS_DIR="$XMESH_DIR/users"
XMESH_SUBS_DIR="/var/www/xmesh-subs"
XMESH_LIB_DIR="/var/lib/xmesh"
XMESH_STATE="$XMESH_LIB_DIR/state.env"
PANEL_COOKIE="/etc/xmesh/.panel.cookie"
ROUTER_XRAY="/usr/local/bin/xray"
WATCH_BIN="/usr/local/bin/xmesh-watch"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

#=========================== ВАЛИДАЦИЯ ВВОДА ==================================
is_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] || return 1
  # TLD должен содержать букву: иначе "999.999.999.999" проходит как домен
  [[ "${1##*.}" =~ [a-zA-Z] ]]
}

is_ipv4() {
  local ip="$1" IFS='.' o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for o in $ip; do [ "$((10#$o))" -le 255 ] || return 1; done
  return 0
}

is_ipv6() {
  [[ "$1" =~ ^[0-9a-fA-F:]{2,45}$ ]] && [[ "$1" == *:* ]]
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$1" != *"//"* ]]
}

# имя файла/группы/ноды: только безопасные символы (защита от ../ и инъекций)
safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }

is_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

host_kind() { if is_ip "$1"; then echo "ip"; else echo "domain"; fi }

read_host() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_domain "$v" || is_ip "$v"; then printf '%s' "$v"; return 0; fi
    err "Некорректно: '$v'. Нужен домен или IP — без http://, без путей, без портов"
  done
}

read_port() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_port "$v"; then printf '%s' "$v"; return 0; fi
    err "Порт должен быть числом 1-65535"
  done
}

read_path() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_path "$v"; then printf '%s' "$v"; return 0; fi
    err "Путь должен начинаться с / и содержать только буквы, цифры и . _ ~ / - (без пробелов)"
  done
}

read_name() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if safe_name "$v"; then printf '%s' "$v"; return 0; fi
    err "Имя: 1-32 символа, буквы/цифры/. _ - , начинается с буквы или цифры"
  done
}

read_secret() {
  local prompt="$1" v=""
  read -r -s -p "$prompt" v || die "Ввод прерван"
  echo >&2
  printf '%s' "$v"
}

gen_uuid() {
  if [ -x "$ROUTER_XRAY" ]; then "$ROUTER_XRAY" uuid 2>/dev/null && return 0; fi
  cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || die "Не удалось сгенерировать UUID"
}

gen_hex() { openssl rand -hex "$1" 2>/dev/null || die "openssl недоступен"; }

urienc() { jq -rn --arg s "$1" '$s|@uri'; }

#=========================== ENV-ФАЙЛ /etc/xmesh/xmesh.env ====================
env_get() {
  [ -f "$XMESH_ENV" ] || return 0
  grep "^$1=" "$XMESH_ENV" 2>/dev/null | head -n1 | cut -d= -f2-
}

env_set() {
  local k="$1" v="$2" f="$XMESH_ENV" tmp
  mkdir -p "$XMESH_DIR"; touch "$f"; chmod 600 "$f"
  tmp="${f}.tmp.$$"
  awk -F= -v k="$k" -v v="$v" 'BEGIN{fnd=0} $1==k{print k"="v; fnd=1; next} {print} END{if(!fnd) print k"="v}' "$f" > "$tmp" \
    && mv "$tmp" "$f"
}

# пароль панели храним в base64 (в env нельзя безопасно класть произвольные символы)
env_set_secret() { env_set "$1" "$(printf '%s' "$2" | base64 -w0)"; }
env_get_secret() { local v; v=$(env_get "$1"); [ -n "$v" ] && printf '%s' "$v" | base64 -d; }

#=========================== ХЕЛПЕРЫ NGINX ====================================
nginx_ver() { nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p'; }

# ver_ge A B — истина, если версия A >= B
ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# блок listen 443 с корректным синтаксисом http2 под версию nginx
build_h2_block() {
  local ver
  ver=$(nginx_ver)
  if [ -n "$ver" ] && ver_ge "$ver" "1.25.1"; then
    printf '    listen 443 ssl;\n    http2 on;'
  else
    printf '    listen 443 ssl http2;'
  fi
}

backup_file() {
  local f="$1" b
  [ -f "$f" ] || return 0
  b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$b" && ok "Бэкап: $b"
  return 0
}

# nginx -t + reload; при ошибке — реальный откат к последнему бэкапу
apply_config() {
  local f="$1" out b
  if out=$(nginx -t 2>&1); then
    if systemctl reload nginx >/dev/null 2>&1; then ok "Nginx перезагружен"; return 0; fi
    if systemctl start nginx >/dev/null 2>&1; then ok "Nginx запущен"; return 0; fi
    err "nginx -t прошёл, но перезапустить nginx не удалось"; return 1
  fi
  err "nginx -t не прошёл:"
  echo "$out" | sed 's/^/    /' >&2
  b=$(ls -1t "${f}".bak.* 2>/dev/null | head -n1)
  if [ -n "$b" ]; then
    warn "Откатываю конфиг к последнему бэкапу: $b"
    cp -a "$b" "$f"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
      ok "Откат выполнен — nginx работает на старом конфиге"
    else
      warn "Откат тоже битый — правьте вручную: $f"
    fi
  else
    warn "Бэкапа нет — конфиг оставлен как есть, чините вручную: $f"
  fi
  return 1
}

# вставка произвольного блока в server{...} перед закрывающей скобкой
nginx_insert_block() {
  local f="$1" block="$2"
  [ "$(wc -l < "$f")" -ge 2 ] || { err "Конфиг $f слишком короткий/пустой — не трогаю"; return 1; }
  sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$f"   # срезать хвостовые пустые строки
  [ "$(tail -n 1 "$f" | xargs)" = "}" ] || { err "Конфиг $f не заканчивается на '}' — не трогаю"; return 1; }
  { head -n -1 "$f"; printf '%s\n' "$block"; echo "}"; } > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# удаление блока по маркерам # XMESH:<marker>:BEGIN ... # XMESH:<marker>:END
nginx_remove_marker() {
  local f="$1" marker="$2"
  sed -i "/# XMESH:${marker}:BEGIN/,/# XMESH:${marker}:END/d" "$f"
  sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$f"
}

#=========================== СЕРТИФИКАТЫ (из v2.1) ============================
certbot_version() { certbot --version 2>&1 | awk '{print $2}'; }
certbot_supports_ip() { ver_ge "$(certbot_version)" "$CERTBOT_MIN_IP"; }

install_renew_hooks() {
  mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
  cat > /etc/letsencrypt/renewal-hooks/pre/xray-nginx.sh <<'EOF'
#!/bin/bash
# Standalone-аутентификации нужен порт 80 — останавливаем nginx
systemctl stop nginx.service 2>/dev/null || true
EOF
  cat > /etc/letsencrypt/renewal-hooks/post/xray-nginx.sh <<'EOF'
#!/bin/bash
systemctl start nginx.service 2>/dev/null || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/pre/xray-nginx.sh \
           /etc/letsencrypt/renewal-hooks/post/xray-nginx.sh
}

certbot_upgrade() {
  log "Ставлю certbot в /opt/certbot-venv через pip..."
  apt-get install -y -qq python3-venv python3-pip >/dev/null 2>&1 || true
  python3 -m venv /opt/certbot-venv 2>/dev/null || return 1
  /opt/certbot-venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
  /opt/certbot-venv/bin/pip install -q certbot >/dev/null 2>&1 || return 1
  ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
  if [ -d /etc/systemd/system ]; then
    mkdir -p /etc/systemd/system/certbot.service.d
    cat > /etc/systemd/system/certbot.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/opt/certbot-venv/bin/certbot -q renew
EOF
    systemctl daemon-reload 2>/dev/null || true
  fi
  hash -r
  return 0
}

le_email_args() {
  local email="$1"
  if [ -n "$email" ]; then
    printf '%s\n' "--email" "$email" "--no-eff-email"
  else
    printf '%s\n' "--register-unsafely-without-email"
  fi
}

issue_cert_le_domain() {
  local d="$1" email="$2" rc=0 extra=()
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить сертификат (nginx снова запущен). Проверьте A-запись и открытый порт 80."
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$d/"
  return 0
}

issue_cert_le_ip() {
  local ip="$1" email="$2" rc=0 extra=()
  if ! certbot_supports_ip; then
    warn "Установленный certbot $(certbot_version) не умеет IP-сертификаты (нужно >= ${CERTBOT_MIN_IP})"
    read -r -p "Обновить certbot автоматически через pip/venv? [y/N]: " a
    if [[ "$a" =~ ^[Yy] ]]; then
      certbot_upgrade || { err "Обновление не удалось — используйте самоподписанный вариант"; return 1; }
      ok "certbot обновлён: $(certbot_version)"
    else
      warn "Используйте самоподписанный вариант или обновите certbot вручную"
      return 1
    fi
  fi
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone --ip-address "$ip" --preferred-profile shortlived \
    --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить IP-сертификат (nginx снова запущен). Проверьте, что это IP данного сервера и порт 80 доступен извне."
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$ip/"
  warn "IP-сертификат shortlived действует 6 ДНЕЙ — продление уже настроено (certbot.timer + hooks)"
  return 0
}

issue_cert_selfsigned() {
  local h="$1" kind="$2" dest="/etc/nginx/ssl/$h" san
  if [ "$kind" = "ip" ]; then san="IP:$h"; else san="DNS:$h"; fi
  mkdir -p "$dest"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dest/privkey.pem" -out "$dest/fullchain.pem" \
    -days 3650 -subj "/CN=$h" -addext "subjectAltName=$san" 2>/dev/null \
    || { err "openssl не смог создать сертификат"; return 1; }
  chmod 700 "$dest"
  chmod 600 "$dest/privkey.pem"
  chmod 644 "$dest/fullchain.pem"
  warn "Самоподписанный сертификат (10 лет): на клиентах allowInsecure=true"
  return 0
}

install_cert_files() {
  local h="$1" src="/root/cert/$h" dest="/etc/nginx/ssl/$h"
  if [ ! -f "$src/fullchain.pem" ] || [ ! -f "$src/privkey.pem" ]; then
    err "Не найдены $src/fullchain.pem и/или $src/privkey.pem"
    return 1
  fi
  mkdir -p "$dest"
  cp "$src/fullchain.pem" "$dest/fullchain.pem"
  cp "$src/privkey.pem"  "$dest/privkey.pem"
  chmod 700 "$dest"; chmod 600 "$dest/privkey.pem"; chmod 644 "$dest/fullchain.pem"
  ok "Скопировано в $dest (ключ 600, каталог 700)"
  return 0
}

#=========================== ГЕНЕРАЦИЯ LOCATION (из v2.1) =====================
generate_location_block() {
    local trans_type="$1" path_name="$2" target="$3" is_local="$4"
    local block="" domain_only=""

    if [ "$trans_type" == "1" ]; then
        block=$(cat <<BLK

    # --- gRPC (${path_name}) ---
    location ${path_name} {
        if (\$content_type !~ "application/grpc") { return 404; }
        client_max_body_size 0;
        access_log off;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
BLK
)
        if [ "$is_local" == "true" ]; then
            block+="        grpc_pass grpc://${target};
"
        else
            domain_only="${target%%:*}"
            block+="        grpc_pass grpcs://${target};
        grpc_ssl_server_name on;
        grpc_ssl_name ${domain_only};
"
        fi
        block+="    }"

    elif [ "$trans_type" == "2" ]; then
        block=$(cat <<BLK

    # --- WebSocket (${path_name}) ---
    location ${path_name} {
        if (\$http_upgrade != "websocket") { return 404; }
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
BLK
)
        if [ "$is_local" == "true" ]; then
            block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
        else
            domain_only="${target%%:*}"
            block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
        fi
        block+="    }"

    elif [ "$trans_type" == "3" ]; then
        block=$(cat <<BLK

    # --- XHTTP / SplitHTTP (${path_name}) ---
    location ${path_name} {
        client_max_body_size 0;
        access_log off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        keepalive_timeout 1h;
BLK
)
        if [ "$is_local" == "true" ]; then
            block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
        else
            domain_only="${target%%:*}"
            block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
        fi
        block+="    }"
    fi

    printf '%s' "$block"
}

#=========================== ЗАВИСИМОСТИ ======================================
ensure_dirs() {
  mkdir -p "$XMESH_DIR" "$XMESH_SSH_DIR" "$XMESH_NODES_DIR" "$XMESH_GROUPS_DIR" \
           "$XMESH_USERS_DIR" "$XMESH_SUBS_DIR" "$XMESH_LIB_DIR"
  chmod 700 "$XMESH_DIR" "$XMESH_SSH_DIR" "$XMESH_NODES_DIR" "$XMESH_GROUPS_DIR" "$XMESH_USERS_DIR"
  # S-04 (аудит №2): подписки — bearer-креды; читать должен только nginx
  chmod 750 "$XMESH_SUBS_DIR"
  chgrp www-data "$XMESH_SUBS_DIR" 2>/dev/null || true
}

deps_install() {
  log "Устанавливаю зависимости (nginx, certbot, jq, sshpass, openssl)..."
  with_spinner "apt-get update..." apt-get update -qq || warn "apt-get update вернул ошибку — продолжаю"
  with_spinner "Установка пакетов..." env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq nginx curl certbot openssl jq sshpass uuid-runtime tar ca-certificates \
    || warn "Часть пакетов могла не установиться — проверю ниже"
  local miss="" p
  for p in nginx curl certbot openssl jq sshpass tar; do
    command -v "$p" >/dev/null 2>&1 || miss+="$p "
  done
  [ -n "$miss" ] && { err "Отсутствуют: $miss — установите вручную и повторите"; return 1; }
  ok "Зависимости на месте"
  return 0
}

# спиннер для долгих операций (ревью v4.7): крутится только на живом терминале,
# иначе — прозрачный прогон (вывод команды как есть, без анимации)
with_spinner() {
  local msg="$1"; shift
  if [ ! -t 2 ] || [ "${XMESH_NO_ANIM:-0}" = "1" ]; then
    "$@"
    return $?
  fi
  local tmplog pid rc=1 i=0
  tmplog="$(mktemp /tmp/xmesh-spin.XXXXXX)" || { "$@"; return $?; }
  "$@" >"$tmplog" 2>&1 &
  pid=$!
  local marks='-\|/'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s[%s]%s %s   ' "$GREEN" "${marks:$i:1}" "$NC" "$msg" >&2
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  wait "$pid"; rc=$?
  printf '\r\033[K' >&2
  if [ $rc -eq 0 ]; then
    printf '%s[OK]%s   %s\n' "$GREEN" "$NC" "$msg" >&2
  else
    printf '%s[ERR]%s  %s\n' "$RED" "$NC" "$msg" >&2
    tail -n 20 "$tmplog" | sed 's/^/       /' >&2
  fi
  rm -f "$tmplog"
  return $rc
}

ensure_xray_binary() {
  if [ -x "$ROUTER_XRAY" ]; then ok "Xray уже установлен: $("$ROUTER_XRAY" version 2>/dev/null | head -n1)"; return 0; fi
  log "Ставлю Xray-core официальным инсталлятором..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
    || { err "Не удалось установить Xray (нет доступа к github с этого сервера?)"; return 1; }
  [ -x "$ROUTER_XRAY" ] || { err "Xray не появился в $ROUTER_XRAY"; return 1; }
  systemctl disable --now xray >/dev/null 2>&1 || true   # системный xray не нужен, у нас свои инстансы
  ok "Xray установлен: $("$ROUTER_XRAY" version 2>/dev/null | head -n1)"
  return 0
}

#=========================== 3X-UI API ========================================
# Панель используется ТОЛЬКО для прямого выхода (inbound "direct") и
# управления клиентами. Слой нод панель не трогает.
# API: POST /login, GET /panel/api/inbounds/list,
#      POST /panel/api/inbounds/add, POST /panel/api/inbounds/addClient,
#      POST /panel/api/inbounds/<id>/delClient/<uuid>

panel_creds_dialog() {
  local port user pass tries=0 resp
  hr
  echo "Нужен доступ к API панели 3X-UI (localhost)."
  read -r -p "Порт веб-панели 3X-UI (как в установщике, обычно 2053): " port
  is_port "$port" || die "Некорректный порт панели"
  read -r -p "Логин панели: " user
  [ -n "$user" ] || die "Логин обязателен"
  pass=$(read_secret "Пароль панели (скрытый ввод): ")
  [ -n "$pass" ] || die "Пароль обязателен"

  env_set PANEL_PORT "$port"; env_set PANEL_USER "$user"; env_set_secret PANEL_PASS_B64 "$pass"
  while [ $tries -lt 3 ]; do
    if panel_login; then
      ok "Вход в панель выполнен, доступ сохранён в $XMESH_ENV (600)"
      return 0
    fi
    tries=$((tries+1))
    warn "Не удалось войти (попытка $tries/3). Проверьте логин/пароль/порт."
    read -r -p "Логин панели: " user
    pass=$(read_secret "Пароль панели (скрытый ввод): ")
    env_set PANEL_USER "$user"; env_set_secret PANEL_PASS_B64 "$pass"
  done
  err "Доступ к панели не настроен. Проверьте вручную и повторите пункт настройки."
  return 1
}

panel_login() {
  local port user pass resp rt
  port=$(env_get PANEL_PORT); user=$(env_get PANEL_USER)
  pass=$(env_get_secret PANEL_PASS_B64)
  [ -n "$port" ] && [ -n "$user" ] && [ -n "$pass" ] || { err "Нет сохранённых данных панели ($XMESH_ENV)"; return 1; }
  rt="$(mktemp /tmp/.xmesh_plogin.XXXXXX)"; chmod 600 "$rt"
  # V-03 (аудит №2): пароль через stdin (--data @-), не в argv (ps/proc)
  printf 'username=%s&password=%s' \
    "$(jq -rn --arg v "$user" '$v|@uri')" "$(jq -rn --arg v "$pass" '$v|@uri')" \
  | curl -s --noproxy '*' -m 10 -c "$PANEL_COOKIE" -X POST "http://127.0.0.1:${port}/login" \
      -H 'Content-Type: application/x-www-form-urlencoded' --data @- -o "$rt" 2>/dev/null \
    || { rm -f "$rt"; return 1; }
  jq -e '.success == true' "$rt" >/dev/null 2>&1
  local rc=$?; rm -f "$rt"; return $rc
}

# panel_call METHOD PATH [JSON_BODY] — с автоперелогином
panel_call() {
  local method="$1" path="$2" body="${3:-}" port resp
  port=$(env_get PANEL_PORT)
  [ -n "$port" ] || { err "Порт панели не задан"; return 1; }
  local url="http://127.0.0.1:${port}${path}"
  if [ -n "$body" ]; then
    resp=$(printf '%s' "$body" | curl -s --noproxy '*' -m 20 -b "$PANEL_COOKIE" -X "$method" -H 'Content-Type: application/json' --data @- "$url" 2>/dev/null)
  else
    resp=$(curl -s --noproxy '*' -m 20 -b "$PANEL_COOKIE" -X "$method" "$url" 2>/dev/null)
  fi
  if ! printf '%s' "$resp" | jq -e 'has("success")' >/dev/null 2>&1; then
    panel_login || { err "Панель недоступна (нет ответа/не удалось войти)"; printf ''; return 1; }
    if [ -n "$body" ]; then
      resp=$(printf '%s' "$body" | curl -s --noproxy '*' -m 20 -b "$PANEL_COOKIE" -X "$method" -H 'Content-Type: application/json' --data @- "$url" 2>/dev/null)
    else
      resp=$(curl -s --noproxy '*' -m 20 -b "$PANEL_COOKIE" -X "$method" "$url" 2>/dev/null)
    fi
  fi
  printf '%s' "$resp"
}

panel_list_inbounds() {
  panel_call GET /panel/api/inbounds/list | jq -c '.obj[]?' 2>/dev/null
}

panel_inbound_by_remark() {
  local remark="$1"
  panel_list_inbounds | jq -c --arg r "$remark" 'select(.remark==$r)' | head -n1
}

# inbound, в котором сидит клиент с данным uuid: "<весь объект inbound>"
panel_inbound_by_client_uuid() {
  local uuid="$1" ib
  while read -r ib; do
    [ -n "$ib" ] || continue
    if jq -e --arg u "$uuid" '(.settings|fromjson|.clients // []) | map(.id) | index($u)' <<<"$ib" >/dev/null 2>&1; then
      printf '%s' "$ib"; return 0
    fi
  done < <(panel_list_inbounds)
  return 1
}

panel_add_inbound_direct() {
  local dport="$1" dpath="$2"
  if [ -n "$(panel_inbound_by_remark direct)" ]; then
    ok "Панельный inbound 'direct' уже существует"
    return 0
  fi
  log "Создаю в панели inbound 'direct' (vless+ws, 127.0.0.1:${dport}, путь ${dpath})..."
  local settings stream sniff alloc body
  settings=$(jq -nc '{clients:[],decryption:"none",fallbacks:[]}')
  stream=$(jq -nc --arg p "$dpath" '{network:"ws",security:"none",externalProxy:[],wsSettings:{acceptProxyProtocol:false,path:$p,headers:{}}}')
  sniff=$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')
  alloc=$(jq -nc '{strategy:"always",count:0}')
  body=$(jq -n --arg rem "direct" --argjson port "$dport" --arg s "$settings" --arg st "$stream" --arg sn "$sniff" --arg al "$alloc" \
    '{up:0,down:0,total:0,remark:$rem,enable:true,expiryTime:0,listen:"127.0.0.1",port:$port,protocol:"vless",settings:$s,streamSettings:$st,sniffing:$sn,allocate:$al}')
  local resp
  resp=$(panel_call POST /panel/api/inbounds/add "$body")
  if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    ok "Inbound 'direct' создан в панели"
    return 0
  fi
  err "Панель не создала inbound: $(printf '%s' "$resp" | head -c 300)"
  return 1
}

panel_add_client() {
  local inbound_id="$1" uuid="$2" email="$3"
  local subid client body resp
  subid=$(gen_hex 8)
  client=$(jq -n --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
    '{id:$id,flow:"",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,reset:0}')
  body=$(jq -n --argjson id "$inbound_id" --argjson c "$client" '{id:$id,clients:[$c]}')
  resp=$(panel_call POST /panel/api/inbounds/addClient "$body")
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1
}

panel_del_client_by_email() {
  local email="$1" ib cid iid
  while read -r ib; do
    [ -n "$ib" ] || continue
    cid=$(jq -r --arg e "$email" '(.settings|fromjson|.clients // [])[]|select(.email==$e)|.id' <<<"$ib" | head -n1)
    if [ -n "$cid" ]; then
      iid=$(jq -r '.id' <<<"$ib")
      local resp
      resp=$(panel_call POST "/panel/api/inbounds/${iid}/delClient/${cid}")
      if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
        ok "Клиент удалён из панели (inbound id=$iid)"
      else
        warn "Панель не удалила клиента (inbound id=$iid): $(printf '%s' "$resp" | head -c 200)"
      fi
      return 0
    fi
  done < <(panel_list_inbounds)
  return 1
}

#=========================== ГРУППЫ ВЫХОДА ====================================
# Группа = страна/пул нод = один вход на мастере (vless+ws на 127.0.0.1:порт,
# путь /<имя>) за nginx. Внутри группы: pin primary + failover, без авторотации.

group_file()     { printf '%s/%s.json' "$XMESH_GROUPS_DIR" "$1"; }
group_clients()  { printf '%s/%s.clients.json' "$XMESH_GROUPS_DIR" "$1"; }
group_config()   { printf '%s/%s/config.json' "$XMESH_GROUPS_DIR" "$1"; }

group_list_names() {
  local f b
  shopt -s nullglob
  for f in "$XMESH_GROUPS_DIR"/*.json; do b=$(basename "$f"); printf '%s\n' "${b%.json}"; done
}

group_count_nodes() { jq -r '.nodes|length' "$(group_file "$1")" 2>/dev/null; }

port_is_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
    return 1
  fi
  return 0
}

group_next_port() {
  local p used f b
  for p in $(seq 21001 21600); do
    used=0
    shopt -s nullglob
    for f in "$XMESH_GROUPS_DIR"/*.json; do
      b=$(basename "$f")
      [ "$p" = "$(jq -r '.listen_port' "$f" 2>/dev/null)" ] && used=1
    done
    port_is_free "$p" || used=1
    [ $used -eq 0 ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

probe_next_port() {
  local p used f
  for p in $(seq 22001 23000); do
    used=0
    shopt -s nullglob
    for f in "$XMESH_NODES_DIR"/*.json; do
      [ "$p" = "$(jq -r '.probe_port' "$f" 2>/dev/null)" ] && used=1
    done
    port_is_free "$p" || used=1
    [ $used -eq 0 ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

group_create() {
  hr
  echo "Создание группы выхода (страна/пул нод)"
  hr
  local name country port
  name=$(read_name "Имя группы (латиницей, напр. de): ")
  [ -f "$(group_file "$name")" ] && { err "Группа '$name' уже существует"; return 1; }
  read -r -p "Подпись для клиентов (напр. Германия): " country
  [ -n "$country" ] || country="$name"
  port=$(group_next_port) || die "Нет свободных портов 21001-21600"
  jq -nc --arg n "$name" --arg c "$country" --argjson p "$port" --arg path "/$name" \
    '{name:$n,country:$c,listen_port:$p,ws_path:$path,primary:"",nodes:[],revert:true}' \
    > "$(group_file "$name")"
  chmod 600 "$(group_file "$name")"
  printf '[]\n' > "$(group_clients "$name")"
  chmod 600 "$(group_clients "$name")"
  mkdir -p "$XMESH_GROUPS_DIR/$name"
  ok "Группа '$name' создана: вход 127.0.0.1:${port}, путь WS /$name"
  read -r -p "Добавить ноду в группу сейчас? [Y/n]: " a
  if [[ ! "$a" =~ ^[Nn] ]]; then
    node_add "$name"
  else
    group_rebuild "$name"
    nginx_ensure_group_location "$name" || true
  fi
  return 0
}

group_delete() {
  local name
  name=$(read_name "Имя группы для удаления: ")
  [ -f "$(group_file "$name")" ] || { err "Группа не найдена"; return 1; }
  read -r -p "Удалить группу '$name' вместе с конфигом nginx-локейшена? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || { log "Отменено"; return 0; }
  systemctl stop "xmesh@${name}.service" 2>/dev/null || true
  systemctl disable "xmesh@${name}.service" 2>/dev/null || true
  local conf; conf=$(env_get MASTER_CONF)
  if [ -n "$conf" ] && [ -f "$conf" ]; then
    backup_file "$conf"
    nginx_remove_marker "$conf" "g-${name}"
    apply_config "$conf" >/dev/null 2>&1 || true
  fi
  rm -rf "$(group_file "$name")" "$(group_clients "$name")" "$XMESH_GROUPS_DIR/$name"
  # чистим ACTIVE из state
  [ -f "$XMESH_STATE" ] && sed -i "/^ACTIVE_${name}=/d" "$XMESH_STATE"
  ok "Группа '$name' удалена"
}

# активная нода группы: state -> primary -> "" (block)
group_active_node() {
  local g="$1" a
  a=$(state_get "ACTIVE_${g}")
  if [ -z "$a" ]; then a=$(jq -r '.primary // ""' "$(group_file "$g")" 2>/dev/null); fi
  printf '%s' "$a"
}

#=========================== СБОРКА КОНФИГА ГРУППЫ ============================
# Один xray-инстанс на группу (systemd: xmesh@<имя>):
#   inbound  in-<g>   vless+ws 127.0.0.1:<port> путь /<g> — клиенты (за nginx)
#   inbound  probe-<n> socks5 127.0.0.1:<probe_port> — проверка выхода ноды
#   outbound block (первый = дефолт: никакой трафик не утечёт с IP мастера)
#   outbound out-<n>  vless+reality -> нода
#   правила: probe-<n> -> out-<n>; in-<g> -> out-<active>; всё прочее -> block
build_group_config() {
  local g="$1" active="__auto__"
  [ $# -ge 2 ] && active="$2"
  local gj cf; gj=$(group_file "$g")
  [ -f "$gj" ] || { err "Группа $g не найдена"; return 1; }
  if [ "$active" = "__auto__" ]; then active=$(group_active_node "$g"); fi

  local port wspath
  port=$(jq -r '.listen_port' "$gj")
  wspath=$(jq -r '.ws_path' "$gj")

  local tmpd; tmpd=$(mktemp -d /tmp/xmesh-cfg.XXXXXX)
  local outf=() pinf=() rul=() f i=0
  shopt -s nullglob

  local node name
  while read -r node; do
    [ -n "$node" ] || continue
    local nj="$XMESH_NODES_DIR/$node.json"
    if [ ! -f "$nj" ]; then warn "Нода '$node' не найдена — пропущена"; continue; fi
    local host rport uuid pbk sid sni probe_port
    host=$(jq -r '.host' "$nj"); rport=$(jq -r '.port' "$nj")
    uuid=$(jq -r '.uuid' "$nj"); pbk=$(jq -r '.pubkey' "$nj")
    sid=$(jq -r '.short_id' "$nj"); sni=$(jq -r '.sni' "$nj")
    probe_port=$(jq -r '.probe_port' "$nj")

    jq -n --arg tag "out-${node}" --arg addr "$host" --argjson port "$rport" --arg uuid "$uuid" \
         --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" '{
      tag: $tag, protocol: "vless", mux: {enabled: false},
      settings: {vnext: [{address: $addr, port: $port,
        users: [{id: $uuid, encryption: "none", level: 0}]}]},
      streamSettings: {network: "tcp", security: "reality",
        realitySettings: {show: false, serverName: $sni, publicKey: $pbk,
          shortId: $sid, fingerprint: "chrome", spiderX: "/"}}
    }' > "$tmpd/out.$i"

    jq -n --arg tag "probe-${node}" --argjson port "$probe_port" '{
      tag: $tag, listen: "127.0.0.1", port: $port, protocol: "socks",
      settings: {auth: "noauth", udp: false}
    }' > "$tmpd/pin.$i"

    jq -n --arg tag "probe-${node}" --arg out "out-${node}" \
      '{inboundTag: [$tag], outboundTag: $out}' > "$tmpd/rule.$i"

    i=$((i+1))
  done < <(jq -r '.nodes[]' "$gj" 2>/dev/null)

  # основной inbound группы с клиентами
  local clients_json="[]"
  if [ -f "$(group_clients "$g")" ]; then
    clients_json=$(jq -c '.' "$(group_clients "$g")" 2>/dev/null || printf '[]')
  fi
  jq -n --arg tag "in-${g}" --argjson port "$port" --arg path "$wspath" --argjson clients "$clients_json" '{
    tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
    settings: {clients: $clients, decryption: "none"},
    streamSettings: {network: "ws", security: "none",
      wsSettings: {acceptProxyProtocol: false, path: $path, headers: {}}},
    sniffing: {enabled: true, destOverride: ["http", "tls"]}
  }' > "$tmpd/main_in"

  # правило группы: вход -> активная нода (или block, если активной нет)
  # №3 (аудит №1): ACTIVE_<g> может указывать на УДАЛЁННУЮ ноду — раньше
  # собирали правило на несуществующий out-тег и получали отказ apply без
  # понятной причины. Ноды нет — честно уводим группу в block
  local out_tag="block"
  if [ -n "$active" ] && [ -f "$XMESH_NODES_DIR/$active.json" ]; then
    out_tag="out-${active}"
  elif [ -n "$active" ]; then
    warn "ACTIVE_${g}=${active} не найдена в реестре — правило in-${g} -> block"
  fi
  jq -n --arg tag "in-${g}" --arg out "$out_tag" \
    '{inboundTag: [$tag], outboundTag: $out}' > "$tmpd/rule.main"

  # склейка
  for f in "$tmpd"/out.*;  do outf+=("$f"); done
  for f in "$tmpd"/pin.*;  do pinf+=("$f"); done
  for f in "$tmpd"/rule.*; do rul+=("$f");  done

  local outb_json pin_json rul_json
  if [ ${#outf[@]} -gt 0 ]; then outb_json=$(jq -s '.' "${outf[@]}"); else outb_json='[]'; fi
  if [ ${#pinf[@]} -gt 0 ]; then pin_json=$(jq -s '.' "${pinf[@]}"); else pin_json='[]'; fi
  if [ ${#rul[@]}  -gt 0 ]; then rul_json=$(jq -s '.' "${rul[@]}");  else rul_json='[]'; fi

  # block — ПЕРВЫЙ outbound: дефолт для неразобранного трафика = чёрная дыра
  local inb_json ob_json
  ob_json=$(jq -n --argjson block '[{"tag":"block","protocol":"blackhole","settings":{"response":{"type":"none"}}}]' \
    --argjson rest "$outb_json" '$block + $rest')
  inb_json=$(jq -s '.' "$tmpd/main_in" ${pinf[@]+"${pinf[@]}"})

  jq -n --argjson log '{"loglevel":"warning"}' --argjson inbounds "$inb_json" \
       --argjson outbounds "$ob_json" --argjson rules "$rul_json" \
    '{log: $log, inbounds: $inbounds, outbounds: $outbounds,
      routing: {domainStrategy: "AsIs", rules: $rules}}'
  local rc=$?
  rm -rf "$tmpd"
  return $rc
}

# (мёртвая функция xray_test_config удалена в v3.2: тест конфига встроен в
#  group_apply — двойных реализаций не оставляем)

group_apply() {  # group_apply <g> [active] — собрал, проверил, атомарно записал, рестартнул
  local g="$1" active="__auto__" cfg newcfg dir
  [ $# -ge 2 ] && active="$2"
  safe_name "$g" || { err "Некорректное имя группы: $g"; return 1; }
  cfg=$(group_config "$g"); dir=$(dirname "$cfg")
  mkdir -p "$dir"
  newcfg=$(build_group_config "$g" "$active") || return 1
  printf '%s\n' "$newcfg" > "${cfg}.new"
  if [ -x "$ROUTER_XRAY" ]; then
    if ! "$ROUTER_XRAY" run -test -c "${cfg}.new" >/dev/null 2>&1 \
       && ! "$ROUTER_XRAY" -test -config="${cfg}.new" >/dev/null 2>&1; then
      err "Собранный конфиг группы '$g' не прошёл xray -test:"
      "$ROUTER_XRAY" run -test -c "${cfg}.new" 2>&1 | tail -n5 | sed 's/^/    /' >&2
      rm -f "${cfg}.new"
      return 1
    fi
  fi
  mv "${cfg}.new" "$cfg"
  chmod 600 "$cfg"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "xmesh@${g}.service" 2>/dev/null \
      && ok "Инстанс xmesh@${g} перезапущен (active=${active:-block})" \
      || warn "Не удалось перезапустить xmesh@${g} (systemd недоступен?)"
  fi
  return 0
}

group_rebuild() { group_apply "$1" "__auto__"; }

#=========================== SYSTEMD-ЮНИТ РОУТЕРА =============================
install_router_unit() {
  # №23 (аудит №1): юнит перезаписывается без вопросов — сохраняем прежнюю версию
  [ -f /etc/systemd/system/xmesh@.service ] \
    && cp -f /etc/systemd/system/xmesh@.service "/etc/systemd/system/xmesh@.service.bak.$(date +%s)" 2>/dev/null || true
  cat > /etc/systemd/system/xmesh@.service <<'EOF'
[Unit]
Description=XMesh Router (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/xray run -test -c /etc/xmesh/groups/%i/config.json
ExecStart=/usr/local/bin/xray run -c /etc/xmesh/groups/%i/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  ok "Юнит xmesh@.service установлен"
}

#=========================== NGINX: ЛОКАЙШЕНЫ ГРУПП И ПОДПИСОК ================
master_conf_path() {
  local conf; conf=$(env_get MASTER_CONF)
  if [ -n "$conf" ] && [ -f "$conf" ]; then printf '%s' "$conf"; return 0; fi
  return 1
}

nginx_ensure_group_location() {
  local g="$1" conf gj port
  conf=$(master_conf_path) || { err "Не найден конфиг мастер-узла (MASTER_CONF). Сначала установка/привязка."; return 1; }
  gj=$(group_file "$g"); [ -f "$gj" ] || { err "Группа $g не найдена"; return 1; }
  port=$(jq -r '.listen_port' "$gj")
  if grep -q "# XMESH:g-${g}:BEGIN" "$conf"; then
    ok "Локейшен группы $g уже в конфиге"
    return 0
  fi
  local block
  block="# XMESH:g-${g}:BEGIN$(generate_location_block "2" "/${g}" "127.0.0.1:${port}" "true")
    # XMESH:g-${g}:END"
  backup_file "$conf"
  nginx_insert_block "$conf" "$block" || return 1
  if apply_config "$conf"; then
    ok "Локейшен группы '$g' добавлен (/${g} -> 127.0.0.1:${port})"
    return 0
  fi
  return 1
}

nginx_ensure_sub_location() {
  local conf
  conf=$(master_conf_path) || { err "Не найден конфиг мастер-узла (MASTER_CONF)"; return 1; }
  grep -q "# XMESH:subs:BEGIN" "$conf" && { ok "Раздача подписок уже настроена"; return 0; }
  local block
  block=$(cat <<'EOF'
    # XMESH:subs:BEGIN
    # --- Подписки клиентов (раздаёт сам xray-mesh) ---
    location ^~ /sub/ {
        alias /var/www/xmesh-subs/;
        default_type text/plain;
        add_header Cache-Control "no-store";
        access_log off;
    }
    # XMESH:subs:END
EOF
)
  backup_file "$conf"
  nginx_insert_block "$conf" "$block" || return 1
  apply_config "$conf"
}

nginx_ensure_direct_location() {
  local conf port dpath block
  conf=$(master_conf_path) || { err "Не найден конфиг мастер-узла"; return 1; }
  port=$(env_get DIRECT_PORT); dpath=$(env_get DIRECT_PATH)
  [ -n "$port" ] && [ -n "$dpath" ] || { err "DIRECT_PORT/DIRECT_PATH не заданы"; return 1; }
  grep -q "# XMESH:g-direct:BEGIN" "$conf" && { ok "Локейшен direct уже есть"; return 0; }
  block="# XMESH:g-direct:BEGIN$(generate_location_block "2" "$dpath" "127.0.0.1:${port}" "true")
    # XMESH:g-direct:END"
  backup_file "$conf"
  nginx_insert_block "$conf" "$block" || return 1
  apply_config "$conf"
}

#=========================== ПОДПИСКИ =========================================
# Файл /var/www/xmesh-subs/<token> = base64(список vless:// ссылок).
# Раздаётся nginx-ом: https://<host>/sub/<token>

link_group_user() {  # <группа> <uuid> <email>
  local g="$1" uuid="$2" email="$3" gj host path country label
  gj=$(group_file "$g"); [ -f "$gj" ] || return 1
  host=$(env_get MASTER_HOST); [ -n "$host" ] || return 1
  path=$(jq -r '.ws_path' "$gj"); country=$(jq -r '.country' "$gj")
  label=$(urienc "${country} · ${email%%@*}")
  local penc; penc=$(urienc "$path")
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2,http/1.1&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$host" "$host" "$host" "$penc" "$label"
}

link_panel_user() {  # <inbound_obj> <uuid> <email>
  # В нашей архитектуре панельные inbound'ы слушают 127.0.0.1 и прячутся за
  # nginx: клиент подключается к 443 (TLS терминирует nginx), а внутренний
  # порт inbound'а в ссылку НЕ попадает. Если inbound смотрит наружу
  # (listen != 127.0.0.1) — строим "нативную" ссылку как есть.
  local obj="$1" uuid="$2" email="$3" host listen port remark stream network
  host=$(env_get MASTER_HOST); [ -n "$host" ] || return 1
  listen=$(jq -r '.listen // ""' <<<"$obj")
  remark=$(jq -r '.remark' <<<"$obj")
  stream=$(jq -r '.streamSettings|fromjson' <<<"$obj")
  network=$(jq -r '.network' <<<"$stream")
  local q="encryption=none&type=${network}"
  local label; label=$(urienc "${remark} · ${email%%@*}")
  if [ "$listen" = "127.0.0.1" ]; then
    # --- режим за nginx: клиент ходит на 443, TLS держит nginx ---
    q+="&security=tls&sni=${host}&fp=chrome&alpn=h2,http/1.1"
    case "$network" in
      ws)
        local wpath
        wpath=$(jq -r '.wsSettings.path // "/"' <<<"$stream")
        q+="&path=$(urienc "$wpath")&host=${host}"
        ;;
      grpc)
        local svc
        svc=$(jq -r '.grpcSettings.serviceName // ""' <<<"$stream")
        q+="&serviceName=$(urienc "$svc")&mode=gun"
        ;;
      xhttp|splithttp)
        local xpath
        xpath=$(jq -r '(.xhttpSettings.path // .splitHttpSettings.path // "/")' <<<"$stream")
        q+="&path=$(urienc "$xpath")&host=${host}"
        ;;
    esac
    printf 'vless://%s@%s:443?%s#%s' "$uuid" "$host" "$q" "$label"
    return 0
  fi
  # --- нативный режим: inbound открыт наружу сам по себе ---
  port=$(jq -r '.port' <<<"$obj")
  local clients security flow
  clients=$(jq -r '.settings|fromjson|.clients' <<<"$obj")
  flow=$(jq -r --arg u "$uuid" '[.[]|select(.id==$u)][0].flow // ""' <<<"$clients" 2>/dev/null)
  security=$(jq -r '.security' <<<"$stream")
  [ -n "$flow" ] && [ "$flow" != "null" ] && [ "$flow" != "" ] && q+="&flow=${flow}"
  case "$security" in
    tls)
      local sni
      sni=$(jq -r '.tlsSettings.serverName // ""' <<<"$stream")
      [ -n "$sni" ] && [ "$sni" != "null" ] || sni="$host"
      q+="&security=tls&sni=${sni}&fp=chrome&alpn=h2,http/1.1"
      ;;
    reality)
      local sni pbk sid
      sni=$(jq -r '.realitySettings.serverNames[0] // .realitySettings.serverName // ""' <<<"$stream")
      pbk=$(jq -r '.realitySettings.settings.publicKey // ""' <<<"$stream")
      sid=$(jq -r '.realitySettings.settings.shortIds[0] // ""' <<<"$stream")
      q+="&security=reality&sni=${sni}&fp=chrome"
      [ -n "$pbk" ] && q+="&pbk=${pbk}"
      [ -n "$sid" ] && q+="&sid=${sid}"
      ;;
    *) q+="&security=none" ;;
  esac
  case "$network" in
    ws)
      local wpath
      wpath=$(jq -r '.wsSettings.path // "/"' <<<"$stream")
      q+="&path=$(urienc "$wpath")&host=${host}"
      ;;
    grpc)
      local svc
      svc=$(jq -r '.grpcSettings.serviceName // ""' <<<"$stream")
      q+="&serviceName=$(urienc "$svc")&mode=gun"
      ;;
    xhttp|splithttp)
      local xpath
      xpath=$(jq -r '(.xhttpSettings.path // .splitHttpSettings.path // "/")' <<<"$stream")
      q+="&path=$(urienc "$xpath")&host=${host}"
      ;;
  esac
  printf 'vless://%s@%s:%s?%s#%s' "$uuid" "$host" "$port" "$q" "$label"
}

user_file_by_email() {
  local email="$1" f b
  shopt -s nullglob
  for f in "$XMESH_USERS_DIR"/*.json; do
    if [ "$(jq -r '.email' "$f" 2>/dev/null)" = "$email" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

build_sub() {  # <email>
  local email="$1" uf uuid token groups g links=() l obj
  uf=$(user_file_by_email "$email") || { err "Пользователь $email не найден"; return 1; }
  uuid=$(jq -r '.uuid' "$uf"); token=$(jq -r '.token' "$uf")
  groups=$(jq -r '.groups[]' "$uf")
  [ -n "$groups" ] || { warn "У пользователя $email нет групп"; }
  for g in $groups; do
    if [ "$g" = "direct" ]; then
      obj=$(panel_inbound_by_client_uuid "$uuid")
      if [ -n "$obj" ]; then
        l=$(link_panel_user "$obj" "$uuid" "$email") && links+=("$l")
      else
        warn "Клиент $email не найден в панели (direct) — ссылка пропущена"
      fi
    else
      l=$(link_group_user "$g" "$uuid" "$email") && links+=("$l")
    fi
  done
  if [ ${#links[@]} -eq 0 ]; then
    err "Для $email не собрано ни одной ссылки (нет групп/нодов?)"
    return 1
  fi
  printf '%s\n' "${links[@]}" | base64 -w0 > "${XMESH_SUBS_DIR}/${token}.new"
  mv "${XMESH_SUBS_DIR}/${token}.new" "${XMESH_SUBS_DIR}/${token}"
  chmod 640 "${XMESH_SUBS_DIR}/${token}"   # S-04: читать — только nginx
  chgrp www-data "${XMESH_SUBS_DIR}/${token}" 2>/dev/null || true
  ok "Подписка обновлена: https://$(env_get MASTER_HOST)/sub/${token}  (${#links[@]} ссылок)"
  return 0
}

build_all_subs() {
  local f email n=0
  shopt -s nullglob
  for f in "$XMESH_USERS_DIR"/*.json; do
    email=$(jq -r '.email' "$f" 2>/dev/null)
    [ -n "$email" ] || continue
    build_sub "$email" && n=$((n+1))
  done
  ok "Перевыпущено подписок: $n"
}

sub_show_urls() {
  local f email token
  shopt -s nullglob
  hr
  echo "Ссылки на подписки:"
  for f in "$XMESH_USERS_DIR"/*.json; do
    email=$(jq -r '.email' "$f" 2>/dev/null); token=$(jq -r '.token' "$f" 2>/dev/null)
    [ -n "$email" ] && echo "  $email : https://$(env_get MASTER_HOST)/sub/${token}"
  done
  hr
}

#=========================== STATE (состояние нод/групп) ======================
state_get() {
  [ -f "$XMESH_STATE" ] || { printf ''; return 0; }
  grep "^$1=" "$XMESH_STATE" 2>/dev/null | head -n1 | cut -d= -f2-
  return 0
}

state_set() {
  local k="$1" v="$2" tmp
  mkdir -p "$XMESH_LIB_DIR"; touch "$XMESH_STATE"; chmod 600 "$XMESH_STATE"
  tmp="${XMESH_STATE}.tmp.$$"
  awk -F= -v k="$k" -v v="$v" 'BEGIN{f=0} $1==k{print k"="v; f=1; next} {print} END{if(!f) print k"="v}' "$XMESH_STATE" > "$tmp" \
    && mv "$tmp" "$XMESH_STATE"
  return 0
}

human_bytes() {
  local b="$1"
  if [ -z "$b" ] || [ "$b" = "null" ]; then printf '0 B'; return 0; fi
  awk -v b="$b" 'BEGIN{
    s="B KB MB GB TB"; n=split(s,a," "); i=1;
    while (b>=1024 && i<n) { b/=1024; i++ }
    printf (i==1) ? "%d B" : "%.1f %s", b, a[i]}'
}

#=========================== SSH-СЛОЙ (управление нодами) =====================
ssh_key_path() { printf '%s/xmesh_ed25519' "$XMESH_SSH_DIR"; }

ssh_key_ensure() {
  local key; key=$(ssh_key_path)
  if [ ! -f "$key" ]; then
    mkdir -p "$XMESH_SSH_DIR"; chmod 700 "$XMESH_SSH_DIR"
    ssh-keygen -t ed25519 -N "" -f "$key" -C "xmesh-master" >/dev/null 2>&1 \
      || die "Не удалось создать SSH-ключ"
    ok "SSH-ключ мастера создан: $key"
  fi
  printf '%s' "$key"
}

# V-05 (аудит №2): TOFU-подтверждение отпечатка ДО первого соединения; пароль
# на ноду не уезжает, пока человек не сверил отпечаток (или XMESH_YES=1)
v3_ssh_host_key() { # $1 host, $2 port -> 0 = можно подключаться
  local host="$1" port="$2" kh="$XMESH_SSH_DIR/known_hosts" scan fp a
  mkdir -p "$XMESH_SSH_DIR" 2>/dev/null || true
  ssh-keygen -F "[${host}]:${port}" -f "$kh" >/dev/null 2>&1 && return 0
  ssh-keygen -F "${host}" -f "$kh" >/dev/null 2>&1 && return 0
  scan="$(timeout 15 ssh-keyscan -T 8 -p "$port" "$host" 2>/dev/null)" || scan=""
  [ -n "$scan" ] || { err "Не удалось снять отпечаток ключа ${host}:${port} (V-05)"; return 1; }
  fp="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  warn "Первое подключение к ${host}:${port}; отпечаток ключа: ${fp:-?}"
  if [ "${XMESH_YES:-${XKIT_YES:-0}}" = "1" ]; then
    warn "Принимаю без подтверждения (YES; TOFU — сверьте с консолью провайдера)"
  else
    read -r -p "Совпадает с консолью провайдера? [y/N]: " a || a=""
    case "$a" in y|Y|yes|Yes) ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$scan" >> "$kh"
  return 0
}

ssh_run() {  # <key> <port> <user> <host> <command...>   (SSH_TIMEOUT — лимит, сек)
  local key="$1" port="$2" user="$3" host="$4"
  shift 4
  v3_ssh_host_key "$host" "$port" || { err "Ключ хоста ${host}:${port} не подтверждён (V-05)"; return 1; }
  timeout "${SSH_TIMEOUT:-300}" ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=12 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$XMESH_SSH_DIR/known_hosts" "${user}@${host}" "$@"
}

ssh_deploy_key() {  # <port> <user> <host> <password> <key>
  local port="$1" user="$2" host="$3" pw="$4" key="$5"
  # V-05: пароль отправляем только ПОСЛЕ подтверждения ключа хоста
  v3_ssh_host_key "$host" "$port" || { err "Ключ хоста не подтверждён — пароль не отправляю (V-05)"; return 1; }
  SSHPASS="$pw" sshpass -e ssh-copy-id -i "${key}.pub" -p "$port" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$XMESH_SSH_DIR/known_hosts" -o ConnectTimeout=12 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "${user}@${host}" >/dev/null 2>&1
}

# Установочный скрипт для ноды. Параметры приходят через env (XM_*),
# сам скрипт неизменяем и передаётся по stdin: ssh 'env .. bash -s' < script
write_node_install_script() {
  cat > "$1" <<'NODEEOF'
#!/bin/bash
set -e
[ "$(id -u)" -eq 0 ] || { echo "ERR: нужны права root на ноде"; exit 1; }
: "${XM_PORT:?XM_PORT not set} ${XM_UUID:?XM_UUID not set} ${XM_SNI:?XM_SNI not set} ${XM_SID:?XM_SID not set}"
export DEBIAN_FRONTEND=noninteractive
echo "== arch =="
case "$(uname -m)" in
  x86_64) : ;; aarch64) : ;;
  *) echo "ERR: неподдерживаемая архитектура $(uname -m)"; exit 1 ;;
esac
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl unzip openssl jq ca-certificates >/dev/null 2>&1 || true
fi
echo "== xray install =="
if [ ! -x /usr/local/bin/xray ]; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
    || { echo "ERR: не удалось установить xray (нет доступа к github с ноды?)"; exit 1; }
fi
echo "== reality keys =="
X25519=$(/usr/local/bin/xray x25519)
PRIV=$(printf '%s\n' "$X25519" | sed -n 's/^Private key: //p')
PUB=$(printf '%s\n' "$X25519" | sed -n 's/^Public key: //p')
[ -n "$PRIV" ] && [ -n "$PUB" ] || { echo "ERR: xray x25519 не выдал ключи"; exit 1; }
echo "== config =="
mkdir -p /usr/local/etc/xray
jq -n --arg port "$XM_PORT" --arg uuid "$XM_UUID" --arg sni "$XM_SNI" --arg sid "$XM_SID" --arg priv "$PRIV" '{
  log: {loglevel: "warning"},
  inbounds: [{
    tag: "mesh-in", listen: "0.0.0.0", port: ($port|tonumber), protocol: "vless",
    settings: {clients: [{id: $uuid, email: "mesh", level: 0}], decryption: "none"},
    streamSettings: {network: "tcp", security: "reality",
      realitySettings: {show: false, dest: ($sni + ":443"), xver: 0,
        serverNames: [$sni], privateKey: $priv, shortIds: [$sid]},
      tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}
  }],
  outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}]
}' > /usr/local/etc/xray/config.json
/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${XM_PORT}/tcp" >/dev/null 2>&1 || true
fi
EXIT_IP=$(curl -s -m 8 https://api.ipify.org 2>/dev/null || echo "")
echo "===XMESH_JSON==="
jq -n --arg pubkey "$PUB" --arg ip "$EXIT_IP" '{pubkey: $pubkey, exit_ip: $ip, ok: true}'
echo "===XMESH_END==="
NODEEOF
}

#=========================== НОДЫ =============================================
node_file() { printf '%s/%s.json' "$XMESH_NODES_DIR" "$1"; }

node_add() {  # [группа] — если передана, вопрос о группе не задаётся
  local grp="${1:-}"
  hr
  echo "Добавление ноды (установка идёт по SSH прямо из этого окна)"
  hr
  if [ -z "$grp" ]; then
    local gs
    gs=$(group_list_names)
    [ -n "$gs" ] || { warn "Групп нет — сначала создайте группу"; group_create; grp=$(group_list_names | head -n1); [ -n "$grp" ] || return 1; }
    echo "Группы:"; echo "$gs" | nl -w2 -s') '
    read -r -p "Номер группы: " gnum
    grp=$(echo "$gs" | sed -n "${gnum}p")
    [ -n "$grp" ] || { err "Нет такой группы"; return 1; }
  else
    [ -f "$(group_file "$grp")" ] || { err "Группа $grp не найдена"; return 1; }
  fi

  local name host sshport sshuser pw key
  name=$(read_name "Имя ноды (напр. de1): ")
  [ -f "$(node_file "$name")" ] && { err "Нода '$name' уже существует"; return 1; }
  host=$(read_host "IP ноды: ")
  # ревью v3.2: EOF (Ctrl-D) на вводе с дефолтом — отмена, а не молчаливое
  # продолжение с дефолтом (попытка коннекта к случайному хосту);
  # имя/IP/пароль и так защищены (read_name/read_host/read_secret → die)
  read -r -p "SSH-порт ноды [22]: " sshport || { echo; return 1; }
  sshport=${sshport:-22}
  is_port "$sshport" || { err "Некорректный SSH-порт"; return 1; }
  read -r -p "SSH-пользователь [root]: " sshuser || { echo; return 1; }
  sshuser=${sshuser:-root}
  # аудит №3 (v4.6): без валидации кавычка в sshuser ломала JSON реестра
  # (писался printf'ом) и уезжала в ssh; допускаем как useradd
  [[ "$sshuser" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || { err "SSH-пользователь: только латиница/цифры/._- (до 32 симв., не с цифры)"; return 1; }
  echo ""
  warn "Пароль нужен ОДИН раз — чтобы положить ключ мастера на ноду. Он нигде не сохраняется."
  pw=$(read_secret "Пароль ${sshuser}@${host}: ")
  [ -n "$pw" ] || { err "Пустой пароль"; return 1; }
  key=$(ssh_key_ensure)

  log "Кладу ключ мастера на ноду..."
  ssh_deploy_key "$sshport" "$sshuser" "$host" "$pw" "$key" \
    || { err "Не удалось войти по паролю (проверьте IP/порт/пароль, разрешён ли вход root по паролю)"; return 1; }
  ssh_run "$key" "$sshport" "$sshuser" "$host" 'echo ok' >/dev/null 2>&1 \
    || { err "Вход по ключу не заработал"; return 1; }
  ok "Ключ установлен — дальше пароль не нужен"

  local nport sni
  read -r -p "Reality-порт ноды [443]: " nport || { echo; return 1; }
  nport=${nport:-443}
  is_port "$nport" || { err "Некорректный порт"; return 1; }
  read -r -p "SNI-маскировка (домен-приманка) [www.microsoft.com]: " sni || { echo; return 1; }
  sni=${sni:-www.microsoft.com}
  is_domain "$sni" || { err "SNI должен быть доменом"; return 1; }

  local uuid sid probe_port
  uuid=$(gen_uuid); sid=$(gen_hex 8)
  probe_port=$(probe_next_port) || { err "Нет свободных портов для probe (22001-23000)"; return 1; }

  log "Устанавливаю Xray на ноду $host (2-4 минуты)..."
  local nis; nis="$(mktemp /tmp/.xmesh_node_install.XXXXXX)"
  write_node_install_script "$nis"
  local out json pbk eip
  out=$(SSH_TIMEOUT=900 ssh_run "$key" "$sshport" "$sshuser" "$host" \
        "env XM_PORT='$nport' XM_UUID='$uuid' XM_SNI='$sni' XM_SID='$sid' bash -s" \
        < "$nis") || { err "SSH-сессия оборвалась/истекла"; printf '%s\n' "$out" | tail -n 15; rm -f "$nis"; return 1; }
  rm -f "$nis"
  json=$(printf '%s\n' "$out" | sed -n '/===XMESH_JSON===/,/===XMESH_END===/p' | sed '1d;$d')
  if [ -z "$json" ]; then
    err "Установка не завершилась корректно. Последние строки вывода ноды:"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
    return 1
  fi
  pbk=$(jq -r '.pubkey' <<<"$json")
  eip=$(jq -r '.exit_ip' <<<"$json")
  [ -n "$eip" ] && [ "$eip" != "null" ] && [ "$eip" != "" ] || eip="$host"
  # S-05/№10: ответ ноды не доверяем — битый eip/pbk не должен ломать JSON реестра
  is_ip "$eip" || eip="$host"
  [[ "$pbk" =~ ^[A-Za-z0-9_-]{42,44}$ ]] \
    || { err "Нода вернула некорректный публичный ключ (${pbk:0:12}…) — отмена"; return 1; }

  printf '{\n  "name": "%s",\n  "group": "%s",\n  "host": "%s",\n  "ssh_port": %s,\n  "ssh_user": "%s",\n  "port": %s,\n  "uuid": "%s",\n  "pubkey": "%s",\n  "short_id": "%s",\n  "sni": "%s",\n  "exit_ip": "%s",\n  "probe_port": %s,\n  "created": "%s"\n}\n' \
    "$name" "$grp" "$host" "$sshport" "$sshuser" "$nport" "$uuid" "$pbk" "$sid" "$sni" "$eip" "$probe_port" \
    "$(date +%F)" > "$(node_file "$name")"
  chmod 600 "$(node_file "$name")"

  # регистрация в группе: в список нод; первая нода становится primary
  local gf; gf=$(group_file "$grp")
  jq --arg n "$name" '.nodes += [$n] | (if (.primary // "") == "" then .primary = $n else . end)' "$gf" > "${gf}.tmp" \
    && mv "${gf}.tmp" "$gf"

  [ -f /etc/systemd/system/xmesh@.service ] || install_router_unit
  group_apply "$grp" || warn "Группу не удалось применить (смотрите ошибки выше)"
  nginx_ensure_group_location "$grp" || warn "Не удалось добавить nginx-локейшен группы"
  build_all_subs >/dev/null 2>&1 || true
  echo ""
  ok "Нода '$name' добавлена в группу '$grp'. Exit IP: $eip, Reality: $host:$nport (SNI $sni)"
  return 0
}

node_tcp_ok() {  # <host> <port>
  timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null
}

node_list() {
  hr
  printf '%-10s %-8s %-16s %-6s %-24s %-16s %s\n' "НОДА" "ГРУППА" "IP" "ПОРТ" "SNI" "EXIT-IP" "СТАТУС"
  local f n down
  shopt -s nullglob
  for f in "$XMESH_NODES_DIR"/*.json; do
    n=$(jq -r '.name' "$f"); down=$(state_get "DOWN_${n}")
    local st="up"
    [ "$down" = "1" ] && st="DOWN"
    printf '%-10s %-8s %-16s %-6s %-24s %-16s %s\n' \
      "$(jq -r '.name' "$f")" "$(jq -r '.group' "$f")" "$(jq -r '.host' "$f")" \
      "$(jq -r '.port' "$f")" "$(jq -r '.sni' "$f")" "$(jq -r '.exit_ip' "$f")" "$st"
  done
  [ -n "$(ls -A "$XMESH_NODES_DIR" 2>/dev/null)" ] || echo "  (нод нет)"
  hr
}

node_test_menu() {
  node_list
  local n nj host port alive
  read -r -p "Имя ноды для проверки (Enter — все): " n
  if [ -z "$n" ]; then
    shopt -s nullglob
    local f
    for f in "$XMESH_NODES_DIR"/*.json; do node_test_one "$(jq -r '.name' "$f")"; done
    return 0
  fi
  nj=$(node_file "$n"); [ -f "$nj" ] || { err "Нода не найдена"; return 1; }
  node_test_one "$n"
}

node_test_one() {
  local n="$1" nj host port pport eip t0 t1
  nj=$(node_file "$n"); [ -f "$nj" ] || { err "Нода $n не найдена"; return 1; }
  host=$(jq -r '.host' "$nj"); port=$(jq -r '.port' "$nj")
  pport=$(jq -r '.probe_port' "$nj"); eip=$(jq -r '.exit_ip' "$nj")
  if node_tcp_ok "$host" "$port"; then
    t0=$(date +%s%N)
    local pt; pt="$(mktemp /tmp/.xmesh_probe.XXXXXX)"; chmod 600 "$pt"
    if curl -s -m 8 -x "socks5h://127.0.0.1:${pport}" https://api.ipify.org -o "$pt" 2>/dev/null; then
      t1=$(date +%s%N)
      local got; got=$(cat "$pt" 2>/dev/null); rm -f "$pt"
      local ms=$(( (t1 - t0) / 1000000 ))
      if [ "$got" = "$eip" ]; then
        ok "нода $n: TCP ok, выход ok ($got, ${ms} мс)"
      else
        warn "нода $n: TCP ok, но exit-IP не совпал: ожидалось $eip, получено ${got:-нет}"
      fi
    else
      warn "нода $n: TCP ok, глубокая проверка не прошла (socks-проба 127.0.0.1:${pport})"
    fi
  else
    err "нода $n: TCP ${host}:${port} НЕ отвечает"
  fi
}

node_remove() {
  node_list
  local n nj grp gf wipe
  n=$(read_name "Имя ноды для удаления: ")
  nj=$(node_file "$n"); [ -f "$nj" ] || { err "Нода не найдена"; return 1; }
  grp=$(jq -r '.group' "$nj")
  read -r -p "Стереть xray на самой ноде по SSH (disable+stop, конфиг остаётся)? [y/N]: " wipe
  if [[ "$wipe" =~ ^[Yy] ]]; then
    local key sshport sshuser host
    key=$(ssh_key_ensure)
    sshport=$(jq -r '.ssh_port' "$nj"); sshuser=$(jq -r '.ssh_user' "$nj"); host=$(jq -r '.host' "$nj")
    ssh_run "$key" "$sshport" "$sshuser" "$host" \
      'systemctl disable --now xray >/dev/null 2>&1; echo done' >/dev/null 2>&1 \
      && ok "xray на ноде остановлен" || warn "Не удалось подключиться к ноде — пропускаю"
  fi
  gf=$(group_file "$grp")
  if [ -f "$gf" ]; then
    jq --arg n "$n" '.nodes = [.nodes[] | select(. != $n)] | (if .primary == $n then .primary = (.nodes[0] // "") else . end)' "$gf" > "${gf}.tmp" \
      && mv "${gf}.tmp" "$gf"
    sed -i "/^ACTIVE_${grp}=/d" "$XMESH_STATE" 2>/dev/null || true
    group_apply "$grp" || true
  fi
  rm -f "$nj"
  build_all_subs >/dev/null 2>&1 || true
  ok "Нода '$n' удалена"
}

# смена SNI-маскировки ноды (после сканера)
node_apply_sni() {
  local n="$1" sni="$2" nj key sshport sshuser host
  nj=$(node_file "$n"); [ -f "$nj" ] || { err "Нода не найдена"; return 1; }
  is_domain "$sni" || { err "SNI должен быть доменом"; return 1; }
  key=$(ssh_key_ensure)
  sshport=$(jq -r '.ssh_port' "$nj"); sshuser=$(jq -r '.ssh_user' "$nj"); host=$(jq -r '.host' "$nj")
  local ssf; ssf="$(mktemp /tmp/.xmesh_sni.XXXXXX)"
  cat > "$ssf" <<'SNIEOF'
#!/bin/bash
set -e
: "${XM_SNI:?XM_SNI not set}"
F=/usr/local/etc/xray/config.json
[ -f "$F" ] || { echo "ERR: нет конфига xray на ноде"; exit 1; }
command -v jq >/dev/null 2>&1 || { apt-get install -y -qq jq >/dev/null 2>&1 || { echo "ERR: нет jq"; exit 1; }; }
jq --arg sni "$XM_SNI" '(.inbounds[] | select(.tag=="mesh-in") | .streamSettings.realitySettings) |=
  (.dest = ($sni + ":443") | .serverNames = [$sni])' "$F" > "${F}.tmp"
/usr/local/bin/xray run -test -c "${F}.tmp" >/dev/null
mv "${F}.tmp" "$F"
systemctl restart xray
echo "SNIOK"
SNIEOF
  local out
  out=$(ssh_run "$key" "$sshport" "$sshuser" "$host" \
        "env XM_SNI='$sni' bash -s" < "$ssf" 2>&1) || true
  rm -f "$ssf"
  case "$out" in
    *SNIOK*)
      jq --arg sni "$sni" '.sni = $sni' "$nj" > "${nj}.tmp" && mv "${nj}.tmp" "$nj"
      local grp; grp=$(jq -r '.group' "$nj")
      group_apply "$grp" || true
      ok "SNI ноды $n сменён на $sni (конфиг мастера и ноды обновлены)"
      ;;
    *) err "Не удалось сменить SNI на ноде:"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' ;;
  esac
}

#=========================== ДЕМОН xmesh-watch ================================
install_watch_daemon() {
  log "Устанавливаю демон мониторинга xmesh-watch..."
  cat > "$WATCH_BIN" <<'WEOF'
#!/bin/bash
# xmesh-watch v3 — мониторинг нод: sticky pin + failover (без авторотации).
# Логика: пока primary жив — ВСЕ пользователи группы выходят через него.
# Смерть primary (DOWN_THRESHOLD подряд неудач) -> группа переезжает на
# первую живую ноду той же группы (та же страна). Восстановление
# (UP_THRESHOLD подряд успехов) -> возврат на primary, если group.revert=true.
# Переключение = пересборка конфига и рестарт ТОЛЬКО инстанса xmesh@<группа>.
set -u
XMESH_DIR="/etc/xmesh"
ENVF="$XMESH_DIR/xmesh.env"
STATE="/var/lib/xmesh/state.env"
[ -f "$ENVF" ] && . "$ENVF"
MAIN="${XMESH_MAIN:-/usr/local/bin/xray-mesh}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
DOWN_THRESHOLD="${DOWN_THRESHOLD:-3}"
UP_THRESHOLD="${UP_THRESHOLD:-4}"
DEEP_INTERVAL="${DEEP_INTERVAL:-60}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"

log() { logger -t xmesh-watch "$*"; }
notify() {
  log "$*"
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
    curl -s -m 5 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT}" -d text="xmesh-watch: $*" >/dev/null 2>&1
  fi
}
state_get() { grep "^$1=" "$STATE" 2>/dev/null | head -n1 | cut -d= -f2-; }
state_set() {
  local k="$1" v="$2" tmp
  touch "$STATE"
  tmp="${STATE}.tmp"
  awk -F= -v k="$k" -v v="$v" 'BEGIN{f=0} $1==k{print k"="v; f=1; next} {print} END{if(!f) print k"="v}' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}
tcp_ok() { timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null; }
deep_ok() {
  local ip
  ip=$(curl -s -m 8 -x "socks5h://127.0.0.1:$2" https://api.ipify.org 2>/dev/null)
  [ "$ip" = "$3" ]
}
node_down() { [ "$(state_get "DOWN_$1")" = "1" ]; }

probe_node() {
  local n="$1" nj fails oks now deep_ts was
  nj="$XMESH_DIR/nodes/$n.json"
  [ -f "$nj" ] || return 0
  local host port pport eip
  host=$(jq -r '.host' "$nj"); port=$(jq -r '.port' "$nj")
  pport=$(jq -r '.probe_port' "$nj"); eip=$(jq -r '.exit_ip' "$nj")
  fails=$(state_get "FAIL_$n"); oks=$(state_get "OK_$n")
  fails=${fails:-0}; oks=${oks:-0}
  now=$(date +%s); deep_ts=$(state_get "DEEP_$n"); deep_ts=${deep_ts:-0}
  if tcp_ok "$host" "$port"; then
    if [ $((now - deep_ts)) -ge "$DEEP_INTERVAL" ]; then
      state_set "DEEP_$n" "$now"
      if deep_ok "$n" "$pport" "$eip"; then
        oks=$((oks+1)); fails=0
      else
        fails=$((fails+2)); oks=0
        log "нода $n: TCP жив, но выход через неё не соответствует ($eip)"
      fi
    fi
  else
    fails=$((fails+1)); oks=0
  fi
  state_set "FAIL_$n" "$fails"
  state_set "OK_$n" "$oks"
  was=$(state_get "DOWN_$n"); was=${was:-0}
  if [ "$fails" -ge "$DOWN_THRESHOLD" ] && [ "$was" != "1" ]; then
    state_set "DOWN_$n" 1
    notify "нода $n: НЕДОСТУПНА (fails=$fails)"
  fi
  if [ "$oks" -ge "$UP_THRESHOLD" ] && [ "$was" = "1" ]; then
    state_set "DOWN_$n" 0
    notify "нода $n: восстановилась (oks=$oks)"
  fi
}

desired_for_group() {
  local gj="$1" primary n
  [ -f "$gj" ] || { printf ''; return 0; }
  primary=$(jq -r '.primary // ""' "$gj")
  if [ -n "$primary" ] && ! node_down "$primary"; then printf '%s' "$primary"; return 0; fi
  while read -r n; do
    [ -n "$n" ] || continue
    [ "$n" = "$primary" ] && continue
    if ! node_down "$n"; then printf '%s' "$n"; return 0; fi
  done < <(jq -r '.nodes[]' "$gj" 2>/dev/null)
  printf ''
}

switch_group() {
  local g="$1" target="$2"
  if "$MAIN" --switch "$g" "$target" >/dev/null 2>&1; then
    state_set "ACTIVE_$g" "$target"
    notify "группа $g: активная нода -> ${target:-block (нет живых нод)}"
  else
    notify "группа $g: СБОЙ переключения на ${target:-block} — смотрите журнал xray-mesh"
  fi
}

log "xmesh-watch запущен (interval=${CHECK_INTERVAL}s down=${DOWN_THRESHOLD} up=${UP_THRESHOLD} deep=${DEEP_INTERVAL}s)"
while true; do
  shopt -s nullglob
  watch_g=""
  for watch_gj in "$XMESH_DIR"/groups/*.json; do
    g=$(jq -r '.name' "$watch_gj" 2>/dev/null)
    [ -n "$g" ] || continue
    while read -r nn; do
      [ -n "$nn" ] || continue
      probe_node "$nn"
    done < <(jq -r '.nodes[]' "$watch_gj" 2>/dev/null)
    des=$(desired_for_group "$watch_gj")
    act=$(state_get "ACTIVE_$g")
    if [ -z "$act" ]; then act=$(jq -r '.primary // ""' "$watch_gj"); fi
    # self-heal: инстанс должен быть активен, если группе есть куда слать
    if [ -n "$des" ] && ! systemctl is-active --quiet "xmesh@${g}.service" 2>/dev/null; then
      "$MAIN" --rebuild "$g" >/dev/null 2>&1
    fi
    if [ "$des" != "$act" ]; then
      switch_group "$g" "$des"
    fi
  done
  sleep "$CHECK_INTERVAL"
done
WEOF
  chmod 700 "$WATCH_BIN"

  cat > /etc/systemd/system/xmesh-watch.service <<'UEOF'
[Unit]
Description=XMesh Watch (node health + failover)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xmesh-watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UEOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now xmesh-watch >/dev/null 2>&1 || true
  ok "Демон xmesh-watch установлен и запущен"
}

#=========================== ПОЛЬЗОВАТЕЛИ =====================================
user_add() {
  hr
  echo "Добавление пользователя"
  hr
  local email uuid token
  read -r -p "Email/логин пользователя (напр. ivan@mail.com): " email
  is_email "$email" || { err "Некорректный email"; return 1; }
  [ -n "$(user_file_by_email "$email")" ] && { err "Пользователь уже существует"; return 1; }
  uuid=$(gen_uuid); token=$(gen_hex 16)

  # выбор групп
  local groups_avail=() i=1 g
  echo "  $i) direct  (выход с IP мастер-узла, через панель 3X-UI)"; i=$((i+1))
  for g in $(group_list_names); do
    echo "  $i) $g      (выход через ноды группы '$g')"
    groups_avail+=("$g"); i=$((i+1))
  done
  read -r -p "Группы через запятую (напр. 1,2,3 или 'a' — все): " pick
  [ -n "$pick" ] || { err "Нужно выбрать хотя бы одну группу"; return 1; }
  local total=$(( ${#groups_avail[@]} + 1 )) chosen=() num
  if [ "$pick" = "a" ]; then
    for num in $(seq 1 "$total"); do chosen+=("$num"); done
  else
    IFS=',' read -ra nums <<<"$pick"
    for num in "${nums[@]}"; do
      num=$(printf '%s' "$num" | tr -d ' ')
      case "$num" in ''|*[!0-9]*) err "Некорректный выбор: $num"; return 1 ;; esac
      [ "$num" -ge 1 ] && [ "$num" -le "$total" ] || { err "Нет пункта $num"; return 1; }
      chosen+=("$num")
    done
  fi

  local ugroups=() n
  for num in "${chosen[@]}"; do
    if [ "$num" = "1" ]; then ugroups+=("direct"); else ugroups+=("${groups_avail[$((num-2))]}"); fi
  done

  # direct: добавить клиента в панель
  local ib_obj ib_id
  for n in "${ugroups[@]}"; do
    if [ "$n" = "direct" ]; then
      ib_obj=$(panel_inbound_by_remark direct)
      if [ -z "$ib_obj" ]; then
        err "В панели нет inbound 'direct'. Сначала полная установка или пункт привязки."
        return 1
      fi
      ib_id=$(jq -r '.id' <<<"$ib_obj")
      if panel_add_client "$ib_id" "$uuid" "$email"; then
        ok "Клиент добавлен в панель (inbound 'direct', id=$ib_id)"
      else
        err "Панель не приняла клиента"; return 1
      fi
    else
      local cf; cf=$(group_clients "$n")
      [ -f "$cf" ] || printf '[]\n' > "$cf"
      jq --arg id "$uuid" --arg email "$email" '. += [{id: $id, email: $email}]' "$cf" > "${cf}.tmp" \
        && mv "${cf}.tmp" "$cf"
      group_apply "$n" || warn "Группа $n не перезапустилась чисто"
    fi
  done

  local safe; safe=$(printf '%s' "$email" | sed 's/[^A-Za-z0-9._-]/_/g')
  printf '{\n  "email": "%s",\n  "uuid": "%s",\n  "token": "%s",\n  "groups": [%s],\n  "created": "%s"\n}\n' \
    "$email" "$uuid" "$token" \
    "$(printf '%s\n' "${ugroups[@]}" | sed 's/"/\\"/g' | awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')" \
    "$(date +%F)" > "${XMESH_USERS_DIR}/${safe}.json"
  chmod 600 "${XMESH_USERS_DIR}/${safe}.json"

  build_sub "$email"
  local pl="${XMESH_LIB_DIR}/links-${token}.txt"
  {
    echo "# Ссылки пользователя $email (можно импортировать вручную)"
    for n in "${ugroups[@]}"; do
      if [ "$n" = "direct" ]; then
        local obj; obj=$(panel_inbound_by_client_uuid "$uuid")
        [ -n "$obj" ] && link_panel_user "$obj" "$uuid" "$email"
      else
        link_group_user "$n" "$uuid" "$email"
      fi
    done
  } > "$pl"
  chmod 600 "$pl"
  echo ""
  ok "Подписка:  https://$(env_get MASTER_HOST)/sub/${token}"
  ok "Ссылки сохранены: $pl"
  return 0
}

user_del() {
  local email uf uuid token cf g
  read -r -p "Email пользователя для удаления: " email
  uf=$(user_file_by_email "$email") || { err "Пользователь не найден"; return 1; }
  uuid=$(jq -r '.uuid' "$uf"); token=$(jq -r '.token' "$uf")
  read -r -p "Удалить пользователя '$email' из панели и всех групп? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || { log "Отменено"; return 0; }
  panel_del_client_by_email "$email" || warn "В панели клиент не найден (не критично)"
  for g in $(jq -r '.groups[]' "$uf" 2>/dev/null); do
    [ "$g" = "direct" ] && continue
    cf=$(group_clients "$g")
    if [ -f "$cf" ]; then
      jq --arg e "$email" 'map(select(.email != $e))' "$cf" > "${cf}.tmp" && mv "${cf}.tmp" "$cf"
      group_apply "$g" || true
    fi
  done
  rm -f "${XMESH_SUBS_DIR}/${token}" "${XMESH_LIB_DIR}/links-${token}.txt" "$uf"
  ok "Пользователь '$email' удалён"
}

user_list() {
  hr
  echo "Пользователи:"
  local f email uuid token g traffic
  shopt -s nullglob
  for f in "$XMESH_USERS_DIR"/*.json; do
    email=$(jq -r '.email' "$f"); uuid=$(jq -r '.uuid' "$f")
    echo "  * $email  (создан $(jq -r '.created' "$f"))"
    echo "    группы: $(jq -r '.groups | join(", ")' "$f")"
    if jq -e '.groups | index("direct")' "$f" >/dev/null 2>&1; then
      local ib_id resp
      ib_obj=$(panel_inbound_by_client_uuid "$uuid")
      if [ -n "$ib_obj" ]; then
        ib_id=$(jq -r '.id' <<<"$ib_obj")
        resp=$(panel_call POST "/panel/api/inbounds/${ib_id}/getClientTraffic/${email}")
        local up down tot
        up=$(jq -r '.obj.up // 0' <<<"$resp" 2>/dev/null)
        down=$(jq -r '.obj.down // 0' <<<"$resp" 2>/dev/null)
        tot=$(( ${up:-0} + ${down:-0} ))
        echo "    трафик (direct): $(human_bytes "$tot")"
      fi
    fi
  done
  [ -n "$(ls -A "$XMESH_USERS_DIR" 2>/dev/null)" ] || echo "  (пользователей нет)"
  hr
}

#=========================== УСТАНОВКА 3X-UI (официальный инсталлятор) =======
write_master_nginx_conf() {  # <host> <crt> <key> <conf_file>
  local HOST="$1" CRT="$2" KEY="$3" CONF_FILE="$4" H2
  # ВАЖНО: НЕ удаляем sites-enabled/default здесь — только ПОСЛЕ успешного
  # nginx -t + reload в full_install. Иначе при ошибке конфига nginx остаётся
  # вообще без server{} на этом хосте и reload падает.
  H2=$(build_h2_block)
  cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $HOST;
    return 301 https://\$host\$request_uri;
}
server {
$H2
    server_name $HOST;
    ssl_certificate $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1h;
    server_tokens off;
    keepalive_timeout 1h;
    client_body_timeout 1h;
    client_max_body_size 0;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/$(basename "$CONF_FILE")"
}
install_3xui() {
  warn "Будет скачан и запущен ОФИЦИАЛЬНЫЙ установщик 3X-UI (github.com/MHSanaei/3x-ui)."
  read -r -p "Продолжить установку 3X-UI? [Y/n]: " a || { echo; return 1; }
  if [[ "$a" =~ ^[Nn] ]]; then log "Пропущено"; return 1; fi
  local dl tag url
  # K-02 (аудит №2): тег последнего релиза вместо плавающего master
  tag="$(curl -fsSL --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null \
    | jq -r '.tag_name // ""' 2>/dev/null || true)"
  if [[ "$tag" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
    url="https://raw.githubusercontent.com/mhsanaei/3x-ui/${tag}/install.sh"
    log "Установщик 3X-UI: релиз ${tag} (не master — K-02)"
  else
    warn "Не удалось определить тег релиза 3X-UI — качаю master"
    url="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
  fi
  dl="$(mktemp /tmp/xmesh-3xui.XXXXXX)" || { err "mktemp не удался"; return 1; }
  curl -fsSL -o "$dl" "$url" \
    || { err "Не удалось скачать установщик 3X-UI (проверьте сеть)"; rm -f "$dl"; return 1; }
  bash -n "$dl" || { err "Установщик 3X-UI не проходит bash -n — отмена (K-02)"; rm -f "$dl"; return 1; }
  # NOTE (аудит №8): XUI_NONINTERACTIVE=1 здесь НЕ ставим, в отличие от xkit.sh —
  # осознанно: пользователь вводит креды руками и затем дублирует их в env
  # (panel_creds_dialog); принудительный режим сломал бы этот диалог
  bash "$dl"; local rc=$?
  rm -f "$dl"
  return $rc
}

install_self() {
  # аудит №8: успех cp/chmod проверяем — раньше «доступен командой» печатался
  # даже если файл не скопировался
  if [ "$SELF_PATH" != "/usr/local/bin/xray-mesh" ]; then
    if cp -f "$SELF_PATH" /usr/local/bin/xray-mesh && chmod 700 /usr/local/bin/xray-mesh; then
      env_set XMESH_MAIN "/usr/local/bin/xray-mesh"
      ok "Скрипт доступен командой: xray-mesh"
    else
      err "Не удалось установить в /usr/local/bin/xray-mesh — запускайте напрямую: bash $SELF_PATH"
      return 1
    fi
  else
    ok "Скрипт уже доступен командой: xray-mesh"
  fi
}

#=========================== ПОЛНАЯ УСТАНОВКА МАСТЕР-УЗЛА =====================
full_install() {
  hr
  echo "ПОЛНАЯ УСТАНОВКА МАСТЕР-УЗЛА"
  echo "nginx (TLS, скрытие) + 3X-UI (пользователи/подписки) + слой нод + демон"
  hr
  deps_install || return 1
  ensure_xray_binary || return 1
  ensure_dirs

  echo ""
  echo -e "${GREEN}Введите домен ИЛИ IP ЭТОГО сервера (например mesh.example.com или 203.0.113.10):${NC}"
  local HOST HOST_KIND
  HOST=$(read_host "-> ")
  [ -n "$HOST" ] || die "Домен/IP обязателен"
  HOST_KIND=$(host_kind "$HOST")
  env_set MASTER_HOST "$HOST"

  echo ""
  echo -e "${YELLOW}Откуда берём SSL-сертификат?${NC}"
  echo "1) Let's Encrypt — для ДОМЕНА (90 дней, авто-продление)"
  echo "2) Свои файлы в /root/cert/$HOST/ (fullchain.pem + privkey.pem)"
  echo "3) Let's Encrypt — для IP (shortlived, 6 дней, авто-продление, нужен certbot >= ${CERTBOT_MIN_IP})"
  echo "4) Самоподписанный — домен или IP (10 лет, на клиентах allowInsecure=true)"
  local CERT_MODE LE_EMAIL FINAL_CRT="" FINAL_KEY=""
  read -r -p "Ваш выбор: " CERT_MODE
  case "$CERT_MODE" in
    1|2|3|4) ;;
    *) die "Нет такого пункта" ;;
  esac
  read -r -p "Email для Let's Encrypt (Enter — пропустить): " LE_EMAIL
  if [ -n "$LE_EMAIL" ] && ! is_email "$LE_EMAIL"; then
    warn "Email выглядит некорректно — продолжаю без него"; LE_EMAIL=""
  fi
  case "$CERT_MODE" in
    1) [ "$HOST_KIND" = "domain" ] || die "LE-домен — только для домена. Возьмите пункт 3/4"
       issue_cert_le_domain "$HOST" "$LE_EMAIL" || return 1
       FINAL_CRT="/etc/letsencrypt/live/$HOST/fullchain.pem"; FINAL_KEY="/etc/letsencrypt/live/$HOST/privkey.pem" ;;
    2) install_cert_files "$HOST" || return 1
       FINAL_CRT="/etc/nginx/ssl/$HOST/fullchain.pem"; FINAL_KEY="/etc/nginx/ssl/$HOST/privkey.pem" ;;
    3) [ "$HOST_KIND" = "ip" ] || die "Пункт 3 — для IP"
       issue_cert_le_ip "$HOST" "$LE_EMAIL" || return 1
       FINAL_CRT="/etc/letsencrypt/live/$HOST/fullchain.pem"; FINAL_KEY="/etc/letsencrypt/live/$HOST/privkey.pem" ;;
    4) issue_cert_selfsigned "$HOST" "$HOST_KIND" || return 1
       FINAL_CRT="/etc/nginx/ssl/$HOST/fullchain.pem"; FINAL_KEY="/etc/nginx/ssl/$HOST/privkey.pem" ;;
  esac

  # страница-приманка
  mkdir -p /var/www/html
  echo "<!doctype html><html><head><meta charset=utf-8><title>System</title></head><body><h1>System Operational</h1></body></html>" \
    > /var/www/html/index.html
  chown -R www-data:www-data /var/www/html 2>/dev/null || true

  # конфиг nginx
  local CONF_FILE="/etc/nginx/sites-available/${HOST}.conf"
  env_set MASTER_CONF "$CONF_FILE"
  if [ -f "$CONF_FILE" ]; then
    backup_file "$CONF_FILE"
    read -r -p "Конфиг уже существует, перезаписать? [y/N]: " a
    if [[ ! "$a" =~ ^[Yy] ]]; then
      warn "Существующий конфиг оставлен — новые локейшены добавляются через меню"
    else
      write_master_nginx_conf "$HOST" "$FINAL_CRT" "$FINAL_KEY" "$CONF_FILE"
    fi
  else
    write_master_nginx_conf "$HOST" "$FINAL_CRT" "$FINAL_KEY" "$CONF_FILE"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1
    ok "UFW: 80/443 открыты"
  fi
  log "Проверяю nginx..."
  local ngt; ngt="$(mktemp /tmp/.xmesh-nginx-t.XXXXXX)" || ngt=""   # V-04: не фиксированный путь в /tmp
  if [ -n "$ngt" ] && nginx -t 2>"$ngt"; then
    rm -f "$ngt"
    systemctl restart nginx && ok "Nginx работает"
    # дефолтный сайт сносим только когда наш конфиг точно работает:
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null
    systemctl reload nginx 2>/dev/null || true
  else
    err "nginx -t не прошёл:"; [ -n "$ngt" ] && sed 's/^/    /' "$ngt" >&2
    [ -n "$ngt" ] && rm -f "$ngt"
    return 1
  fi

  # панель
  echo ""
  install_3xui || warn "3X-UI не установлен — панель можно поставить позже вручную"
  panel_creds_dialog || warn "Доступ к панели не настроен — direct-группа не создана"

  # direct-группа (выход с IP мастер-узла через панель)
  local dport dpath
  read -r -p "Порт прямого inbound в панели [2083]: " dport; dport=${dport:-2083}
  is_port "$dport" || { err "Некорректный порт"; dport=2083; }
  read -r -p "Путь прямого входа [/direct]: " dpath; dpath=${dpath:-/direct}
  is_path "$dpath" || { err "Некорректный путь"; dpath=/direct; }
  env_set DIRECT_PORT "$dport"; env_set DIRECT_PATH "$dpath"
  if panel_call GET /panel/api/inbounds/list >/dev/null 2>&1; then
    panel_add_inbound_direct "$dport" "$dpath" || warn "Продолжаю без direct-группы"
    nginx_ensure_direct_location || warn "Продолжаю без direct-локейшена"
  else
    warn "Панель не отвечает — direct-группу можно создать позже (пункт 2 меню)"
  fi
  nginx_ensure_sub_location || warn "Раздача подписок не настроена"

  install_router_unit
  install_self
  install_watch_daemon

  echo ""
  hr
  ok "МАСТЕР-УЗЕЛ ГОТОВ"
  ok "  Домен/IP : $HOST"
  ok "  Конфиг   : $CONF_FILE"
  ok "  Серт     : $FINAL_CRT"
  ok "  Панель   : http://127.0.0.1:$(env_get PANEL_PORT) (снаружи закрыта, ходим через API)"
  ok "  Демон    : xmesh-watch (мониторинг нод, pin+failover)"
  [ "$CERT_MODE" = "3" ] && warn "IP-серт живёт 6 дней — не отключайте certbot.timer"
  [ "$CERT_MODE" = "4" ] && warn "Самоподписанный серт — на клиентах allowInsecure=true"
  echo "  Дальше: пункт 3 меню — добавить ноды; пункт 4 — группы; пункт 5 — пользователи."
  hr
  return 0
}

#=========================== ПРИВЯЗКА СУЩЕСТВУЮЩЕЙ УСТАНОВКИ ==================
bind_existing() {
  hr
  echo "ПРИВЯЗКА СУЩЕСТВУЮЩЕЙ УСТАНОВКИ (nginx и/или 3X-UI уже стоят)"
  hr
  command -v jq >/dev/null 2>&1 || { err "Нужен jq: apt-get install -y jq"; return 1; }
  ensure_dirs
  local HOST conf
  HOST=$(read_host "Домен/IP мастер-узла (как в nginx server_name): ")
  conf="/etc/nginx/sites-available/${HOST}.conf"
  [ -f "$conf" ] || read -r -p "Конфиг не найден по имени. Введите путь к конфигу nginx: " conf
  [ -f "$conf" ] || { err "Конфиг '$conf' не найден"; return 1; }
  env_set MASTER_HOST "$HOST"; env_set MASTER_CONF "$conf"
  ensure_xray_binary || return 1
  [ -f /etc/systemd/system/xmesh@.service ] || install_router_unit
  panel_creds_dialog || return 1
  local dport dpath
  read -r -p "Порт прямого inbound в панели [2083]: " dport; dport=${dport:-2083}
  read -r -p "Путь прямого входа [/direct]: " dpath; dpath=${dpath:-/direct}
  is_path "$dpath" || dpath=/direct
  env_set DIRECT_PORT "$dport"; env_set DIRECT_PATH "$dpath"
  panel_add_inbound_direct "$dport" "$dpath" || warn "Продолжаю без direct-группы"
  nginx_ensure_direct_location || warn "Продолжаю без direct-локейшена"
  nginx_ensure_sub_location || warn "Раздача подписок не настроена"
  install_router_unit
  install_self
  install_watch_daemon
  ok "Готово. Дальше: ноды (пункт 3), группы (пункт 4), пользователи (пункт 5)."
  return 0
}

#=========================== REALITY-СКАНЕР ===================================
reality_scan() {
  hr
  echo "Сканер маскировки Reality: ищем в подсети сайты с TLS1.3+h2,"
  echo "которые можно использовать как dest/SNI для ноды."
  hr
  local base oct1 oct2 oct3 pport results sni num
  while true; do
    read -r -p "Первые три октета подсети (напр. 5.188.100): " base || die "Ввод прерван"
    IFS='.' read -r oct1 oct2 oct3 <<<"$base"
    if [ -n "${oct1:-}" ] && [ -n "${oct2:-}" ] && [ -n "${oct3:-}" ] \
       && is_ipv4 "${oct1}.${oct2}.${oct3}.1"; then
      break
    fi
    err "Нужно три октета через точку, каждый 0-255"
  done
  read -r -p "Порт для скана [443]: " pport || die "Ввод прерван"; pport=${pport:-443}
  is_port "$pport" || { err "Некорректный порт"; return 1; }
  log "Сканирую ${oct1}.${oct2}.${oct3}.0/24:${pport} (1-2 минуты)..."
  scan_one() {
    local ip="${base}.$1" out proto alpn
    out=$(timeout 4 openssl s_client -connect "${ip}:${pport}" -servername "${ip}" -brief </dev/null 2>/dev/null) || return 0
    proto=$(printf '%s\n' "$out" | sed -n 's/^.*Protocol version: *//p' | head -n1)
    alpn=$(printf '%s\n' "$out" | sed -n 's/^.*ALPN protocols: *//p' | head -n1)
    [ "$proto" = "TLSv1.3" ] || return 0
    printf '%s\n' "$alpn" | grep -qw h2 || return 0
    printf '%s\n' "$ip"
  }
  export -f scan_one
  export base pport
  results=$(seq 1 254 | xargs -P 30 -I{} bash -c 'scan_one "$@"' _ {} 2>/dev/null | sort -t. -k4 -n | head -n 12)
  if [ -z "$results" ]; then
    warn "Кандидатов не найдено. Задайте SNI вручную при добавлении ноды (напр. www.microsoft.com)"
    return 0
  fi
  echo ""
  echo "Кандидаты (TLS1.3 + h2):"
  echo "$results" | nl -w2 -s') '
  echo ""
  warn "Лучше использовать ДОМЕН с хорошей репутацией; IP-кандидаты — допустимый запасной вариант."
  read -r -p "Применить кандидата к ноде? Введите номер (Enter — нет): " num
  [ -n "$num" ] || return 0
  sni=$(printf '%s\n' "$results" | sed -n "${num}p")
  [ -n "$sni" ] || { err "Нет такого номера"; return 1; }
  local n
  n=$(read_name "Имя ноды: ")
  node_apply_sni "$n" "$sni"
}

#=========================== ДИАГНОСТИКА ======================================
cert_enddate() {
  local crt="$1"
  [ -f "$crt" ] || { printf 'нет файла'; return 0; }
  openssl x509 -enddate -noout -in "$crt" 2>/dev/null | sed 's/notAfter=//'
}

show_diagnostics() {
  hr
  echo "СТАТУС МАСТЕР-УЗЛА"
  hr
  local host conf crt
  host=$(env_get MASTER_HOST); conf=$(env_get MASTER_CONF)
  echo "  Хост        : ${host:-не задан}"
  echo "  Конфиг nginx: ${conf:-не задан}"
  echo "  Nginx       : $(systemctl is-active nginx 2>/dev/null || echo unknown)"
  if [ -n "$conf" ] && [ -f "$conf" ]; then
    crt=$(grep -m1 'ssl_certificate ' "$conf" | awk '{print $2}' | tr -d ';')
    [ -n "$crt" ] && echo "  Серт до     : $(cert_enddate "$crt")"
  fi
  echo "  Панель x-ui : $(systemctl is-active x-ui 2>/dev/null || echo 'не установлена')"
  echo "  Демон watch : $(systemctl is-active xmesh-watch 2>/dev/null || echo 'не установлен')"
  echo ""
  echo "  Группы (группа | порт | primary | активная | ноды):"
  local gj g act
  shopt -s nullglob
  for gj in "$XMESH_GROUPS_DIR"/*.json; do
    g=$(jq -r '.name' "$gj" 2>/dev/null); [ -n "$g" ] || continue
    act=$(state_get "ACTIVE_${g}"); [ -n "$act" ] || act=$(jq -r '.primary // "-"' "$gj")
    printf '    %-10s :%s  primary=%-8s active=%-8s nodes=[%s]\n' \
      "$g" "$(jq -r '.listen_port' "$gj")" "$(jq -r '.primary // "-"' "$gj")" "$act" \
      "$(jq -r '.nodes | join(",")' "$gj")"
  done
  echo ""
  echo "  Подписок в /var/www/xmesh-subs: $(ls -1 "$XMESH_SUBS_DIR" 2>/dev/null | wc -l)"
  echo ""
  node_list
  if systemctl is-active --quiet xmesh-watch 2>/dev/null; then
    echo "  Последние события watch:"
    journalctl -u xmesh-watch -n 5 --no-pager 2>/dev/null | tail -n 5 | sed 's/^/    /'
  fi
  hr
}

#=========================== БЭКАП / ВОССТАНОВЛЕНИЕ ===========================
backup_create() {
  local out="/root/xmesh-backup-$(date +%F-%H%M).tar.gz" extra=""
  [ -d /etc/x-ui ] && extra="etc/x-ui"
  if ! tar czf "$out" -C / \
    --exclude="etc/xmesh/.panel.cookie" \
    etc/xmesh var/www/xmesh-subs var/lib/xmesh \
    usr/local/bin/xmesh-watch usr/local/bin/xray-mesh \
    etc/systemd/system/xmesh@.service etc/systemd/system/xmesh-watch.service \
    etc/nginx/sites-available etc/nginx/ssl etc/letsencrypt $extra 2>/dev/null; then
    err "tar не смог собрать бэкап (частичный файл удалён): $out"
    rm -f "$out"
    return 1
  fi
  # проверяем целостность: размер + читаемость всего архива
  if [ ! -s "$out" ] || ! tar tzf "$out" >/dev/null 2>&1; then
    err "Бэкап пустой/битый — удаляю: $out"
    rm -f "$out"
    return 1
  fi
  chmod 600 "$out"
  ok "Бэкап создан: $out ($(human_bytes "$(stat -c%s "$out")"))"
}

backup_restore() {
  local files f
  files=$(ls -1t /root/xmesh-backup-*.tar.gz 2>/dev/null)
  [ -n "$files" ] || { err "Бэкапов нет"; return 1; }
  echo "$files" | nl -w2 -s') '
  read -r -p "Номер архива: " n || { echo; return 1; }
  f=$(printf '%s\n' "$files" | sed -n "${n}p")
  [ -f "$f" ] || { err "Нет такого архива"; return 1; }
  warn "Восстановление перезапишет /etc/xmesh, nginx-конфиги, сертификаты, /etc/x-ui."
  read -r -p "Продолжить? Введите YES: " a || { echo; return 1; }
  [ "$a" = "YES" ] || { log "Отменено"; return 0; }
  # аудит №11: старые tar могут развернуть ../-пути — проверяем список членов
  # архива ДО распаковки (бэкапы создаём мы сами, но защита в глубину не лишняя)
  if tar -tzf "$f" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    err "Архив содержит небезопасные пути (../ или абсолютные) — восстановление отменено"
    return 1
  fi
  # №15 (аудит №1): symlink-члены не должны указывать НАРУЖУ. Легитимные
  # внутренние ссылки letsencrypt (live -> archive, оба в архиве) — остаются
  local rst; rst="$(mktemp -d /tmp/xmesh-restore.XXXXXX)" || { err "mktemp не удался"; return 1; }
  if ! tar xzf "$f" -C "$rst" --no-same-owner; then
    err "Архив битый"; rm -rf "$rst"; return 1
  fi
  esc="$(find "$rst" -type l 2>/dev/null | while read -r l; do
    lt="$(readlink -f "$l" 2>/dev/null || true)"
    case "$lt" in "$rst"|"$rst"/*) ;; *) echo "$l"; break ;; esac
  done)"
  if [ -n "$esc" ]; then
    err "Архив содержит symlink наружу (${esc#"$rst"/}) — восстановление отменено (№15)"
    rm -rf "$rst"; return 1
  fi
  cp -a "$rst"/. / || { err "Не удалось перенести файлы из временного каталога"; rm -rf "$rst"; return 1; }
  rm -rf "$rst"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true
  systemctl restart x-ui 2>/dev/null || true
  systemctl restart 'xmesh@*.service' 2>/dev/null || true
  systemctl restart xmesh-watch 2>/dev/null || true
  ok "Восстановлено из $f"
}

#=========================== МЕНЮ =============================================
menu_nodes() {
  echo "  1) Добавить ноду (по SSH, из этого окна)"
  echo "  2) Список нод"
  echo "  3) Тест нод (TCP + проверка выхода)"
  echo "  4) Удалить ноду"
  echo "  5) Сменить маскировку (SNI) у ноды"
  echo "  0) Назад"
  read -r -p "Выбор: " c || { echo; return 0; }
  case "$c" in
    1) node_add ;;
    2) node_list ;;
    3) node_test_menu ;;
    4) node_remove ;;
    5) local n s
       n=$(read_name "Имя ноды: ")
       read -r -p "Новый SNI (домен): " s
       node_apply_sni "$n" "$s" ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

menu_groups() {
  echo "  1) Создать группу (страна/пул нод)"
  echo "  2) Список групп"
  echo "  3) Пересобрать группу (конфиг + рестарт инстанса)"
  echo "  4) Удалить группу"
  echo "  0) Назад"
  read -r -p "Выбор: " c || { echo; return 0; }
  case "$c" in
    1) group_create ;;
    2) local gj g
       shopt -s nullglob
       hr
       for gj in "$XMESH_GROUPS_DIR"/*.json; do
         g=$(jq -r '.name' "$gj" 2>/dev/null); [ -n "$g" ] || continue
         echo "  $g: вход 127.0.0.1:$(jq -r '.listen_port' "$gj"), путь $(jq -r '.ws_path' "$gj"), ноды: $(jq -r '.nodes|join(", ")' "$gj"), primary: $(jq -r '.primary // "-"' "$gj")"
       done
       hr ;;
    3) group_rebuild "$(read_name 'Имя группы: ')" ;;
    4) group_delete ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

menu_users() {
  echo "  1) Добавить пользователя (+ подписка)"
  echo "  2) Список пользователей (с трафиком direct)"
  echo "  3) Удалить пользователя"
  echo "  0) Назад"
  read -r -p "Выбор: " c || { echo; return 0; }
  case "$c" in
    1) user_add ;;
    2) user_list ;;
    3) user_del ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

menu_subs() {
  echo "  1) Перевыпустить ВСЕ подписки"
  echo "  2) Показать ссылки подписок"
  echo "  0) Назад"
  read -r -p "Выбор: " c || { echo; return 0; }
  case "$c" in
    1) build_all_subs ;;
    2) sub_show_urls ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

menu_backup() {
  echo "  1) Создать бэкап"
  echo "  2) Восстановить из бэкапа"
  echo "  0) Назад"
  read -r -p "Выбор: " c || { echo; return 0; }
  case "$c" in
    1) backup_create ;;
    2) backup_restore ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

main_menu() {
  local host
  host=$(env_get MASTER_HOST); [ -n "$host" ] || host="не настроен"
  while true; do
    echo ""
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${GREEN}   XRAY MESH MANAGER v3.2.1 — мастер-узел (${host})${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo " 1) Полная установка мастер-узла (nginx + SSL + 3X-UI + слой нод)"
    echo " 2) Привязать существующую установку (nginx/3X-UI уже стоят)"
    echo " 3) Ноды"
    echo " 4) Группы выхода"
    echo " 5) Пользователи"
    echo " 6) Подписки"
    echo " 7) Reality-сканер (подобрать сайт-маскировку для ноды)"
    echo " 8) Диагностика и статус"
    echo " 9) Бэкап / восстановление"
    echo " 0) Выход"
    read -r -p "Выбор: " c || { echo; return 0; }
    case "$c" in
      1) full_install ;;
      2) bind_existing ;;
      3) menu_nodes ;;
      4) menu_groups ;;
      5) menu_users ;;
      6) menu_subs ;;
      7) reality_scan ;;
      8) show_diagnostics ;;
      9) menu_backup ;;
      0) exit 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== CLI (для демона) =================================
cli_switch() {  # <группа> <нода|"">
  local g="$1" node="${2-}"
  safe_name "$g" || { err "Некорректное имя группы: $g"; return 1; }
  [ -z "$node" ] || safe_name "$node" || { err "Некорректное имя ноды: $node"; return 1; }
  [ -f "$(group_file "$g")" ] || { err "Группа $g не найдена"; return 1; }
  group_apply "$g" "$node"
}

#=========================== САМОПРОВЕРКА =====================================
selftest() {
  local fails=0
  tf() { # <описание> <функция> <аргумент> <ожидание 0|1>
    local desc="$1" fn="$2" arg="$3" want="$4" got
    if "$fn" "$arg" 2>/dev/null; then got=0; else got=1; fi
    if [ "$got" = "$want" ]; then echo "  PASS: $desc"
    else echo "  FAIL: $desc"; fails=$((fails+1)); fi
  }
  echo "Самопроверка валидаторов и сборщиков:"

  tf "is_ipv4 1.2.3.4"          is_ipv4 "1.2.3.4" 0
  tf "is_ipv4 256.1.1.1"        is_ipv4 "256.1.1.1" 1
  tf "is_ipv4 1.2.3"            is_ipv4 "1.2.3" 1
  tf "is_ipv6 ::1"              is_ipv6 "::1" 0
  tf "is_domain example.com"    is_domain "example.com" 0
  tf "is_domain /etc/passwd"    is_domain "/etc/passwd" 1
  tf "is_port 443"              is_port "443" 0
  tf "is_port 70000"            is_port "70000" 1
  tf "is_port ; rm -rf"         is_port "; rm -rf" 1
  tf "is_path /de-ws"           is_path "/de-ws" 0
  tf "is_path de-ws"            is_path "de-ws" 1
  tf "safe_name de1"            safe_name "de1" 0
  tf "safe_name ../etc"         safe_name "../etc" 1
  tf "is_email a@b.co"          is_email "a@b.co" 0
  tf "is_email a b@c.co"        is_email "a b@c.co" 1

  # хост: IP приоритетнее домена
  local hk; hk=$(host_kind "203.0.113.5")
  [ "$hk" = "ip" ] && echo "  PASS: host_kind сначала IP" || { echo "  FAIL: host_kind"; fails=$((fails+1)); }

  # временные каталоги
  local saved_dir="$XMESH_DIR" saved_state="$XMESH_STATE" saved_subs="$XMESH_SUBS_DIR" saved_lib="$XMESH_LIB_DIR" saved_env="$XMESH_ENV"
  XMESH_DIR=$(mktemp -d)
  XMESH_ENV="$XMESH_DIR/xmesh.env"
  XMESH_SSH_DIR="$XMESH_DIR/ssh"
  XMESH_NODES_DIR="$XMESH_DIR/nodes"; XMESH_GROUPS_DIR="$XMESH_DIR/groups"; XMESH_USERS_DIR="$XMESH_DIR/users"
  XMESH_SUBS_DIR=$(mktemp -d); XMESH_LIB_DIR=$(mktemp -d); XMESH_STATE="$XMESH_LIB_DIR/state.env"
  ensure_dirs
  env_set MASTER_HOST "mesh.example.com"
  env_set_secret TEST_SECRET "p@ss w:rd/сложно"
  [ "$(env_get_secret TEST_SECRET)" = "p@ss w:rd/сложно" ] \
    && echo "  PASS: env secret roundtrip" || { echo "  FAIL: env secret"; fails=$((fails+1)); }
  state_set ACTIVE_de de1; [ "$(state_get ACTIVE_de)" = "de1" ] \
    && echo "  PASS: state roundtrip" || { echo "  FAIL: state"; fails=$((fails+1)); }

  # сборка конфига группы: 2 ноды, primary=de1, активная=de2
  printf '{"name":"de","country":"Германия","listen_port":21001,"ws_path":"/de","primary":"de1","nodes":["de1","de2"],"revert":true}\n' > "$(group_file de)"
  mkdir -p "$XMESH_GROUPS_DIR/de"; printf '[]\n' > "$(group_clients de)"
  printf '{"name":"de1","group":"de","host":"1.2.3.4","ssh_port":22,"ssh_user":"root","port":443,"uuid":"11111111-1111-1111-1111-111111111111","pubkey":"PUB1","short_id":"abcd1234","sni":"www.microsoft.com","exit_ip":"1.2.3.4","probe_port":22001,"created":"2026-01-01"}\n' > "$(node_file de1)"
  printf '{"name":"de2","group":"de","host":"5.6.7.8","ssh_port":22,"ssh_user":"root","port":443,"uuid":"22222222-2222-2222-2222-222222222222","pubkey":"PUB2","short_id":"beefcafe","sni":"www.microsoft.com","exit_ip":"5.6.7.8","probe_port":22002,"created":"2026-01-01"}\n' > "$(node_file de2)"
  local cfg
  cfg=$(build_group_config de "de2") \
    && echo "  PASS: build_group_config" || { echo "  FAIL: build_group_config"; fails=$((fails+1)); }
  if [ -n "$cfg" ]; then
    local chk
    chk=$(printf '%s' "$cfg" | jq -r '.outbounds[0].tag' 2>/dev/null)
    [ "$chk" = "block" ] && echo "  PASS: block — первый outbound (дефолт)" || { echo "  FAIL: block first"; fails=$((fails+1)); }
    chk=$(printf '%s' "$cfg" | jq -r '[.routing.rules[] | select(.inboundTag[0]=="in-de")][0].outboundTag' 2>/dev/null)
    [ "$chk" = "out-de2" ] && echo "  PASS: правило in-de -> out-de2" || { echo "  FAIL: rule main"; fails=$((fails+1)); }
    chk=$(printf '%s' "$cfg" | jq -r '.inbounds | length' 2>/dev/null)
    [ "$chk" = "3" ] && echo "  PASS: inbound'ов 3 (main + 2 probe)" || { echo "  FAIL: inbounds=$chk"; fails=$((fails+1)); }
    chk=$(printf '%s' "$cfg" | jq -r '[.inbounds[] | select(.tag=="in-de")][0].settings.clients | length' 2>/dev/null)
    [ "$chk" = "0" ] && echo "  PASS: клиентов 0" || { echo "  FAIL: clients"; fails=$((fails+1)); }
  fi
  # пустая активная -> block
  cfg=$(build_group_config de "")
  chk=$(printf '%s' "$cfg" | jq -r '[.routing.rules[] | select(.inboundTag[0]=="in-de")][0].outboundTag' 2>/dev/null)
  [ "$chk" = "block" ] && echo "  PASS: активной нет -> block" || { echo "  FAIL: empty->block"; fails=$((fails+1)); }

  # ссылка группы
  local lnk
  lnk=$(link_group_user de "33333333-3333-3333-3333-333333333333" "u@mail.com")
  case "$lnk" in
    vless://33333333-3333-3333-3333-333333333333@mesh.example.com:443*path=%2Fde*)
      echo "  PASS: link_group_user" ;;
    *) echo "  FAIL: link_group_user ($lnk)"; fails=$((fails+1)) ;;
  esac

  # панельная ссылка (nginx-режим): клиент обязан получать 443 + tls
  local pin
  pin=$(jq -nc --arg s '{"network":"ws","security":"none","wsSettings":{"path":"/direct"}}' \
        '{listen:"127.0.0.1",port:2083,remark:"direct",
          settings:("{\"clients\":[{\"id\":\"UUID1\",\"email\":\"u\",\"flow\":\"\"}]}"),
          streamSettings:$s}')
  lnk=$(link_panel_user "$pin" "UUID1" "u@mail.com")
  case "$lnk" in
    vless://UUID1@mesh.example.com:443?*security=tls*path=%2Fdirect*)
      echo "  PASS: link_panel_user (nginx-режим: 443 + tls, порт панели скрыт)" ;;
    *) echo "  FAIL: link_panel_user ($lnk)"; fails=$((fails+1)) ;;
  esac

  rm -rf "$XMESH_DIR" "$XMESH_SUBS_DIR" "$XMESH_LIB_DIR"
  echo ""
  if [ "$fails" -eq 0 ]; then
    ok "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
    return 0
  fi
  err "Провалено проверок: $fails"
  return 1
}

#=========================== ТОЧКА ВХОДА ======================================
require_root() { [ "$(id -u)" -eq 0 ] || die "Запустите от root"; }

main() {
  case "${1:-}" in
    --switch)   require_root; cli_switch "${2:-}" "${3-}"; exit $? ;;
    --rebuild)  require_root; group_rebuild "${2:-}"; exit $? ;;
    --selftest) selftest; exit $? ;;
    "") ;;
    *) die "Использование: $0 [--selftest]" ;;
  esac
  require_root
  ensure_dirs
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
