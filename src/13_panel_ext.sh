
#=========================== v4.1: API-РАСШИРЕНИЯ =============================
api_get_raw() {
  local url; url="$(api_url)$1"
  local -a a=(-s --max-time 10 -b "$COOKIE_JAR")
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  curl "${a[@]}" "$url"
}

api_post_raw() { # $1 путь, остальные — аргументы curl (--data-urlencode k=v ...)
  local p="$1"; shift
  local url; url="$(api_url)${p#/}"
  local -a a=(-s --max-time 20 -b "$COOKIE_JAR" -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  [ -n "$CSRF_TOKEN" ] && a+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  curl "${a[@]}" "$url" "$@"
}

# v4.9.1: в 3X-UI v3 externalProxy у инбаунда ВЫВЕДЕН — вместо него host-группы
# /panel/api/hosts ( remark "xkit", адрес+порт+security). Апдейт по groupId, если
# группа уже есть — без дублей при повторном запуске.
v3_host_upsert() { # $1 id инбаунда, $2 адрес, $3 порт, $4 security (tls|same|reality)
  local id="$1" addr="$2" eport="$3" sec="$4" resp gid body
  body="$(jq -nc --argjson ids "[${id}]" --arg a "$addr" --argjson p "$eport" --arg s "$sec" \
    '{inboundIds:$ids, remark:"xkit", hosts:[$a], port:$p, security:$s}')"
  resp="$(api_get_raw "panel/api/hosts/list" 2>/dev/null || true)"
  # №18 (аудит №1): нестандартный ответ (строка/массив вместо объекта) —
  # поиск groupId молча не найдёт группу => hosts/add создаст ДУБЛЬ. Честно предупредить
  if [ -n "$resp" ] && ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then
    warn "hosts/list: нестандартный ответ панели — возможен дубль host-группы (проверьте панель)"
  fi
  gid="$(jq -r --argjson id "$id" \
    '[.obj[]? | select(((.inboundIds // []) | index($id)) and ((.remark // "") == "xkit"))][0].groupId // empty' \
    <<<"$resp" 2>/dev/null || true)"
  if [ -n "$gid" ]; then
    resp="$(api_post_json "panel/api/hosts/update/${gid}" "$body")"
  else
    resp="$(api_post_json "panel/api/hosts/add" "$body")"
  fi
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1
}

panel_settings_get() {
  local out
  if [ "$API_V3" = "1" ]; then
    # v3: /panel/api/setting/all только POST (и возвращает browser-safe view:
    # секреты скрыты, но sub*/xray-поля на месте)
    out="$(api_post_json "panel/api/setting/all" "{}")"
  else
    out="$(api_get_raw "panel/setting/all")"
    if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      out="$(api_post_raw "panel/setting/all")"
    fi
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "panel settings: $(jq -r '.msg // "нет ответа"' <<<"$out" 2>/dev/null | head -c 200)"
    return 1
  fi
  printf '%s' "$out"
}

panel_settings_set() { # пары key=value (form-urlencoded, панель обновит только их)
  local -a args=()
  local kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  local resp p
  if [ "$API_V3" = "1" ]; then p="panel/api/setting/update"; else p="panel/setting/update"; fi
  resp="$(api_post_raw "$p" "${args[@]}")"
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "${p}: $(jq -r '.msg // "нет ответа"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

panel_restart() {
  local p out
  # v3: /panel/api/setting/restartPanel; v2: panel/setting/restartPanel, server/restartPanel
  for p in "panel/api/setting/restartPanel" "panel/setting/restartPanel" "server/restartPanel"; do
    out="$(api_post_raw "$p")" || true
    if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      ok "Панель перезапускается..."
      sleep 3
      kit_login >/dev/null 2>&1 || true
      return 0
    fi
  done
  warn "Перезапуск панели через API не удался (можно вручную: x-ui restart panel)"
  return 1
}

xray_restart() {
  if api_post_raw "panel/api/server/restartXrayService" >/dev/null 2>&1; then
    ok "Xray перезапущен"
  else
    warn "Не удалось перезапустить xray через API"
  fi
  return 0
}

api_add_inbound() { # $1 полный JSON инбаунда
  local resp
  resp="$(api_post add "$1")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "add inbound: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# пара ключей x25519 "private public" (API панели, фолбэк — локальный xray)
api_get_new_x25519() {
  local out priv pub xr pair
  out="$(api_get_raw "panel/api/server/getNewX25519Cert")"
  priv="$(jq -r '.obj.privateKey // .obj.private_key // empty' <<<"$out" 2>/dev/null)"
  pub="$(jq -r '.obj.publicKey // .obj.public_key // empty' <<<"$out" 2>/dev/null)"
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    xr="$(ls -1 /usr/local/x-ui/bin/xray-* 2>/dev/null | head -n1)"
    [ -n "$xr" ] || { err "Не могу сгенерировать x25519 (нет API и нет бинарника xray)"; return 1; }
    pair="$("$xr" x25519 2>/dev/null)" || { err "xray x25519 не сработал"; return 1; }
    priv="$(awk '/Private/{print $NF}' <<<"$pair")"
    pub="$(awk '/Public/{print $NF}' <<<"$pair")"
  fi
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  printf '%s %s\n' "$priv" "$pub"
}

#=========================== v4.1: ПОДПИСКИ САМОЙ ПАНЕЛИ ======================
# Нативный sub-сервис 3X-UI вешаем на 127.0.0.1:ПОРТ и проксируем через nginx.
# В панели при этом корректный URL: https://ДОМЕН/sub-<token>/<subId>
ensure_panel_sub_settings() {
  local all cur_port cur_path
  all="$(panel_settings_get)" || return 1
  cur_port="$(jq -r '.obj.subPort // ""' <<<"$all")"
  cur_path="$(jq -r '.obj.subPath // ""' <<<"$all")"

  if [ -z "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "$cur_port" ] && is_port "$cur_port" && [ "$cur_port" != "0" ]; then
    XKIT_PANEL_SUB_PORT="$cur_port"
  fi
  [ -n "${XKIT_PANEL_SUB_PORT:-}" ] || XKIT_PANEL_SUB_PORT="$(rand_free_port 30000 50000)" \
    || { err "Нет свободного порта для подписок"; return 1; }
  if [ -z "${XKIT_PANEL_SUB_PATH:-}" ]; then
    if [ -n "$cur_path" ] && is_nginx_path "$(normalize_panel_path "$cur_path")"; then
      XKIT_PANEL_SUB_PATH="$(normalize_panel_path "$cur_path")"
    else
      [ -n "$cur_path" ] && warn "subPath панели «${cur_path:0:40}» нестандартный — генерирую свой (K-01)"
      XKIT_PANEL_SUB_PATH="/sub-${XKIT_SUB_TOKEN:-$(rand_str 8)}/"
    fi
  fi

  log "Подписки панели: 127.0.0.1:${XKIT_PANEL_SUB_PORT}${XKIT_PANEL_SUB_PATH} -> https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}"
  panel_settings_set \
    "subEnable=true" \
    "subPort=${XKIT_PANEL_SUB_PORT}" \
    "subPath=${XKIT_PANEL_SUB_PATH}" \
    "subListen=127.0.0.1" \
    "subDomain=${XKIT_HOST}" \
    "subURI=https://${XKIT_HOST}" || return 1
  ok "Настройки подписок панели применены"
  panel_restart || true
  save_xkit_env
  return 0
}

#=========================== v4.1: КОРРЕКТНЫЕ ССЫЛКИ В ПАНЕЛИ =================
# externalProxy каждому инбаунду: панель генерирует ссылки и QR с
# https://ДОМЕН:443/путь (за nginx) либо ДОМЕН:ПОРТ (direct: Reality и т.п.)
external_proxy_fix() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  kit_session || return 1
  routes_load

  echo ""
  log "Шаг 1/2: нативные подписки 3X-UI через nginx..."
  ensure_panel_sub_settings || return 1

  echo ""
  log "Шаг 2/2: externalProxy на инбаундах (панель покажет ДОМЕН, а не 127.0.0.1)..."
  if [ -t 0 ] && [ "${XKIT_YES:-0}" != "1" ]; then
    read -r -p "Проставить externalProxy ws/grpc/xhttp-инбаундам? (Reality/прямые НЕ трогаем) [Y/n]: " a
    [[ "$a" =~ ^[Nn] ]] && { log "Отменено"; return 0; }
  fi
  local fixed=0 same=0 ib id port mode eport cur new patched sec
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    IFS='|' read -r mode _ _ <<<"$(route_info "$id")"
    if [ "$sec" = "reality" ] || [ "$mode" = "direct" ]; then
      same=$((same+1)); continue   # прямым инбаундам (Reality/relay) externalProxy не нужен
    fi
    if [ "$mode" = "local" ]; then eport=443; else eport="$port"; fi
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; апдейт идемпотентен (по groupId)
      if v3_host_upsert "$id" "$XKIT_HOST" "$eport" "tls"; then
        ok "#$id: внешний адрес ${XKIT_HOST}:${eport} (hosts)"
        fixed=$((fixed+1))
      else
        err "#$id: host-группа не применилась"
      fi
      continue
    fi
    cur="$(jq -c '.externalProxy // []' <<<"$ib")"
    new="$(jq -nc --arg d "$XKIT_HOST" --argjson p "$eport" '[{"dest":$d,"port":$p,"remark":"xkit"}]')"
    if [ "$cur" = "$new" ]; then same=$((same+1)); continue; fi
    patched="$(jq -c --argjson ep "$new" '.externalProxy = $ep' <<<"$ib")"
    if api_update_inbound "$id" "$patched"; then
      ok "#$id: внешний адрес ${XKIT_HOST}:${eport}"
      fixed=$((fixed+1))
    else
      err "#$id: externalProxy не применился"
    fi
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  ok "Обновлено: $fixed; уже было корректно: $same"
  xray_restart
  sub_regen_quiet || true
  echo ""
  ok "Теперь ссылки/QR/sub URL в самой панели корректные:"
  ok "  подписка пользователя: https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}<subId>"
  ok "  файловые подписки xkit: https://${XKIT_HOST}$(sub_path)<subId>"
  return 0
}

#=========================== v4.1: REALITY ====================================
CAMO_DIR="/var/www/camo"

camo_site_install() {
  mkdir -p "$CAMO_DIR"
  cat > "${CAMO_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coming soon</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f7f8fa;color:#333}
  .card{max-width:560px;text-align:center;padding:48px 32px}
  h1{font-weight:600;font-size:28px;margin:0 0 12px}
  p{line-height:1.6;color:#666;margin:0}
  .dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#4a90d9;margin-right:8px}
</style>
</head>
<body>
  <div class="card">
    <h1><span class="dot"></span>Coming soon</h1>
    <p>Something new is on the way. This domain is reserved and will be
       launched shortly. Please check back later.</p>
  </div>
</body>
</html>
HTML
  chmod 644 "${CAMO_DIR}/index.html"
  ok "Сайт-прикрытие установлен: ${CAMO_DIR}/index.html"
}
