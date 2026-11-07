
#=========================== СТАТУС: ЧТО ВИДНО СНАРУЖИ ========================
show_status() {
  load_xkit_env || die "Нет состояния — сначала установка"
  echo ""
  echo -e "${GREEN}==== XKIT v${XKIT_VERSION}: ${XKIT_HOST} ====${NC}"
  echo "  Панель:  https://${XKIT_HOST}$(read_panel_settings >/dev/null 2>&1 && echo "${PANEL_WBP}")"
  echo "  Подписки: https://${XKIT_HOST}$(sub_path)<subId>"
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
    echo "  Дашборд: https://${XKIT_HOST}$(dash_path) (данные: cron каждые 5 мин)"
  fi
  # v4.5: явный режим — «мастер» это состояние (nodes.json не пуст), а не отдельная установка
  local ncnt; ncnt="$(nodes_load 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "$ncnt" -gt 0 ]; then
    echo "  Режим:   мастер (${ncnt} нод; балансировка ${XKIT_BAL_STRATEGY:-roundRobin})"
  else
    echo "  Режим:   одиночный сервер (ноды не подключены)"
  fi
  echo ""
  echo "  Сервисы:  nginx=$(systemctl is-active nginx 2>/dev/null)  x-ui=$(systemctl is-active x-ui 2>/dev/null)  ufw=$(ufw status 2>/dev/null | sed -n 's/Status: //p')"
  echo ""
  echo "  Слушатели, видимые снаружи (0.0.0.0/::):"
  local found=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;; *) continue ;; esac
    echo "    ${netid}/${port}  ${proc:-?}"
    found=$((found+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$found" -eq 0 ] && echo "    (нет)"
  echo ""
  echo "  Локальные (127.0.0.1 — снаружи НЕ видны):"
  ss -tlnpH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1/ {print "    "$4"  "$7}' | head -n 20
  echo ""
  routes_load
  echo "  Маршруты за nginx: ${#ROUTES[@]}"
  local row
  for row in "${ROUTES[@]}"; do
    IFS=$'\t' read -r _ r_mode r_net r_path r_target _ <<<"$row"
    echo "    $r_path -> $r_target [$r_mode/$r_net]"
  done
  return 0
}

#=========================== УСТАНОВКА ОДНИМ ШАГОМ ============================
setup_ufw() {
  command -v ufw >/dev/null 2>&1 || { warn "ufw не найден — пропускаю настройку фаервола"; return 0; }
  if ufw status 2>/dev/null | head -n1 | grep -q "inactive"; then
    local ssh_port a
    # S-03 (аудит №2): порт SSH из sshd -T/sshd_config, НЕ из ss-парсинга;
    # не определили — UFW НЕ включаем (fallback на 22 = lockout при нестандартном порте)
    ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [ -n "$ssh_port" ] || ssh_port="$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
    [ -n "$ssh_port" ] || ssh_port="$(ss -tlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]; exit}')"
    if [ -n "$ssh_port" ] && ! is_port "$ssh_port"; then ssh_port=""; fi
    if [ -z "$ssh_port" ]; then
      if [ -t 0 ]; then
        read -r -p "Не смог определить порт SSH. Укажите его вручную (Enter — пропустить ufw): " ssh_port || ssh_port=""
      fi
      is_port "${ssh_port:-}" 2>/dev/null || ssh_port=""
    fi
    if [ -z "$ssh_port" ]; then
      warn "Порт SSH не определён — UFW НЕ включаю (риск заблокировать себя). Вручную: ufw allow <порт>/tcp && ufw enable"
      return 0
    fi
    read -r -p "Включить ufw (наружу останутся только SSH ${ssh_port}, 80, 443)? [Y/n]: " a || a=""
    if [[ "$a" =~ ^[Nn] ]]; then
      warn "UFW не включён — панель/инбаунды на 127.0.0.1 всё равно не видны, но проверьте открытые порты сами"
      return 0
    fi
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1
    ufw allow 80/tcp  >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 && ok "UFW включён: наружу только SSH ${ssh_port}, 80, 443"
    XKIT_UFW=1
  else
    ok "UFW уже активен"
    XKIT_UFW=1
  fi
  return 0
}

#=========================== PREFLIGHT (v4.7) ==================================
# Проверки ДО каких-либо изменений: уже установлен / порты / диск / RAM / сеть.
# Раньше повторный `xkit install` молча ставил поверх: env не загружался ->
# НОВЫЙ SUB_TOKEN (все ссылки подписок у клиентов отваливались) + save_xkit_env
# затирал TG/dash-токены нулями. Теперь — явный выбор.
preflight_installed_menu() { # 0 = продолжать установку поверх, 1 = стоп
  local a
  echo ""
  warn "xkit уже установлен: ${XKIT_ENV}"
  echo "  1) Обновить скрипт (xkit update) — состояние/ноды/подписки НЕ трогаются"
  echo "  2) Чистая переустановка: бэкап -> полное удаление -> установка с нуля"
  echo "  3) Починить поверх: пакеты/панель/конфиг заново, состояние сохраняется"
  echo "  0) Выход"
  read -r -p "Выбор [0]: " a || { echo; return 1; }   # EOF (cron/pipe) — безопасный выход
  case "${a:-0}" in
    1) xkit_self_update; return 1 ;;
    2) xkit_reinstall; return 1 ;;
    3) warn "Починка поверх: пакеты/панель/конфиг переустановятся, текущее состояние"
       warn "(адрес, путь подписок, Telegram, дашборд) СОХРАНИТСЯ и подхватится."
       confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
       return 0 ;;
    *) log "Выход без изменений"; return 1 ;;
  esac
}

