
#=========================== v4.5: TELEGRAM-АЛЕРТЫ =============================
# Принцип: шлём ТОЛЬКО то, чего 3X-UI не знает (ноды/аренда/сертификат/
# дашборд). Бот-команды и уведомления о клиентах НЕ дублируем — это умеет
# сам 3X-UI (один бот, один чат, сообщения xkit помечены [XKIT]).
#
# Доставка: (1) напрямую с мастера; (2) если api.telegram.org недоступен
# (типично для РФ) — через ноды по SSH: curl крутится НА ноде, выход с её
# зарубежного IP. Живой выбор балансировщика здесь не нужен: сообщение
# одно и то же, идём по реестру до первой успешной доставки. Токен не
# попадает в argv (ps на ноде чист): curl читает URL из stdin-конфига -K -.
xkit_tg_send() { # $1 текст; 0 = доставлено или TG не настроен
  local msg="$1" token="${XKIT_TG_TOKEN:-}" chat="${XKIT_TG_CHAT:-}"
  [ -n "$token" ] && [ -n "$chat" ] || return 0   # TG не настроен — тихо
  # №9 (аудит №1): токен из env уходит в curl-конфиг — убеждаемся в формате,
  # иначе мусор/инъекция из xkit.env доедет до curl
  [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] \
    || { warn "TG-токен в env невалиден — уведомление пропущено (xkit 6 → 2 — перенастройте)"; return 1; }
  [ -n "$msg" ] || return 0
  # urlencoded POST-body (chat_id и text кодируются @uri: переводы строк -> %0A,
  # кавычек/бэкслэшей не остаётся — строка безопасна для curl-конфига)
  local data
  data="$(jq -rn --arg c "$chat" --arg t "$msg" '"chat_id=\($c|@uri)&text=\($t|@uri)"' 2>/dev/null)" || return 1
  local -a px=()
  [ -n "${XKIT_TG_PROXY:-}" ] && px=(--proxy "$XKIT_TG_PROXY")
  # (1) напрямую с мастера
  { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
    | curl -sf --max-time 8 ${px[@]+"${px[@]}"} -K - -o /dev/null 2>/dev/null && return 0
  # (2) через ноды по SSH: curl на ноде, выход с её IP
  local rec
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
      | node_ssh "$rec" 'curl -sf --max-time 10 -K - -o /dev/null' >/dev/null 2>&1 && return 0
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)
  return 1
}

# --- состояние алертов (гистерезис/дедуп): key=val построчно, chmod 600 ---
notify_state_get() { # $1 key -> value (пусто если нет)
  [ -r "$XKIT_NOTIFY_STATE" ] || return 0
  awk -F= -v k="$1" '$1==k{print substr($0, length(k)+2); exit}' "$XKIT_NOTIFY_STATE" 2>/dev/null
}

notify_state_set() { # $1 key, $2 value (пустое значение = удалить ключ)
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  # запись целиком в subshell (симметрично dash_gen_locked): umask 077 не
  # утекает в вызывающую оболочку, даже если mktemp/awk/mv провалятся
  # посередине (ревью v4.6.0 — раньше umask 022 ставился в конце основной
  # оболочки и не выполнялся при любом сбое выше)
  (
    umask 077
    tmp="$(mktemp)" || exit 0
    # удаление ключа — awk с точным сравнением $1==k (аудит №14): grep -v
    # трактовал «.» в ключе как regex и мог зацепить чужие ключи; симметрично get
    { [ -r "$XKIT_NOTIFY_STATE" ] && awk -F= -v k="$1" '$1!=k' "$XKIT_NOTIFY_STATE" 2>/dev/null
      [ -n "$2" ] && printf '%s=%s\n' "$1" "$2"; } > "$tmp"
    mv -f "$tmp" "$XKIT_NOTIFY_STATE" 2>/dev/null
  )
  chmod 600 "$XKIT_NOTIFY_STATE" 2>/dev/null
  return 0
}

