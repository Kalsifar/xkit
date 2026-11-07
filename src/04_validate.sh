
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
  [[ "$1" =~ ^[0-9a-fA-F:]{2,45}$ ]] && [[ "$1" == *:* ]] || return 1
  # точная валидация inet_pton (regex пропускает a::b::c и «1234:», аудит №10);
  # python3 — зависимость (п.15), без него — фолбэк: двойное «::» невалидно
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket,sys; socket.inet_pton(socket.AF_INET6, sys.argv[1])' "$1" >/dev/null 2>&1
  else
    # №7 (аудит №1)/N-04 (№2): getent резолвит литерал ТОЛЬКО если это валидный
    # адрес (charset уже ограничен [0-9a-fA-F:] — DNS-имя сюда попасть не может)
    getent ahosts "$1" >/dev/null 2>&1
  fi
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_cidr() { # a.b.c.d/NN (0-32) или IPv6/NN (0-128) — для allow-списков nginx
  local ip="${1%%/*}" m="${1##*/}"
  [[ "$1" == */* ]] || return 1
  [[ "$m" =~ ^[0-9]{1,3}$ ]] || return 1
  if is_ipv4 "$ip"; then [ "$m" -le 32 ] 2>/dev/null
  elif is_ipv6 "$ip"; then [ "$m" -le 128 ] 2>/dev/null
  else return 1; fi
}

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_path() { [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$1" != *"//"* ]]; }

# Строгий location-путь для генерации nginx (K-01, аудит №2): панель/инбаунд/
# routes.tsv не должны уметь вставить директивы. Запрещены ~ (regex-маркер
# location), .. (alias-эскапада), // и * (модификатор location)
is_nginx_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] || return 1
  [[ "$1" != *"//"* && "$1" != *".."* && "$1" != *"~"* && "$1" != *"*"* ]]
}

# host:port / [v6]:port -> R_HOST/R_PORT (K-01; заодно F-3: IPv6-таргет
# раньше ломал domain_only="${target%%:*}" -> "[2001")
parse_hostport() {
  local s="$1"
  R_HOST=""; R_PORT=""
  case "$s" in
    \[*\]:*)
      R_HOST="${s%%]:*}"; R_HOST="${R_HOST#\[}"
      R_PORT="${s##*]:}"
      ;;
    *:*)
      [[ "$s" == *:*:* ]] && return 1   # голый IPv6 (несколько :) — только в скобках
      R_HOST="${s%%:*}"; R_PORT="${s##*:}"
      ;;
    *) return 1 ;;
  esac
  is_port "$R_PORT" || return 1
  case "$s" in
    \[*) is_ipv6 "$R_HOST" || return 1 ;;
    *)   is_ipv4 "$R_HOST" || is_hostname "$R_HOST" || return 1 ;;
  esac
  return 0
}

safe_conf_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

is_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# одно-меточное имя хоста без точки (localhost, relay-алиасы) — is_domain требует точку
is_hostname() { is_domain "$1" || [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

# СНАЧАЛА IP, потом домен: "1.2.3.4" проходит и доменную регулярку!
host_kind() { if is_ip "$1"; then echo "ip"; elif is_domain "$1"; then echo "domain"; else echo "bad"; fi }

# публичный IP этого сервера; если ответ не валидный IP (подмена/ошибка) — пусто
pubip() {
  local ip
  ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
  is_ip "$ip" || ip=""
  printf '%s' "$ip"
}

normalize_panel_path() {
  local p="$1"
  [ -n "$p" ] || p="/"
  case "$p" in /*) ;; *) p="/${p}" ;; esac
  case "$p" in */) ;; *) p="${p}/" ;; esac
  printf '%s' "$p"
}

read_host() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_domain "$v" || is_ip "$v"; then printf '%s' "$v"; return 0; fi
    err "Некорректно: '$v'. Нужен домен или IP — без http://, путей и портов"
  done
}