preflight() { # 0 = можно ставить, 1 = стоп
  # 1) уже установленный xkit: спросить, а не молча перезаписать
  if [ -f "$XKIT_ENV" ]; then
    if [ "${XKIT_FORCE:-0}" = "1" ]; then
      warn "XKIT_FORCE=1: ставлю поверх существующей установки (SUB_TOKEN/TG/dash слетят)"
    else
      preflight_installed_menu || return 1
    fi
  fi

  # 2) порты 80/443 (важно ДО certbot): nginx-оккупант будет перенастроен сам,
  #    чужой процесс (apache/другой vpn) — предупреждение с именем процесса
  local warns=0 p line
  if command -v ss >/dev/null 2>&1; then
    for p in 80 443; do
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if printf '%s' "$line" | grep -q nginx; then
          log "Порт ${p} уже слушает nginx — xkit перенастроит его сайт"
        else
          warn "Порт ${p} занят: ${line}"
          warns=$((warns+1))
        fi
      done < <(ss -ltnpH "sport = :${p}" 2>/dev/null)
    done
  fi

  # 3) диск: certbot + БД + бэкапы не живут на <500 MB
  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 500 ] 2>/dev/null; then
    err "Свободно ${avail_mb} MB на / — нужно >=500 MB (сертификаты, БД панели, бэкапы)"
    return 1
  fi

  # 4) RAM: x-ui + nginx + certbot на 512 MB впритык
  local mem_mb
  mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 400 ] 2>/dev/null; then
    warn "RAM ${mem_mb} MB — x-ui/nginx/certbot могут упасть по OOM (рекомендую >=512 MB)"
    warns=$((warns+1))
  fi

  # 5) сеть: без этих хостов установка не пройдёт (3X-UI качается с github)
  local u
  for u in https://raw.githubusercontent.com https://api.ipify.org; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 3 -o /dev/null "$u" 2>/dev/null || { warn "Нет доступа к ${u} — часть установки может не пройти"; warns=$((warns+1)); }
    fi
  done

  if [ "$warns" -gt 0 ]; then
    confirm "Продолжить несмотря на предупреждения? [y/N]: " n || { log "Отменено"; return 1; }
  fi
  return 0
}