# чистая функция гистерезиса ноды (тестируемая):
#   $1 прошлое состояние (up|fail1|down|пусто), $2 текущая проба (ok|fail)
#   stdout: "новое_состояние<TAB>текст_алерта" (пустой текст = не алертить).
# Логика: алерт о падении — только со 2-й проверки подряд (одиночный таймаут
# не алертим), о восстановлении — всегда один раз.
notify_node_trans() {
  local st="${1:-}" probe="$2"
  if [ "$probe" = "ok" ]; then
    case "$st" in
      down) printf 'up\tнедоступна была — восстановлена\n' ;;
      *)    printf 'up\t' ;;
    esac
  else
    case "$st" in
      down)  printf 'down\t' ;;
      fail1) printf 'down\tнедоступна (2 проверки подряд)\n' ;;
      *)     printf 'fail1\t' ;;
    esac
  fi
}

# периодическая проверка (cron каждые 10 мин): ноды (TCP-проба туннеля),
# аренда, сертификат мастера, свежесть дашборда. Алерты — только при
# ИЗМЕНЕНИИ состояния (дедуп: аренда/серт — при смене числа дней, т.е.
# максимум раз в сутки). Один прогон = максимум одно сообщение со всеми
# событиями (не поток сообщений).
# --- чистые функции алертов (тестируемые, как notify_node_trans) ---

# А1 диск: $1 = занято % -> уровень "95"|"85"|"" (пусто = всё ок)
notify_disk_verdict() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac   # не число — не алертим
  [ "$p" -ge 95 ] && { printf '95'; return 0; }
  [ "$p" -ge 85 ] && printf '85'
  return 0
}

# А2 сервис мастера: переходы. $1 old(""|up|down), $2 new(up|down) -> "state\tmsg"
# (msg пуст — ничего не слать; стиль notify_node_trans)
notify_svc_trans() {
  local old="$1" new="$2"
  if [ "$new" = "down" ]; then
    [ "$old" = "down" ] && { printf 'down\t'; return 0; }   # уже алертили — молчим
    printf 'down\tНЕ работает — проверьте systemctl status'
    return 0
  fi
  [ "$old" = "down" ] && printf 'up\tснова работает' || printf 'up\t'
  return 0
}

