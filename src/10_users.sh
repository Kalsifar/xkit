
#=========================== ПОДПИСКИ =========================================
sub_regen_quiet() { SUB_QUIET=1 sub_regen; }
# flock-обёртка (аудит №5): cron «13 * * * * xkit sub -q» и ручной запуск не должны
# пересекаться — иначе rm -f ${SUBS_DIR}/* + пересборка дают окно 404/битого base64.
# non-blocking: второй процесс тихо пропускает (cron повторит в следующий час).
sub_regen() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  { flock -n 9 || { [ "${SUB_QUIET:-0}" = "1" ] || warn "Подписки уже пересобираются другим процессом — пропуск"; return 0; }
    sub_regen_impl
  } 9>"${XKIT_DIR}/.sub_regen.lock"
}
sub_regen_impl() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  log "Формирую подписки из данных панели..."
  kit_session || return 1
  routes_load

  mkdir -p "$SUBS_DIR"
  # 750 root:www-data (а не 755): содержимое читает только nginx, не все локальные юзеры
  chgrp www-data /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  rm -f "${SUBS_DIR:?}"/* 2>/dev/null
  local idx="${XKIT_DIR}/subs.index"
  : > "$idx"; chmod 600 "$idx"

  local n_links=0 n_subs=0
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local id port proto tag
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"; tag="$(jq -r '.tag // "inbound"' <<<"$ib")"

    # клиенты инбаунда (+ одиночный пользователь для shadowsocks)
    local -a clients=()
    mapfile -t clients < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "$proto" = "shadowsocks" ] && [ "${#clients[@]}" -eq 0 ]; then
      clients=("$(jq -nc --arg p "$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")" --arg t "$tag" '{password:$p,email:$t}')")
    fi
    [ "${#clients[@]}" -gt 0 ] || continue

    local cl
    for cl in "${clients[@]}"; do
      local email subid link
      email="$(jq -r '.email // "user"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] || continue
      n_links=$((n_links+1))
      if [ -n "$subid" ]; then
        printf '%s\n' "$link" >> "${SUBS_DIR}/.acc.${subid}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$subid" "$email" "${tag:0:20}" "$proto" "$port" >> "$idx"
      fi
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  # баз64-файлы по subId
  local acc f subid
  for acc in "${SUBS_DIR}"/.acc.*; do
    [ -e "$acc" ] || break
    subid="${acc##*.acc.}"
    f="${SUBS_DIR}/${subid}"
    sort -u "$acc" | tr '\n' '\n' | base64 -w0 > "$f"
    rm -f "$acc"
    chmod 644 "$f"
    n_subs=$((n_subs+1))
  done

  if [ "${SUB_QUIET:-0}" != "1" ]; then
    ok "Подписки собраны: ссылок $n_links, файлов подписок $n_subs"
    sub_show
  else
    ok "Подписки: ссылок $n_links, файлов $n_subs"
  fi
  return 0
}

# показать URL подписок (по одному на subId)
sub_show() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local idx="${XKIT_DIR}/subs.index"
  [ -s "$idx" ] || { warn "Подписок ещё нет — создайте пользователей (пункты 4-6) и выполните пункт 2"; return 0; }
  local sp; sp="$(sub_path)"
  echo ""
  log "URL подписок (вставить в клиент: v2rayNG / Streisand / Hiddify / v2rayN):"
  awk -F'\t' '{print $1"\t"$2"\t"$3}' "$idx" | sort -u | while IFS=$'\t' read -r subid email tag; do
    printf '  %-18s %-18s https://%s%s%s\n' "${subid:0:18}" "${email}" "$XKIT_HOST" "$sp" "$subid"
  done
  echo ""
  log "Формат: base64-список vless/vmess/trojan/ss ссылок (стандарт v2ray-подписок)"
}

#=========================== ПОЛЬЗОВАТЕЛИ (клиенты) ===========================
list_inbounds_menu() { # показывает нумерованный список, результат в PICK_IB (JSON)
  local i=0 line
  local -a rows=()
  echo ""
  printf '%-3s %-4s %-22s %-9s %-6s %s\n' "#" "ID" "TAG" "PROTO" "PORT" "РЕЖИМ"
  echo "------------------------------------------------------------------------"
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local rid rmode
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    i=$((i+1))
    rows+=("$ib")
    printf '%-3s %-4s %-22s %-9s %-6s %s\n' "$i" "$(jq -r '.id' <<<"$ib")" \
      "$(jq -r '.tag // "inbound"' <<<"$ib" | cut -c1-22)" "$(jq -r '.protocol' <<<"$ib")" \
      "$(jq -r '.port' <<<"$ib")" "$([ "$rmode" = "local" ] && echo "за nginx" || echo "direct")"
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$i" -eq 0 ] && { warn "Активных инбаундов нет — создайте в панели (пункт 2 потом их пробросит)"; return 1; }
  read -r -p "Номер инбаунда [1-$i]: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { err "Нет такого номера"; return 1; }
  PICK_IB="${rows[$((n-1))]}"
  return 0
}

client_add() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  list_inbounds_menu || return 1
  local ib="$PICK_IB"
  local id port proto sec
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"

  local settings email uuid subid total=0 days=0 flow=""
  settings="$(jq -r '.settings' <<<"$ib")"
  jq -e . <<<"$settings" >/dev/null 2>&1 || { err "settings инбаунда #$id не парсятся как JSON — обновите 3x-ui"; return 1; }
  read -r -p "Имя (email) пользователя [u$(rand_hex 2)]: " email
  email="${email:-u$(rand_hex 2)}"
  # таб/перевод строки ломают subs.index (awk -F'\t') — вырезаем; остальное — предупреждение
  email="${email//$'\t'/}"; email="${email//$'\r'/}"; email="${email//$'\n'/}"; email="${email// /}"
  [[ "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] || warn "Имя содержит нестандартные символы — лучше только A-Za-z0-9._@+-"
  read -r -p "Квота трафика, ГБ (0 = без лимита) [0]: " total; total="${total:-0}"
  read -r -p "Срок жизни, дней (0 = бессрочно) [0]: " days; days="${days:-0}"
  if [ "$sec" = "reality" ] && [ "$proto" = "vless" ]; then
    read -r -p "Flow [xtls-rprx-vision]: " flow; flow="${flow:-xtls-rprx-vision}"
  fi
  uuid="$(new_uuid)"
  subid="$(rand_str 16)"

  local expiry=0 gb=0
  [ "$days" -gt 0 ] 2>/dev/null && expiry=$(( $(date +%s) * 1000 + days * 86400000 ))
  [ "$total" -gt 0 ] 2>/dev/null && gb=$(( total * 1073741824 ))

  local cj
  if [ "$proto" = "trojan" ] || [ "$proto" = "shadowsocks" ]; then
    cj="$(jq -nc --arg id "$uuid" --arg pass "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, password:$pass, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  else
    cj="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  fi

  log "Добавляю пользователя через API панели..."
  if ! api_add_client "$id" "$cj" "$settings"; then return 1; fi
  ok "Пользователь '$email' добавлен в инбаунд #$id"

  # свежая ссылка + подписка
  local link
  link="$(link_for_client "$ib" "$cj")"
  [ -n "$link" ] && { echo ""; ok "Ссылка для клиента (или в подписке ниже):"; printf '  %s\n' "$link"; }
  sub_regen_quiet || true
  local sp; sp="$(sub_path)"
  echo ""
  ok "Подписка этого пользователя: https://${XKIT_HOST}${sp}${subid}"
  return 0
}

client_del() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  list_inbounds_menu || return 1
  local ib="$PICK_IB" id
  id="$(jq -r '.id' <<<"$ib")"

  local -a cls=()
  mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
  [ "${#cls[@]}" -gt 0 ] || { warn "В инбаунде нет клиентов"; return 0; }
  echo ""
  printf '%-3s %-28s %-38s %s\n' "#" "EMAIL" "UUID/KEY" "SUBID"
  local i=0 cl
  for cl in "${cls[@]}"; do
    i=$((i+1))
    printf '%-3s %-28s %-38s %s\n' "$i" "$(jq -r '.email // "-"' <<<"$cl" | cut -c1-28)" \
      "$(jq -r '.id // .password // "-"' <<<"$cl" | cut -c1-38)" \
      "$(jq -r '.subId // "-"' <<<"$cl" | cut -c1-12)"
  done
  read -r -p "Номер пользователя для удаления [1-$i] (Enter — отмена): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "Отменено"; return 0; }
  [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { warn "Отменено"; return 0; }
  cl="${cls[$((n-1))]}"
  local email cid
  email="$(jq -r '.email // "-"' <<<"$cl")"
  cid="$(jq -r '.id // .password // empty' <<<"$cl")"
  [ -n "$cid" ] || { err "Не найден id клиента"; return 1; }
  read -r -p "Удалить '$email'? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || { warn "Отменено"; return 0; }
  if api_del_client "$id" "$email" "$cid"; then
    ok "Пользователь '$email' удалён"
    sub_regen_quiet || true
  fi
  return 0
}

human_bytes() { # $1 байты -> читаемый вид (IEC; ЕДИНСТВЕННАЯ версия — не переопределять)
  awk -v b="${1:-0}" 'BEGIN{
    split("B KiB MiB GiB TiB",u," "); i=1
    while (b>=1024 && i<5){b/=1024;i++}
    printf (i==1?"%d %s":"%.1f %s"), b, u[i]}'
}
human_expiry() { local ms="$1"; if [ "$ms" -gt 0 ] 2>/dev/null; then date -d @$((ms/1000)) '+%Y-%m-%d' 2>/dev/null; else echo "∞"; fi; }

client_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  echo ""
  local any=0 ib cl rmode
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    local tag proto port
    tag="$(jq -r '.tag // "inbound"' <<<"$ib")"; proto="$(jq -r '.protocol' <<<"$ib")"
    port="$(jq -r '.port' <<<"$ib")"
    echo -e "${GREEN}── ${tag}  (${proto}, порт ${port}, $([ "$rmode" = "local" ] && echo "за nginx" || echo "direct"))${NC}"
    local -a cls=()
    mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "${#cls[@]}" -eq 0 ]; then echo "   (нет клиентов)"; continue; fi
    any=$((any+1))
    printf '   %-26s %-12s %-10s %-11s %s\n' "EMAIL" "QUOTA" "ИСТЕКАЕТ" "ПОДПИСКА" "ТРАФИК (↑+↓)"
    local used
    for cl in "${cls[@]}"; do
      local email subid totalgb exp up down
      email="$(jq -r '.email // "-"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      totalgb="$(jq -r '.totalGB // 0 | (tonumber? // 0)' <<<"$cl")"
      exp="$(jq -r '.expiryTime // 0' <<<"$cl")"
      up=0; down=0
      # (баг №1, аудит v5.2.1): в else-ветке точка УЖЕ равна значению .clientStats
      # (массив); обращение .clientStats к массиву давало null -> трафик всегда 0
      up="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email==$e) | (.up|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      down="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email==$e) | (.down|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      used="$(human_bytes $((up+down)))"
      printf '   %-26s %-12s %-10s %-11s %s\n' "${email:0:26}" \
        "$([ "${totalgb:-0}" -gt 0 ] 2>/dev/null && human_bytes "$totalgb" || echo "∞")" \
        "$(human_expiry "${exp:-0}")" "$([ -n "$subid" ] && echo "${subid:0:10}" || echo "-")" "$used"
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  echo ""
  sub_show
  return 0
}

#=========================== РУЧНОЙ РЕЛЕЙ-МАРШРУТ =============================
# Проброс пути на ВНЕШНИЙ сервер (Relay): nginx 443 -> https/грpc upstream.
add_relay_route() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo "Транспорт: 1) gRPC  2) WebSocket  3) XHTTP"
  read -r -p "Выбор: " t
  case "$t" in 1) net=grpc ;; 2) net=ws ;; 3) net=xhttp ;; *) die "1-3" ;; esac
  path="$(read_path "Внешний путь (например /relay1/) -> ")"
  [ -n "$path" ] || die "Путь обязателен"
  rh="$(read_host "Внешний сервер (домен/IP backend) -> ")"
  [ -n "$rh" ] || die "Хост обязателен"
  rp=443
  if [ "$net" != "grpc" ]; then
    read -r -p "Порт backend [443]: " rp; rp="${rp:-443}"; is_port "$rp" || die "Порт некорректен"
  fi
  routes_upsert "m$(rand_hex 3)" relay "$net" "$path" "${rh}:${rp}" "manual"
  regen_conf_and_apply || return 1
  ok "Relay-маршрут: $path -> $rh:$rp (TLS до backend, SNI=$rh)"
  warn "Relay-маршруты НЕ попадают в подписки xkit — отдавайте клиенту ссылку вручную"
  return 0
}

#=========================== ПРОВЕРКА ЖИЗНЕСПОСОБНОСТИ ========================
# Что проверяем: сервисы, панель через nginx, серт, каждый маршрут, подписки,
# и главное — ЧТО СВЕТИТСЯ НАРУЖУ (порты на 0.0.0.0/::).
http_code_url() { # $1 url → код или 000
  curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null || printf '000'
}
