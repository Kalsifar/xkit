
#=========================== ПРОВЕРКА ОС ======================================
require_root() { [ "$EUID" -eq 0 ] || die "Запустите от root: sudo bash xkit.sh ..."; }

check_os() {
  local id="" ver=""
  if [ -f /etc/os-release ]; then
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  fi
  case "$id" in
    ubuntu)
      local major="${ver%%.*}"
      [ -n "$major" ] || major=0
      if [ "$major" -ge 24 ] 2>/dev/null; then
        ok "ОС: Ubuntu $ver — полностью поддерживается"
      else
        warn "ОС: Ubuntu $ver — рекомендован 24.04+, продолжаю"
      fi ;;
    debian) warn "ОС: Debian $ver — скрипт заточен под Ubuntu 24+, скорее всего тоже сработает" ;;
    *)      warn "ОС неопознана (${id} ${ver}) — скрипт рассчитан на Ubuntu 24+" ;;
  esac
  return 0
}

#=========================== 3X-UI: ХЕЛПЕРЫ ===================================
install_3xui_auto() {
  if command -v x-ui >/dev/null 2>&1; then
    warn "3X-UI уже установлен — использую текущие настройки"
    return 0
  fi
  log "Скачиваю официальный установщик 3X-UI (K-02: тег релиза, не master)..."
  local u; u="$(xui_install_url)"
  local dl; dl="$(mktemp /tmp/xkit-3xui.XXXXXX)" || die "mktemp не удался"
  curl -fsSL -o "$dl" "$u" \
    || { rm -f "$dl"; die "Не удалось скачать установщик 3X-UI (проверьте сеть)"; }
  bash -n "$dl" || { rm -f "$dl"; die "Скачанный установщик 3X-UI не проходит bash -n — отмена (K-02)"; }
  # (з.6, аудит v5.2.1): установка бежит от root — явное подтверждение, симметрия с node_add
  confirm "Запустить официальный установщик 3X-UI от root? [Y/n] " y \
    || { rm -f "$dl"; warn "Установка 3X-UI отменена"; return 1; }
  log "Устанавливаю 3X-UI в неинтерактивном режиме (случайные креды)..."
  if ! XUI_NONINTERACTIVE=1 bash "$dl" </dev/null; then
    rm -f "$dl"
    err "Установщик 3X-UI завершился с ошибкой"
    return 1
  fi
  rm -f "$dl"
  systemctl enable --now x-ui >/dev/null 2>&1 || true
  ok "3X-UI установлен"
  return 0
}