notify_check() {
  load_xkit_env 2>/dev/null || return 0
  [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ] || return 0   # не настроено
  local -a L=()

  # --- А2 сервисы мастера: nginx/x-ui молча умереть не должны (раньше мастер
  #     сообщал только о нодах, а о себе — через stale-дашборд, и то через 25 мин) ---
  local sv svc_st sold snew snst snmsg
  for sv in nginx x-ui; do
    svc_st="$(systemctl is-active "$sv" 2>/dev/null || true)"
    [ "$svc_st" = "active" ] && svc_st="up" || svc_st="down"
    sold="$(notify_state_get "svc:${sv}")"
    snew="$(notify_svc_trans "${sold:-}" "$svc_st")"
    snst="${snew%%$'\t'*}"; snmsg="${snew#*$'\t'}"
    [ "${sold:-}" != "$snst" ] && notify_state_set "svc:${sv}" "$snst"
    [ -n "$snmsg" ] && L+=("Сервис ${sv}: ${snmsg}")
  done

  # --- А1 диск: переполнение молча валит sqlite панели/certbot/бэкапы ---
  local dpct dlv dold
  dpct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  dlv="$(notify_disk_verdict "$dpct")"
  dold="$(notify_state_get "disk")"
  if [ -n "$dpct" ]; then
    if [ -n "$dlv" ] && [ "$dlv" != "$dold" ]; then
      if [ "$dlv" = "95" ]; then
        L+=("ДИСК: занято ${dpct}% — панель/сертификаты/бэкапы скоро начнут падать")
      else
        L+=("Диск: занято ${dpct}% (порог 85%) — почистите место")
      fi
      notify_state_set "disk" "$dlv"
    elif [ -z "$dlv" ] && [ -n "$dold" ]; then
      L+=("Диск: место освободилось (занято ${dpct}%)")
      notify_state_set "disk" ""
    fi
  fi

  # --- ноды: TCP-проба туннеля (быстро, без SSH) ---
  local rec name host tport old new nst nmsg probe
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then probe="ok"; else probe="fail"; fi
    old="$(notify_state_get "node:${name}")"
    new="$(notify_node_trans "${old:-}" "$probe")"
    nst="${new%%$'\t'*}"; nmsg="${new#*$'\t'}"
    [ "${old:-}" != "$nst" ] && notify_state_set "node:${name}" "$nst"
    [ -n "$nmsg" ] && L+=("Нода ${name}: ${nmsg}")
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)

  # --- аренда: алерт при <=7 дн. и при истечении; дедуп по числу дней ---
  local s i d note dl last
  if [ -s "$XKIT_EXPIRY" ]; then
    while IFS=$'\t' read -r s i d note; do
      [ -z "$s" ] && continue
      dl="$(days_left "$d")"
      [ -n "$dl" ] || continue
      if [ "$dl" -le 7 ]; then
        last="$(notify_state_get "exp:${s}/${i}")"
        if [ "${last:-x}" != "$dl" ]; then
          if [ "$dl" -lt 0 ]; then
            L+=("Аренда ИСТЕКЛА: ${s}/${i} (${d})${note:+ — ${note}}")
          else
            L+=("Осталось ${dl} дн. аренды: ${s}/${i} (${d})${note:+ — ${note}}")
          fi
          notify_state_set "exp:${s}/${i}" "$dl"
        fi
      fi
    done < "$XKIT_EXPIRY"
  fi

  # --- сертификат мастера: <=14 дн., дедуп по числу дней ---
  if [ -n "${XKIT_CRT:-}" ] && [ -f "$XKIT_CRT" ]; then
    local cend cdl
    cend="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$cend" ]; then
      cdl=$(( ( $(date -d "$cend" +%s) - $(date +%s) ) / 86400 ))
      if [ "$cdl" -le 14 ]; then
        last="$(notify_state_get "cert:master")"
        if [ "${last:-x}" != "$cdl" ]; then
          L+=("Сертификат ${XKIT_HOST} истекает через ${cdl} дн. (${cend})")
          notify_state_set "cert:master" "$cdl"
        fi
      fi
    fi
  fi

  # --- дашборд: data.json не обновлялся >25 мин (5 пропусков cron) ---
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    local gen age
    gen="$(jq -r '.generated // 0' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
    case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
    if [ "$gen" -gt 0 ]; then
      age=$(( $(date +%s) - gen ))
      if [ "$age" -gt 1500 ]; then
        if [ "$(notify_state_get "dash")" != "stale" ]; then
          L+=("Дашборд не обновляется: данные от $(date -d "@$gen" '+%d.%m %H:%M' 2>/dev/null || echo '?')")
          notify_state_set "dash" "stale"
        fi
      else
        if [ "$(notify_state_get "dash")" = "stale" ]; then
          notify_state_set "dash" ""
          L+=("Дашборд снова обновляется")
        fi
      fi
    fi
  fi

  [ "${#L[@]}" -eq 0 ] && return 0
  local msg="[XKIT] ${XKIT_HOST:-сервер}" ln
  for ln in "${L[@]}"; do msg+=$'\n'"${ln}"; done
  if xkit_tg_send "$msg"; then
    ok "Telegram: отправлено (событий: ${#L[@]})"
    return 0
  fi
  warn "Telegram: доставить не удалось (${#L[@]} событий) — ни напрямую, ни через ноды"
  return 1
}

