
health_check() {
  load_xkit_env || die "Нет состояния xkit — сначала установка (пункт 1)"
  local fails=0 warns=0 oks=0
  local mark_ok mark_bad mark_warn
  sect() { echo ""; echo -e "${BLUE}── $* ${NC}"; }
  okln()  { echo "  [OK]   $*"; oks=$((oks+1)); }
  warnln(){ echo "  [ВНИМ] $*"; warns=$((warns+1)); }
  badln() { echo "  [СБОЙ] $*"; fails=$((fails+1)); }

  sect "Сервисы"
  for s in nginx x-ui; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then okln "$s: работает"
    else badln "$s: НЕ работает (systemctl status $s)"; fi
  done

  sect "Панель за nginx"
  if read_panel_settings >/dev/null 2>&1; then
    local code
    code="$(http_code_url "https://${XKIT_HOST}${PANEL_WBP}")"
    if [ "$code" != "000" ]; then okln "панель отвечает через nginx (HTTP $code): https://${XKIT_HOST}${PANEL_WBP}"
    else badln "панель недоступна через nginx (${PANEL_WBP})"; fi
    # не слушает ли панель снаружи
    if ss -ltnH 2>/dev/null | awk -v p=":${PANEL_PORT} " 'index($4,p) && $4 !~ /^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\])/' | grep -q .; then
      warnln "порт панели ${PANEL_PORT} слушает НЕ только 127.0.0.1! Выполните: ufw deny ${PANEL_PORT}/tcp"
    else
      okln "порт панели ${PANEL_PORT} наружу не светится (только 127.0.0.1)"
    fi
  else
    badln "не удалось прочитать настройки панели"
  fi

  sect "Сертификат"
  if [ -f "${XKIT_CRT:-}" ]; then
    local end days
    end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2)"
    if [ -n "$end" ]; then
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if [ "$days" -lt 0 ]; then badln "сертификат ПРОСРОЧЕН"
      elif [ "$days" -lt 3 ] && [ "$XKIT_CERT_MODE" = "3" ]; then warnln "IP-серт живёт $days дн. (shortlived, авто-продление включено)"
      elif [ "$days" -lt 14 ]; then warnln "серт истекает через $days дн."
      else okln "серт действителен ещё $days дн. ($end)"; fi
    else badln "не удалось прочитать $XKIT_CRT"; fi
  else badln "сертификат не найден: ${XKIT_CRT:-не задан}"; fi

  sect "Маршруты инбаундов (любой HTTP-код = живой; 000 = труп)"
  routes_load
  if [ "${#ROUTES[@]}" -eq 0 ]; then warnln "маршрутов нет — выполните пункт 2 после создания инбаундов"
  else
    local row r_id r_mode r_net r_path r_target r_tag
    for row in "${ROUTES[@]}"; do
      IFS=$'\t' read -r r_id r_mode r_net r_path r_target r_tag <<<"$row"
      [ "$r_mode" = "local" ] || continue
      local c
      c="$(http_code_url "https://${XKIT_HOST}${r_path}")"
      if [ "$c" = "000" ]; then badln "$r_path -> $r_target: НЕ отвечает"
      else okln "$r_path -> $r_target: живой (HTTP $c)"; fi
    done
  fi

  sect "Подписки"
  local idx="${XKIT_DIR}/subs.index"
  if [ -s "$idx" ]; then
    local first_sub; first_sub="$(awk -F'\t' '{print $1; exit}' "$idx")"
    local sp c2
    sp="$(sub_path)"
    c2="$(http_code_url "https://${XKIT_HOST}${sp}${first_sub}")"
    if [ "$c2" = "200" ]; then okln "подписки раздаются через nginx (HTTP 200)"
    else badln "файл подписки не читается через nginx (HTTP $c2)"; fi
  else warnln "подписок нет (нет пользователей с subId)"; fi

  sect "Что СВЕТИТСЯ НАРУЖУ (слушатели не на 127.0.0.1/::1)"
  local exposed=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;;
      *) continue ;;
    esac
    case "$port" in 80|443) continue ;; esac
    if echo "$proc" | grep -qE "sshd|openssh"; then okln "SSH :$port — нужно для доступа, это нормально"; continue; fi
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if ufw status 2>/dev/null | grep -qE "^${port}/(tcp|udp)[[:space:]]+ALLOW"; then
        warnln "порт ${netid}/${port} ($proc) открыт И в фаерволе — видно снаружи!"
      else
        warnln "порт ${netid}/${port} ($proc) слушает все интерфейсы, но закрыт фаерволом (ufw)"
      fi
    else
      badln "порт ${netid}/${port} ($proc) слушает все интерфейсы, ufw ВЫКЛЮЧЕН — видно снаружи!"
    fi
    exposed=$((exposed+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$exposed" -eq 0 ] && okln "лишних слушателей нет — наружу только 80/443 (+SSH)"

  sect "DNS (для домена)"
  if [ "$(host_kind "$XKIT_HOST")" = "domain" ]; then
    local myip dnsip
    myip="$(pubip)"
    dnsip="$(getent hosts "$XKIT_HOST" 2>/dev/null | awk '{print $1; exit}')"
    if [ -n "$myip" ] && [ -n "$dnsip" ]; then
      if [ "$myip" = "$dnsip" ]; then okln "$XKIT_HOST -> $dnsip (верно)"
      else badln "$XKIT_HOST -> $dnsip, а IP сервера $myip — исправьте A-запись!"; fi
    else warnln "не удалось проверить DNS (нет сети?)"
    fi
  else okln "$XKIT_HOST — IP-режим"; fi

  sect "Итог"
  echo "  OK: $oks | предупреждений: $warns | сбоев: $fails"
  [ "$fails" -eq 0 ] && ok "Всё живо" || err "Есть сбои — см. строки [СБОЙ] выше"
  return 0
}

#=========================== БЭКАПЫ ===========================================
backup_now() {
  load_xkit_env || true
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local f="$BACKUP_DIR/xkit-$(date +%Y%m%d-%H%M%S).tar.gz"
  local -a paths=()
  [ -d "$XKIT_DIR" ] && paths+=("$XKIT_DIR")
  [ -f "$XKIT_CONF" ] && paths+=("$XKIT_CONF")
  [ -d "$SUBS_DIR" ] && paths+=("$SUBS_DIR")
  [ -f "$XUI_RESULT" ] && paths+=("$XUI_RESULT")
  [ -f "$XUI_DB" ] && paths+=("$XUI_DB")
  [ -d /etc/nginx/ssl ] && paths+=("/etc/nginx/ssl")
  [ -d /etc/letsencrypt ] && paths+=("/etc/letsencrypt")
  # v5.2: отдельные службы протоколов тоже входят в аварийный архив.
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null && paths+=("/etc/amnezia/amneziawg/awg0.conf")
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && paths+=("/etc/systemd/system/xkit-hysteria2.service")
  [ -f /etc/sysctl.d/99-xkit-awg.conf ] && paths+=("/etc/sysctl.d/99-xkit-awg.conf")
  [ "${#paths[@]}" -eq 0 ] && { warn "Нечего бэкапить"; return 1; }
  # БД панели в PostgreSQL tar'ом не забрать — честно предупреждаем
  if [ -f "$XUI_RESULT" ] && grep -q "XUI_DB_TYPE=postgres" "$XUI_RESULT" 2>/dev/null; then
    warn "БД панели — PostgreSQL: файл x-ui.db в бэкап НЕ попадёт. Бэкап панели делайте в самой панели (Panel Settings -> Backup)."
    local -a kept=() pth
    for pth in "${paths[@]}"; do [ "$pth" = "$XUI_DB" ] || kept+=("$pth"); done
    paths=("${kept[@]}")
  fi
  tar czf "$f" -C / "${paths[@]}" 2>/dev/null || { err "tar не смог собрать бэкап"; return 1; }
  chmod 600 "$f"
  find "$BACKUP_DIR" -name 'xkit-*.tar.gz' -mtime +13 -delete 2>/dev/null
  ok "Бэкап: $f ($(du -h "$f" 2>/dev/null | cut -f1)); храним 14 дней"
  return 0
}

backup_cron_install() {
  cat > "$XKIT_CRON_MAIN" <<EOF
# XKIT: авто-бэкап раз в сутки + перегенерация подписок каждый час
17 3 * * * root ${XKIT_BIN} backup >/dev/null 2>&1
13 * * * * root ${XKIT_BIN} sub -q >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_MAIN"
  ok "Cron: бэкап ежедневно 03:17, подписки перегенерируются ежечасно"
}

backup_restore() {
  local file="${1:-}"
  [ -z "$file" ] && file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] && [ -f "$file" ] || die "Бэкапы не найдены в $BACKUP_DIR"
  # V-06 (аудит №2): чужой бэкап = root RCE через содержимое. Вне BACKUP_DIR —
  # только через явное YES (или XKIT_ALLOW_UNTRUSTED_BACKUP=1)
  case "$(readlink -f -- "$file" 2>/dev/null || echo "$file")" in
    "$BACKUP_DIR"/*) ;;
    *)
      if [ "${XKIT_ALLOW_UNTRUSTED_BACKUP:-0}" != "1" ]; then
        warn "Файл вне ${BACKUP_DIR}: $(basename -- "$file")"
        local a; read -r -p "Чужой бэкап может выполнить команды от root. Точно восстановить? Введите YES: " a || { echo; return 1; }
        [ "$a" = "YES" ] || { log "Отменено"; return 0; }
      fi
      ;;
  esac
  log "Восстанавливаю из: $file"
  # V-06: члены архива — без ../ и абсолютных путей (проверка ДО распаковки)
  if tar -tzf "$file" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    err "Архив содержит небезопасные пути (../ или абсолютные) — восстановление отменено"
    return 1
  fi
  local t; t="$(mktemp -d)"
  tar xzf "$file" -C "$t" || { err "Архив битый"; rm -rf "$t"; return 1; }
  # V-06: symlink-члены не должны указывать наружу (легитимные внутренние — можно)
  local badlink
  badlink="$(find "$t" -type l 2>/dev/null | while read -r l; do
    lt="$(readlink -f "$l" 2>/dev/null || true)"
    case "$lt" in "$t"|"$t"/*) ;; *) echo "$l"; break ;; esac
  done)"
  if [ -n "$badlink" ]; then
    err "Архив содержит symlink наружу (${badlink#"$t"/}) — восстановление отменено (V-06)"
    rm -rf "$t"; return 1
  fi
  # V-06: xkit.env из архива НЕ исполняем вслепую — командная подстановка = отказ
  if [ -f "$t${XKIT_ENV}" ] && grep -qE '`|\$\(|\$\{' "$t${XKIT_ENV}" 2>/dev/null; then
    err "xkit.env в архиве содержит командную подстановку — восстановление отменено (V-06)"
    rm -rf "$t"; return 1
  fi

  systemctl stop x-ui 2>/dev/null || true
  if [ -f "$t${XUI_DB}" ]; then
    backup_file "$XUI_DB" >/dev/null
    cp "$t${XUI_DB}" "$XUI_DB" && ok "БД панели восстановлена"
  fi
  if [ -f "$t$XKIT_CONF" ]; then
    backup_file "$XKIT_CONF" >/dev/null
    cp "$t$XKIT_CONF" "$XKIT_CONF"; chmod 644 "$XKIT_CONF"
    ln -sf "$XKIT_CONF" "$XKIT_CONF_LINK"
    ok "Конфиг nginx восстановлен"
  fi
  if [ -d "$t$XKIT_DIR" ]; then
    backup_file "$XKIT_ENV" >/dev/null
    cp -a "$t$XKIT_DIR/." "$XKIT_DIR/" 2>/dev/null && ok "Состояние xkit восстановлено"
  fi
  if [ -d "$t$SUBS_DIR" ]; then
    cp -a "$t$SUBS_DIR/." "$SUBS_DIR/" 2>/dev/null && ok "Файлы подписок восстановлены"
  fi
  # v5.2: конфиги отдельных протоколов; бинарники в tar не хранятся.
  local rp
  for rp in /etc/amnezia/amneziawg/awg0.conf /etc/systemd/system/xkit-hysteria2.service /etc/sysctl.d/99-xkit-awg.conf; do
    if [ -f "$t$rp" ]; then mkdir -p "$(dirname "$rp")"; cp -f "$t$rp" "$rp"; fi
  done
  rm -rf "$t"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && systemctl enable --now xkit-hysteria2 >/dev/null 2>&1 || true
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || true

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    ok "Nginx перезагружен"
  else
    err "nginx -t не прошёл после восстановления — проверьте конфиг"
  fi
  systemctl start x-ui 2>/dev/null || true
  sleep 2
  load_xkit_env || true
  if read_panel_settings >/dev/null 2>&1 && detect_panel_scheme "$PANEL_PORT" >/dev/null; then
    COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
    if kit_login; then ok "Панель снова отвечает на логин"
    else warn "Панель запущена, но логин не прошёл — проверьте креды"; fi
  fi
  return 0
}