# PANEL_PORT / PANEL_WBP / PANEL_USER / PANEL_PASS из install-result.env
# (основной источник) или из `x-ui setting -show true` (запасной)
# значение из install-result.env БЕЗ source (аудит №8: файл пишет инсталлятор
# 3X-UI, но source произвольного файла — лишний вектор). Парсим построчно:
# снимаем surrounding-кавычки и CR, внутренности не трогаем
xui_env_val() { # $1 KEY, $2 файл -> значение
  # awk с точным сравнением $1==k: sed "s/^$1=//" трактовал метасимволы (& . * /)
  # в ключе как regex — с текущими статическими ключами безопасно, но awk
  # безопасен всегда (ревью v4.6.0); берём первое вхождение (exit)
  local v
  v="$(awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null)"
  v="${v%$'\r'}"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

read_panel_settings() {
  PANEL_PORT=""; PANEL_WBP=""; PANEL_USER=""; PANEL_PASS=""
  if [ -f "$XUI_RESULT" ]; then
    PANEL_PORT="$(xui_env_val XUI_PANEL_PORT "$XUI_RESULT")"
    PANEL_WBP="$(xui_env_val XUI_WEB_BASE_PATH "$XUI_RESULT")"
    PANEL_USER="$(xui_env_val XUI_USERNAME "$XUI_RESULT")"
    PANEL_PASS="$(xui_env_val XUI_PASSWORD "$XUI_RESULT")"
  fi
  if [ -z "$PANEL_PORT" ] || [ -z "$PANEL_WBP" ]; then
    if command -v x-ui >/dev/null 2>&1; then
      local s
      s=$(x-ui setting -show true 2>/dev/null || true)
      [ -z "$PANEL_PORT" ] && PANEL_PORT=$(echo "$s" | awk -F': ' '/port:/{print $2; exit}' | tr -d '[:space:]')
      [ -z "$PANEL_WBP" ]  && PANEL_WBP=$(echo "$s" | awk -F': ' '/webBasePath:/{print $2; exit}' | tr -d '[:space:]')
    fi
  fi
  [ -n "$PANEL_PORT" ] || { err "Не удалось определить порт панели 3X-UI"; return 1; }
  is_port "$PANEL_PORT" || { err "K-01: порт панели некорректен: ${PANEL_PORT:0:20}"; return 1; }
  PANEL_WBP=$(normalize_panel_path "$PANEL_WBP")
  is_nginx_path "$PANEL_WBP" || { err "K-01: webBasePath панели некорректен: ${PANEL_WBP:0:40}"; return 1; }
  return 0
}

# Панель слушает http или https на 127.0.0.1 (если инсталлятор выдал ей серт)
detect_panel_scheme() {
  local p="$1" code i
  for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "http"; return 0 ;; esac
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "https"; return 0 ;; esac
    sleep 2
  done
  warn "Панель не отвечает на 127.0.0.1:${p} — предполагаю http"
  echo "http"
}

# Панель должна слушать ТОЛЬКО 127.0.0.1 (webListen в БД панели).
# Если не выйдет (postgres / другая схема) — остаётся UFW deny.
force_panel_localhost() {
  local port="$1"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -f "$XUI_DB" ] || return 1
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key,value) VALUES ('webListen','127.0.0.1');" 2>/dev/null || return 1
  systemctl restart x-ui >/dev/null 2>&1 || return 1
  sleep 2
  # проверяем: слушает ли панель 0.0.0.0? (found=1 -> exit 0 -> exposed)
  if ss -ltnH 2>/dev/null | awk -v p=":${port} " '
      index($4, p) { if ($4 !~ /^127\.0\.0\.1/ && $4 !~ /^\[::1\]/) found=1 }
      END { exit (found ? 0 : 1) }'; then
    return 1
  fi
  return 0
}

#=========================== СОСТОЯНИЕ XKIT ===================================
save_xkit_env() {
  mkdir -p "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  chmod 700 "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  # запись в subshell (симметрично notify_state_set/dash_gen_locked, ревью
  # v4.6.0): umask 077 не утекает в вызывающую оболочку при любом сбое;
  # провал записи теперь честный — err + return 1, а не молчаливый ok
  (
    umask 077
    tmp="$(mktemp)" || exit 1
    {
      printf 'XKIT_VERSION=%q\n' "$XKIT_VERSION"
      printf 'XKIT_HOST=%q\n' "${XKIT_HOST:-}"
      printf 'XKIT_CRT=%q\n' "${XKIT_CRT:-}"
      printf 'XKIT_KEY=%q\n' "${XKIT_KEY:-}"
      printf 'XKIT_CERT_MODE=%q\n' "${XKIT_CERT_MODE:-}"
      printf 'XKIT_SUB_TOKEN=%q\n' "${XKIT_SUB_TOKEN:-}"
      printf 'XKIT_UFW=%q\n' "${XKIT_UFW:-0}"
      printf 'XKIT_PANEL_SUB_PORT=%q\n' "${XKIT_PANEL_SUB_PORT:-}"
      printf 'XKIT_PANEL_SUB_PATH=%q\n' "${XKIT_PANEL_SUB_PATH:-}"
      printf 'XKIT_REALITY_INTERNAL=%q\n' "${XKIT_REALITY_INTERNAL:-0}"
      printf 'XKIT_BAL_STRATEGY=%q\n' "${XKIT_BAL_STRATEGY:-roundRobin}"
      printf 'XKIT_POOL_INBOUND=%q\n' "${XKIT_POOL_INBOUND:-}"
      printf 'XKIT_POOL_TAG=%q\n' "${XKIT_POOL_TAG:-}"
      printf 'XKIT_REPO_URL=%q\n' "${XKIT_REPO_URL:-}"
      printf 'XKIT_DASH=%q\n' "${XKIT_DASH:-0}"
      printf 'XKIT_DASH_TOKEN=%q\n' "${XKIT_DASH_TOKEN:-}"
      printf 'XKIT_DASH_ALLOW=%q\n' "${XKIT_DASH_ALLOW:-}"
      printf 'XKIT_DASH_AUTH=%q\n' "${XKIT_DASH_AUTH:-1}"
      printf 'XKIT_DASH_USER=%q\n' "${XKIT_DASH_USER:-}"
      printf 'XKIT_DASH_PASS=%q\n' "${XKIT_DASH_PASS:-}"
      printf 'XKIT_TG_TOKEN=%q\n' "${XKIT_TG_TOKEN:-}"
      printf 'XKIT_TG_CHAT=%q\n' "${XKIT_TG_CHAT:-}"
      printf 'XKIT_TG_PROXY=%q\n' "${XKIT_TG_PROXY:-}"
    } > "$tmp"
    mv "$tmp" "$XKIT_ENV"
  ) || { err "Не удалось сохранить $XKIT_ENV"; return 1; }
  chmod 600 "$XKIT_ENV" 2>/dev/null
  ok "Состояние сохранено: $XKIT_ENV"
}