notify_cron_install() {
  cat > "$XKIT_CRON_NOTIFY" <<EOF
# XKIT: Telegram-алерты (ноды/аренда/сертификат/дашборд) каждые 10 минут
*/10 * * * * root ${XKIT_BIN} telegram check >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_NOTIFY"
  ok "Cron: алерты проверяются каждые 10 минут ($XKIT_CRON_NOTIFY)"
}

notify_cron_remove() { rm -f "$XKIT_CRON_NOTIFY" 2>/dev/null; return 0; }

telegram_setup() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo -e "${YELLOW}=== Telegram-уведомления ===${NC}"
  if [ -n "${XKIT_TG_TOKEN:-}" ]; then
    ok "Уже настроено (чат ${XKIT_TG_CHAT}) — повторный запуск заменит реквизиты"
  fi
  echo "Приходит только то, чего 3X-UI НЕ знает: нода упала/восстановилась,"
  echo "аренда <=7 дн. или истекла, сертификат <=14 дн., дашборд stale."
  echo "Бот-команды и уведомления о клиентах остаются у 3X-UI (не дублируем)."
  echo "Доставка: с мастера напрямую; если не проходит — через ноды (их IP)."
  local tok chat px
  read -r -p "Bot token (от @BotFather, вид 123456:ABC-...): " tok
  [[ "$tok" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] || { err "Токен не похож на валидный"; return 1; }
  read -r -p "Chat ID (число от @userinfobot, или @имя_канала): " chat
  [[ "$chat" =~ ^-?[0-9]+$|^@[A-Za-z0-9_]{4,64}$ ]] || { err "Chat ID: число (личка/группа) или @имя_канала"; return 1; }
  read -r -p "Прокси для api.telegram.org (http://... или socks5://...; Enter — без прокси): " px
  XKIT_TG_TOKEN="$tok"; XKIT_TG_CHAT="$chat"; XKIT_TG_PROXY="$px"
  save_xkit_env
  notify_cron_install
  log "Отправляю тестовое сообщение..."
  if xkit_tg_send "[XKIT] ${XKIT_HOST:-сервер}: Telegram настроен. Алерты: ноды, аренда, сертификат, дашборд."; then
    ok "Тестовое сообщение доставлено"
  else
    warn "Прямая отправка не прошла. Если api.telegram.org недоступен с этого"
    warn "сервера — сообщения пойдут через ноды (после их добавления)."
    warn "Проверка вручную: xkit telegram check"
  fi
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_off() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "${XKIT_TG_TOKEN:-}" ] || { warn "Telegram не настроен"; return 0; }
  local a
  read -r -p "Выключить Telegram-уведомления (токен удалится)? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""
  save_xkit_env
  notify_cron_remove
  ok "Telegram-уведомления выключены (история состояний: ${XKIT_NOTIFY_STATE})"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_menu() {
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== TELEGRAM-АЛЕРТЫ (ноды/аренда/сертификат/дашборд) ===${NC}"
    if [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ]; then
      ok "Настроено: чат ${XKIT_TG_CHAT}${XKIT_TG_PROXY:+, прокси ${XKIT_TG_PROXY}}"
    else
      warn "Не настроено (xkit telegram setup)"
    fi
    echo " 1) Настроить / заменить (токен + chat_id + тестовое сообщение)"
    echo " 2) Проверить сейчас (то же, что cron каждые 10 минут)"
    echo " 3) Отправить тестовое сообщение"
    echo " 4) Выключить (токен удаляется, cron убирается)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) telegram_setup; pause_enter ;;
      2) load_xkit_env >/dev/null 2>&1 || true; notify_check; pause_enter ;;
      3) load_xkit_env >/dev/null 2>&1 || true
         if xkit_tg_send "[XKIT] тест: канал доставки работает"; then ok "Доставлено"; else err "Не доставлено (напрямую и через ноды)"; fi
         pause_enter ;;
      4) telegram_off; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}
