
api_url() { printf '%s://127.0.0.1:%s%s' "${PANEL_SCHEME:-http}" "${PANEL_PORT}" "${PANEL_WBP}"; }

API_V3=0      # 1 = панель 3X-UI v3+ (CSRF + /panel/api/clients|setting|xray/*)
CSRF_TOKEN="" # токен сессии для POST (v3+); пусто = панель v2 — заголовок не ставим

curl_panel() { # curl к панели с учётом схемы (свой/самоподписанный серт = -k)
  local -a a=(-s)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  curl "${a[@]}" "$@"
}

csrf_fetch() { # GET <base>/csrf-token -> CSRF_TOKEN (v3+; v2: роута нет, пусто)
  local out
  # -b -c: отправляем текущую сессию И обновляем jar (повторный вызов после
  # логина обязан привязать новый токен к АВТОРИЗОВАННОЙ сессии)
  out="$(curl_panel --max-time 8 -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$(api_url)csrf-token" 2>/dev/null)" || return 0
  if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    CSRF_TOKEN="$(jq -r '.obj // ""' <<<"$out" 2>/dev/null || true)"
  fi
  return 0
}

kit_login() {
  COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
  local url rc code out resp
  url="$(api_url)login"
  # 3X-UI v3+: POST /login без CSRF-токена = 403 с ПУСТЫМ телом. GET /csrf-token
  # создаёт сессию и возвращает токен (как у браузера); v2: 404 — без заголовка
  csrf_fetch
  resp="$(mktemp /tmp/xkit-login.XXXXXX)"; chmod 600 "$resp"
  local -a h=()
  [ -n "$CSRF_TOKEN" ] && h+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  # V-03 (аудит №2): тело через stdin (--data @-) — пароль не светится в argv
  local body
  body="username=$(jq -rn --arg v "${PANEL_USER:-}" '$v|@uri')&password=$(jq -rn --arg v "${PANEL_PASS:-}" '$v|@uri')"
  rc=0
  code="$(printf '%s' "$body" | curl_panel --max-time 8 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -o "$resp" -w '%{http_code}' -X POST "${h[@]}" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data @- "$url")" || rc=$?
  out="$(cat "$resp" 2>/dev/null || true)"; rm -f "$resp"
  if [ "$rc" -ne 0 ]; then
    err "Панель не отвечает (127.0.0.1:${PANEL_PORT}, curl exit ${rc}) — проверьте: systemctl status x-ui"
    return 1
  fi
  if [ "$code" = "403" ]; then
    err "Панель отклонила запрос (403: CSRF-мiddleware) — устаревший xkit для этой версии 3X-UI"
    err "Обновите меню:  xkit update  (или скачайте свежий xkit.sh из репозитория)"
    return 1
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "Не удалось войти в API панели (127.0.0.1:${PANEL_PORT}${PANEL_WBP}login, HTTP ${code})"
    if [ -n "$out" ]; then
      err "Ответ: $(head -c 300 <<<"$out")"
    else
      err "Тело ответа пустое (HTTP ${code}) — нестандартная сборка 3X-UI или прокси перед панелью"
    fi
    err "Проверьте логин/пароль панели (install-result.env или меню панели x-ui)"
    return 1
  fi
  # v4.9.1: после логина панель ЧИСТИТ сессию (SetLoginUser -> s.Clear()) —
  # CSRF-токен анонимной сессии аннулирован, и все POST вернули бы 403.
  # Переполучаем токен уже от АВТОРИЗОВАННОЙ сессии — как делает и фронтенд панели
  csrf_fetch
  return 0
}

api_get() {
  local url; url="$(api_url)panel/api/inbounds/$1"
  if [ "${PANEL_SCHEME:-http}" = "https" ]; then curl -sk --max-time 10 -b "$COOKIE_JAR" "$url"
  else curl -s --max-time 10 -b "$COOKIE_JAR" "$url"; fi
}