load_xkit_env() {
  XKIT_HOST=""; XKIT_CRT=""; XKIT_KEY=""; XKIT_CERT_MODE=""; XKIT_SUB_TOKEN=""; XKIT_UFW="0"
  XKIT_PANEL_SUB_PORT=""; XKIT_PANEL_SUB_PATH=""; XKIT_REALITY_INTERNAL="0"
  XKIT_BAL_STRATEGY="roundRobin"; XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  XKIT_DASH="0"; XKIT_DASH_TOKEN=""; XKIT_DASH_ALLOW=""
  XKIT_DASH_AUTH="1"; XKIT_DASH_USER=""; XKIT_DASH_PASS=""
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""
  local _repo="${XKIT_REPO_URL:-}"   # внешнее значение (от install.sh) не теряем
  XKIT_REPO_URL="$_repo"             # №22: фолбэк ДО чтения env — ранний return не теряет
  [ -r "$XKIT_ENV" ] || return 1
  # shellcheck disable=SC1090
  . "$XKIT_ENV"
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  return 0
}

# XKIT_SUB_PATH зависит от токена
sub_path() {
  printf '/s-%s/' "${XKIT_SUB_TOKEN:-CHANGE_ME}"
}

#=========================== МАРШРУТЫ (routes.tsv) ============================
# Формат: id<TAB>mode<TAB>net<TAB>path<TAB>target<TAB>tag
#   id:    id инбаунда панели (число) или m<rand> для ручных маршрутов
#   mode:  local (127.0.0.1) | relay (внешний сервер) | panel
#   net:   grpc | ws | xhttp | tcp | web
#   path:  внешний путь с слэшами /xk-ws-2083/
#   target:127.0.0.1:PORT | host:443
routes_load() {
  ROUTES=()
  [ -r "$XKIT_ROUTES" ] || return 0
  mapfile -t ROUTES < "$XKIT_ROUTES"
}

routes_upsert() { # $1..$6 поля строки
  local id="$1" line
  mkdir -p "$(dirname "$XKIT_ROUTES")" 2>/dev/null || true
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6")"
  if [ -f "$XKIT_ROUTES" ]; then
    awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
    mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
  fi
  printf '%s\n' "$line" >> "$XKIT_ROUTES"
  chmod 600 "$XKIT_ROUTES"
}

routes_del() {
  local id="$1"
  [ -f "$XKIT_ROUTES" ] || return 0
  awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
  mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
}

# путь для маршрута инбаунда: детерминированный, по типу транспорта и порту
auto_path_for() { # $1 net (ws|grpc|xhttp|hu|tc)  $2 port
  printf '/xk-%s-%s/' "$1" "$2"
}

#=========================== API ПАНЕЛИ (REST) ================================
# Слой для клиентов/автопроброса/подписок. Все ответы панель отдаёт как
# {"success":true/false,"msg":"...","obj":...}. Всё defensively через jq:
# если формат API когда-нибудь поменяется — увидите понятную ошибку.
#
# ПОКОЛЕНИЯ API (v4.9.1): 3X-UI v3.x (2026) закрыл ВСЕ POST-запросы
# CSRF-мiddleware'ом (без X-CSRF-Token — ответ 403 С ПУСТЫМ телом) и перенёс
# клиентские эндпоинты в /panel/api/clients/*, настройки — в /panel/api/setting/*,
# xray-шаблон — в /panel/api/xray/*. API_V3 определяется в kit_session по
# GET /panel/api/openapi.json (есть только в v3). На v2 всё по-старому.