#=========================== УДАЛЕНИЕ / ПЕРЕУСТАНОВКА =========================
# xkit_uninstall [--full]: бэкап ОБЯЗАТЕЛЕН (провал = отмена), затем чистая
# зачистка следов кита. --full дополнительно удаляет 3X-UI и /etc/nginx/ssl.
# НИКОГДА не удаляются: бэкапы ($BACKUP_DIR), /etc/letsencrypt, сам nginx и
# чужие сайты, UFW-правила 22/80/443. Ноды (xray на них) не трогаются.
# KEEP_BIN=1 — внутренний флаг reinstall: не удалять $XKIT_BIN (running-скрипт).
xkit_uninstall() {
  local full=0
  [ "${1:-}" = "--full" ] && full=1
  require_root
  load_xkit_env 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}============================================================${NC}"
  warn "УДАЛЕНИЕ XKIT С ЭТОГО СЕРВЕРА"
  echo -e "${YELLOW}============================================================${NC}"
  echo "Удаляется:   cron-задачи xkit (3 шт), nginx-сайт xkit.conf (+reload nginx),"
  echo "             /etc/xkit (состояние, SSH-ключи нод, expiry, алерты),"
  echo "             /var/lib/xkit (подписки, дашборд), htpasswd дашборда,"
  echo "             deny-правило UFW для порта панели, /usr/local/bin/xkit"
  [ "$full" = "1" ] && echo "             + --full: 3X-UI (сервис, /etc/x-ui, /usr/local/x-ui, CLI), /etc/nginx/ssl"
  echo "Сохраняется: бэкапы $BACKUP_DIR (включая свежий, 14 дней), /etc/letsencrypt,"
  echo "             nginx и другие сайты, UFW-правила SSH/80/443"
  echo "Ноды продолжат работать автономно — xray на них не трогаем."

  log "Сначала бэкап — без него удаление не состоится..."
  backup_now || { err "Бэкап не удался — удаление отменено (безопасность)"; return 1; }

  if [ "${XKIT_YES:-0}" != "1" ]; then
    local a
    read -r -p "Удалить xkit? Введите YES: " a || { echo; log "Отменено"; return 1; }
    [ "$a" = "YES" ] || { log "Отменено"; return 1; }
  fi

  xkit_log_begin uninstall
  xkit_install_traps_on

  rm -f "$XKIT_CRON_MAIN" "$XKIT_CRON_DASH" "$XKIT_CRON_NOTIFY" 2>/dev/null
  ok "Cron-задачи xkit удалены"

  if [ -e "$XKIT_CONF" ] || [ -L "$XKIT_CONF_LINK" ]; then
    rm -f "$XKIT_CONF" "$XKIT_CONF_LINK" "$XKIT_DASH_HTPASSWD" 2>/dev/null
    if command -v nginx >/dev/null 2>&1; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
        ok "nginx-сайт xkit.conf удалён, nginx перезагружен"
      else
        err "После удаления xkit.conf nginx -t не проходит — проверьте /etc/nginx вручную"
      fi
    else
      ok "nginx-сайт xkit.conf удалён"
    fi
  else
    log "nginx-сайт xkit.conf не найден — пропускаю"
  fi

  # deny порта панели — xkit-специфичное правило; allow 22/80/443 не трогаем:
  # удалить allow 22 = потерять SSH, allow 80/443 безвредны и стандартны
  if [ -n "${PANEL_PORT:-}" ] && command -v ufw >/dev/null 2>&1; then
    ufw delete deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  # v5.2: отдельные службы протоколов. Чужой awg0 без метки XKIT не трогаем.
  systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xkit-hysteria2.service /usr/local/bin/xkit-hysteria2
  if [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then
    systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f /etc/amnezia/amneziawg/awg0.conf /etc/sysctl.d/99-xkit-awg.conf
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # файлы состояния: /etc/xkit, подписки, дашборд и стандартная база /var/lib/xkit
  # (SUBS_DIR/XKIT_DASH_DIR — переменные, удаляем явно; /var/lib/xkit — база по
  # умолчанию, сносит остатки старых версий, если пути переопределены)
  rm -rf "$XKIT_DIR" "$SUBS_DIR" "$XKIT_DASH_DIR" /var/lib/xkit 2>/dev/null
  rm -f "$XKIT_INFO_FILE" 2>/dev/null
  ok "Файлы xkit удалены ($XKIT_DIR, $SUBS_DIR, $XKIT_DASH_DIR)"

  if [ "$full" = "1" ]; then
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/x-ui.service /usr/local/bin/x-ui 2>/dev/null
    rm -rf /etc/systemd/system/x-ui.service.d /etc/x-ui /usr/local/x-ui /etc/nginx/ssl 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed x-ui >/dev/null 2>&1 || true   # не оставляем failed-огрызок в systemctl
    ok "3X-UI и /etc/nginx/ssl удалены (--full)"
  fi

  if [ "${KEEP_BIN:-0}" != "1" ]; then
    [ -f "$XKIT_BIN" ] && rm -f "$XKIT_BIN" && ok "Команда xkit удалена"
    [ -d "$XKIT_MENU_DIR" ] && rm -rf "$XKIT_MENU_DIR" && ok "Модуль меню удалён ($XKIT_MENU_DIR)"
  fi

  xkit_install_traps_off
  ok "ГОТОВО. Свежий бэкап лежит в $BACKUP_DIR (хранится 14 дней)"
  log "Вернуть данные: install.sh -> xkit restore (инбаунды/клиенты панели, маршруты)"
  return 0
}