api_post() { # $1 путь, $2 JSON-тело (пусто = без тела)
  local url; url="$(api_url)panel/api/inbounds/$1"
  local -a args=(-s --max-time 15 -b "$COOKIE_JAR" -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "$CSRF_TOKEN" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  if [ -n "${2:-}" ]; then
    curl "${args[@]}" -H 'Content-Type: application/json' -d "$2" "$url"
  else
    curl "${args[@]}" "$url"
  fi
}

api_list() {
  local out
  out="$(api_get list)" || { err "Панель не отвечает на запрос списка инбаундов"; return 1; }
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "API list: $(jq -r '.msg // "неожиданный ответ (проверьте версию 3x-ui)"' <<<"$out" | head -c 200)"
    return 1
  fi
  jq '.obj // []' <<<"$out"
}

# полный JSON одного инбаунда по id
api_get_inbound() {
  local out
  out="$(api_get "get/$1")" || return 1
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1 || return 1
  jq '.obj' <<<"$out"
}

# обновить инбаунд целиком (панель применит listen/streamSettings)
api_update_inbound() { # $1 id, $2 полный JSON инбаунда
  local resp
  resp="$(api_post "update/$1" "$2")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "update инбаунда #$1: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# удалить инбаунд целиком (3x-ui API: POST /panel/api/inbounds/del/:id)
api_del_inbound() { # $1 id
  local resp
  resp="$(api_post "del/$1" "")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "del инбаунда #$1: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

api_post_json() { # $1 путь от base, $2 JSON-тело — для эндпоинтов вне /panel/api/inbounds
  local url; url="$(api_url)${1#/}"
  local -a args=(-s --max-time 20 -b "$COOKIE_JAR" -X POST -H 'Content-Type: application/json')
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "$CSRF_TOKEN" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  curl "${args[@]}" -d "$2" "$url"
}

# v4.9.1: 3X-UI v3 перенёс клиентов в /panel/api/clients/*:
#   add     POST /panel/api/clients/add              {"client":{...},"inboundIds":[id]}
#   del     POST /panel/api/clients/del/:email
#   reset   POST /panel/api/clients/resetTraffic/:email
# (старые v2-пути inbounds/addClient, inbounds/:id/delClient/:cid в v3 УДАЛЕНЫ)
api_add_client() { # $1 id инбаунда, $2 JSON ОДНОГО клиента, $3 текущая строка settings (для v2)
  local id="$1" cj="$2" settings="$3" resp
  if [ "$API_V3" = "1" ]; then
    local body
    body="$(jq -nc --argjson c "$cj" --argjson i "$id" '{client:$c, inboundIds:[$i]}')"
    resp="$(api_post_json "panel/api/clients/add" "$body")" || return 1
  else
    local body new_settings
    new_settings="$(jq -c --argjson c "$cj" '.clients += [$c]' <<<"$settings")" || return 1
    body="$(jq -n --arg id "$id" --arg s "$new_settings" '{"id":($id|tonumber),"settings":$s}')"
    resp="$(api_post addClient "$body")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "addClient: $(jq -r '.msg // "ошибка"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

api_del_client() { # $1 id инбаунда, $2 email, $3 clientId (uuid; нужен только v2)
  local resp
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/clients/del/$2")" || return 1
  else
    resp="$(api_post "$1/delClient/$3" "")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "delClient: $(jq -r '.msg // "ошибка"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

# единая точка входа: залогиниться и получить список инбаундов
# результат в глобальной INBOUNDS (JSON-массив)
kit_session() {
  load_xkit_env || true
  read_panel_settings || return 1
  PANEL_SCHEME=$(detect_panel_scheme "$PANEL_PORT")
  kit_login || return 1
  api_detect_generation
  INBOUNDS="$(api_list)" || return 1
  return 0
}

# поколение API: GET /panel/api/openapi.json отвечает JSON-ом только в v3+
# (v2: 404/SPA). Лениво и без цензуры: не определили — считаем v2 (старые пути)
api_detect_generation() {
  local out
  API_V3=0
  out="$(api_get_raw "panel/api/openapi.json" 2>/dev/null || true)"
  if jq -e '.openapi' <<<"$out" >/dev/null 2>&1; then
    API_V3=1
    log "Панель 3X-UI v3: клиенты/настройки через /panel/api/clients|setting|xray/*"
  fi
  return 0
}