# ревью v4.9.0 (живая установка): адрес сервера раньше просили набрать вслепую —
# реальный IP на экране не показывался. Теперь определяем pubip и показываем его
# как пункт 1 (Enter = согласиться); 2 — свой домен/другой IP вручную.
# Результат — в глобальной CHOSEN_HOST (stdout занят меню, $() не использовать)
choose_host() {
  local prompt="${1:-Адрес этого сервера}" myip a
  myip="$(pubip)"
  if [ -z "$myip" ]; then
    warn "Публичный IP не определился (api.ipify.org недоступен?) — введите адрес вручную"
    CHOSEN_HOST="$(read_host "$prompt (домен/IP) -> ")"
    return 0
  fi
  echo ""
  echo -e "${YELLOW}${prompt}:${NC}"
  echo "1) IP этого сервера — $myip (определён автоматически)"
  echo "2) Свой домен или другой IP (ввести вручную)"
  while true; do
    read -r -p "Ваш выбор [1]: " a || { echo; a="1"; }
    case "${a:-1}" in
      1) CHOSEN_HOST="$myip"; return 0 ;;
      2) CHOSEN_HOST="$(read_host "Домен или IP -> ")"; return 0 ;;
      *) err "Пункт 1 или 2" ;;
    esac
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
    err "Путь: начинается с /, буквы/цифры/._~/- (без пробелов)"
  done
}

#=========================== СЛУЧАЙНОСТИ ======================================
rand_str() { # [длина] -> [a-zA-Z0-9]; запас входа x3 + доводка циклом: длина всегда точная,
             # head в пайпе нет -> SIGPIPE не роняет цепочку (аудит №9), энтропия base64 сохранена
  local n="${1:-32}" s
  s="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  while [ "${#s}" -lt "$n" ]; do
    s+="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  done
  printf '%s' "${s:0:$n}"
}
rand_hex() { openssl rand -hex "$1" 2>/dev/null; }

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else
    # fallback в корректном формате UUID 8-4-4-4-12
    printf '%s-%s-%s-%s-%s' "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 6)"
  fi
}

port_busy() { ss -ltnH 2>/dev/null | awk -v p=":$1 " 'index($4, p)' | grep -q .; }

rand_free_port() {
  local lo="${1:-20000}" hi="${2:-60000}" p i
  for i in $(seq 1 100); do
    p=$(shuf -i "${lo}-${hi}" -n 1 2>/dev/null) || return 1
    if ! port_busy "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

enc_uri() { jq -rn --arg s "$1" '$s|@uri'; }
# как enc_uri, но '/' не кодируется — пути в ссылках остаются читаемыми (/xk-ws-2083/)
enc_uri_path() { jq -rn --arg s "$1" '$s|@uri' | sed 's/%2F/\//gi'; }

#=========================== ХЕЛПЕРЫ NGINX ====================================
nginx_ver() { nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p'; }

ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# синтаксис http2 под версию nginx (Ubuntu 24.04 = 1.24 -> старый синтаксис)
# $1 = "v6" -> строка listen для IPv6. ВАЖНО: двоеточие в [::]:443 обязательно
# (без него nginx -t падает — invalid parameter; ревью v4.6.0). «http2 on;»
# (новый синтаксис) выводится ТОЛЬКО в v4-строке: дубль дал бы duplicate
# directive; при старом синтаксисе http2 встроен в сам listen
build_h2_block() {
  local ver addr=""
  [ "${1:-}" = "v6" ] && addr="[::]:"
  ver=$(nginx_ver)
  if [ -n "$ver" ] && ver_ge "$ver" "1.25.1"; then
    if [ -n "$addr" ]; then
      printf '    listen [::]:443 ssl;'
    else
      printf '    listen 443 ssl;\n    http2 on;'
    fi
  else
    printf '    listen %s443 ssl http2;' "$addr"
  fi
}

# слушать ли IPv6 (А3: v6-only клиенты за CGNAT не достучатся без [::]:443):
# глобальный v6-адрес на сервере; XKIT_V6_LISTEN=0|1|auto — принудительно
v6_listen_enabled() {
  case "${XKIT_V6_LISTEN:-auto}" in
    0|false|no)  return 1 ;;
    1|true|yes)  return 0 ;;
  esac
  ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}