# Чистая переустановка: бэкап -> uninstall --full -> one_step_install.
# Бинарник сохраняем (KEEP_BIN=1): one_step_install сам обновит его в конце
# (bash держит fd открытого скрипта, но $0 после rm недоступен для cp)
xkit_reinstall() {
  require_root
  echo ""
  warn "ЧИСТАЯ ПЕРЕУСТАНОВКА: бэкап -> полное удаление (включая панель 3X-UI) -> установка с нуля."
  warn "Инбаунды/клиенты панели будут потеряны (останутся в бэкапе), подписки пересоздадутся."
  confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
  # имя лога — строго по reinstall, даже если нас вызвали из процесса,
  # где XKIT_LOG уже открыт (напр. preflight-меню поверх one_step_install)
  XKIT_LOG=""
  xkit_log_begin reinstall
  KEEP_BIN=1 xkit_uninstall --full || { err "Переустановка прервана: удаление не удалось"; return 1; }
  # Вложенный one_step_install — намеренно: preflight увидит, что $XKIT_ENV
  # уже удалён, меню не покажет; вложенный xkit_log_begin переиспользует
  # общий лог без очистки (внешний вызов после `return 1` не выполняется).
  one_step_install   # $XKIT_ENV уже удалён — preflight пропустит меню, лог общий
}

one_step_install() {
  require_root
  check_os
  preflight || return 1
  # ветка «поверх» (или XKIT_FORCE): подхватываем текущее состояние — прежний
  # адрес, SUB_TOKEN (ссылки подписок у клиентов НЕ меняются), TG/dash-токены.
  # При чистой установке/reinstall env отсутствует — load вернёт 1, не страшно
  load_xkit_env 2>/dev/null || true
  xkit_log_begin install
  xkit_install_traps_on
  STEP=0

  step "Пакеты (nginx, certbot, jq, sqlite3, openssl, ufw, python3)"
  with_spinner "apt-get update..." apt-get update -qq || warn "apt-get update вернул ошибку — продолжаю"
  with_spinner "Установка пакетов..." env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq nginx curl certbot openssl jq sqlite3 ufw cron python3 \
    python3-venv python3-pip \
    || die "Не удалось установить пакеты — подробности в $XKIT_LOG"
  # ревью v4.9.0 (живая установка): в репо Ubuntu 24.04 certbot 2.9 без --ip-address.
  # Раньше это всплывало вопросом посреди установки и могло её оборвать — теперь
  # обновляем СРАЗУ (pip/venv), до вопросов про адрес/серт; не вышло — не фатально,
  # issue_cert_le_ip повторит попытку и меню серта предложит пункт 4
  if ! certbot_supports_ip; then
    log "certbot $(certbot_version) старый — обновляю до актуального (нужен >= ${CERTBOT_MIN_IP} для IP-сертификатов)..."
    if with_spinner "Обновление certbot (pip/venv, 1-2 мин)..." certbot_upgrade; then
      ok "certbot обновлён: $(certbot_version)"
    else
      warn "certbot обновить не удалось — IP-сертификаты будут недоступны (возьмите самоподписанный)"
    fi
  fi

  step "Домен/IP и SSL-сертификат"
  if [ -n "${XKIT_HOST:-}" ]; then
    read -r -p "Использовать прежний адрес ${XKIT_HOST}? [Y/n]: " a
    if [[ "$a" =~ ^[Nn] ]]; then XKIT_HOST=""; fi
  fi
  if [ -z "${XKIT_HOST:-}" ]; then
    choose_host "Адрес этого сервера (для сертификата и ссылок)"
    XKIT_HOST="$CHOSEN_HOST"
  fi
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  [ "$HOST_KIND" != "bad" ] || die "Адрес не распознан"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"

  step "Установка панели 3X-UI (официальный инсталлятор, неинтерактивно)"
  install_3xui_auto || return 1
  read_panel_settings || return 1
  # №17 (аудит): XUI_NONINTERACTIVE зависит от версии инсталлятора 3X-UI — если
  # пароль в install-result.env не попал, пункт 3 (логин в панель) не пройдёт
  if [ -z "$PANEL_PASS" ]; then
    warn "Пароль панели не извлечён из install-result.env (версия установщика 3X-UI?)"
    warn "Задайте вручную:  x-ui setting -username admin -password ВАШ_ПАРОЛЬ  — затем продолжайте"
  fi
  PANEL_SCHEME="$(with_spinner -o "Определяю схему панели (http/https)..." detect_panel_scheme "$PANEL_PORT")" || PANEL_SCHEME="http"
  ok "Панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP} (upstream ${PANEL_SCHEME})"

  log "Прибиваю панель к 127.0.0.1 (webListen), чтобы порт не светился..."
  if with_spinner "webListen -> 127.0.0.1..." force_panel_localhost "$PANEL_PORT"; then
    ok "Панель слушает только 127.0.0.1:${PANEL_PORT}"
  else
    warn "Не удалось включить webListen через БД (postgres или другая схема)"
    warn "Порт панели закрою фаерволом (ufw deny) — см. шаг фаервола"
  fi
  read_panel_settings >/dev/null 2>&1 || true

  step "Секретный путь подписок + состояние xkit"
  if [ -z "${XKIT_SUB_TOKEN:-}" ]; then XKIT_SUB_TOKEN="$(rand_str 16)"; fi
  touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"
  save_xkit_env

  step "Конфиг nginx (панель + подписки), перезапуск"
  regen_conf_and_apply || return 1
  systemctl enable nginx >/dev/null 2>&1 || true

  step "Фаервол"
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели ${PANEL_PORT} закрыт снаружи (страховка)"
  fi
  save_xkit_env

  step "Бэкапы по cron + команда xkit"
  backup_cron_install
  if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$XKIT_BIN" ]; then
    cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN" \
      && ok "Меню установлено: введите в SSH команду xkit"
  fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  ok "ГОТОВО. Наружу смотрит только nginx: 80 (redirect) + 443 (TLS)."
  ok "Панель:  https://${XKIT_HOST}${PANEL_WBP}"
  [ -n "$PANEL_USER" ] && ok "Логин:   ${PANEL_USER}   Пароль: ${PANEL_PASS}"
  ok "Креды также в ${XUI_RESULT} (chmod 600)"
  echo ""
  log "Дальше:"
  log "  1) Зайдите в панель, создайте инбаунд: Listen IP = 127.0.0.1, порт любой"
  log "  2) Введите xkit -> пункт 2 — он сам всё пробросит за nginx и сделает подписки"
  log "  3) Проверка: xkit -> пункт 7 (жизнеспособность и «что светится»)"
  [ "$CERT_MODE" = "3" ] && warn "IP-серт живёт 6 дней — продление настроено (certbot.timer)"
  [ "$CERT_MODE" = "4" ] && warn "Самоподписанный серт: на клиентах allowInsecure=true"
  echo -e "${GREEN}============================================================${NC}"

  # v4.5: развилка «что дальше» вместо одного вопроса про автопроброс.
  # Вариант «мастер» = автопроброс + добавление нод (node_add требует
  # живой nginx и панель, поэтому автопроброс всегда идёт первым).
  # XKIT_YES=1 (CI/cloud-init): без вопросов — «сделаю позже сам»
  echo ""
  log "Что дальше?"
  echo "  1) Одиночный сервер — автопроброс инбаундов за nginx (по умолчанию)"
  echo "  2) Мастер с нодами — автопроброс, затем добавить зарубежные ноды"
  echo "  3) Ничего — сделаю позже сам (xkit route / xkit nodes)"
  if [ "${XKIT_YES:-0}" = "1" ]; then
    a="3"
  else
    read -r -p "Выбор [1]: " a || a=""
  fi
  case "${a:-1}" in
    1|"") auto_route ;;
    2) auto_route || warn "Автопроброс не прошёл — ноды можно добавить позже (xkit nodes)"
       echo ""
       log "Добавление нод (мастер-режим)..."
       nodes_menu ;;
    3) : ;;
    *) warn "Нет такого пункта — позже: xkit route (проброс) или xkit nodes (ноды)" ;;
  esac

  echo ""
  xkit_info   # вся сводка в терминал + /root/xkit-info.txt (chmod 600)
  xkit_install_traps_off
  [ -n "${XKIT_LOG:-}" ] && log "Полный лог установки: ${XKIT_LOG}"
  return 0
}

# спрятать УЖЕ установленную панель (без переустановки всего)
hide_existing_panel() {
  require_root
  command -v x-ui >/dev/null 2>&1 || die "3X-UI не установлен (команда x-ui не найдена)"
  read_panel_settings || return 1
  ok "Найдена панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP}"

  echo ""
  choose_host "Адрес этого сервера (для nginx)"
  XKIT_HOST="$CHOSEN_HOST"
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"
  [ -z "${XKIT_SUB_TOKEN:-}" ] && XKIT_SUB_TOKEN="$(rand_str 16)"
  touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"

  if force_panel_localhost "$PANEL_PORT"; then
    ok "Панель прибита к 127.0.0.1"
    read_panel_settings >/dev/null 2>&1 || true
  fi
  save_xkit_env
  regen_conf_and_apply || return 1
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели закрыт снаружи"
  fi
  save_xkit_env
  if [ -f "$0" ]; then cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN"; fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  ok "Панель доступна ТОЛЬКО через: https://${XKIT_HOST}${PANEL_WBP}"
  log "Дальше: инбаунды с Listen IP = 127.0.0.1, затем пункт 2 (автопроброс)"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}
