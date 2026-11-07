
#=========================== ОБНОВЛЕНИЕ =======================================
# v5.0.0: обновляются ОБА файла — xkit.sh (ядро) и xkit_menu.sh (модуль меню).
# Пломба xkit.sh.sha256 — формат sha256sum, 2 строки; строка 1 = xkit.sh,
# строка 2 = xkit_menu.sh (старые версии читают строку 1 — совместимость)
xkit_self_update() { # $1 base-url (необязательно; иначе XKIT_REPO_URL из xkit.env)
  require_root
  load_xkit_env 2>/dev/null || true   # свежая SSH-сессия: XKIT_REPO_URL живёт в xkit.env
  local base="${1:-${XKIT_REPO_URL:-}}"
  if [ -z "$base" ]; then
    err "Не знаю, откуда обновляться. Укажите URL репозитория:"
    err "  xkit update https://raw.githubusercontent.com/НИК/xkit/main"
    err "  (или переустановите через install.sh — он запомнит источник)"
    return 1
  fi
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  # K-02: http:// наружу запрещён (локальные зеркала для тестов — можно)
  case "$base" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
    http://*) err "K-02: обновление по http:// запрещено — укажите https://-источник"; return 1 ;;
  esac
  local tmp tmpm sumf
  tmp="$(mktemp /tmp/.xkit-update.XXXXXX)" || return 1
  log "Скачиваю ${base}/xkit.sh ..."
  curl -fsSL "${base}/xkit.sh" -o "$tmp" || { err "Скачать не удалось: ${base}/xkit.sh"; rm -f "$tmp"; return 1; }
  # модуль меню — обязателен с v5.0.0 (UI-слой вынесен в отдельный файл)
  tmpm="$(mktemp /tmp/.xkit-menu.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if ! curl -fsSL "${base}/xkit_menu.sh" -o "$tmpm"; then
    if [ -r "${XKIT_MENU_DIR}/xkit_menu.sh" ]; then
      warn "xkit_menu.sh в репо не найден — оставляю установленный (${XKIT_MENU_DIR})"
      tmpm=""
    else
      err "Скачать не удалось: ${base}/xkit_menu.sh (файл меню)"
      err "Залейте xkit_menu.sh в репозиторий (см. GITHUB_SETUP.md) или обновите снова позже"
      rm -f "$tmp" "$tmpm"; return 1
    fi
  fi
  local sumf="${tmp}.sha256" want got
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk 'NR==1{print $1}' "$sumf")"; got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      ok "SHA-256 проверен: xkit.sh $got"
    else
      err "SHA-256 НЕ совпал — обновление отменено (файл битый или изменён)"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    if [ -n "$tmpm" ]; then
      want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
      got="$(sha256sum "$tmpm" | awk '{print $1}')"
      if [ -z "$want" ]; then
        # K-02: меню без суммы не ставим — оставляем установленное
        warn "В пломбе нет строки xkit_menu.sh — меню НЕ обновляю (оставляю установленное)"
        rm -f "$tmpm"; tmpm=""
      elif [ "$want" != "$got" ]; then
        err "SHA-256 xkit_menu.sh НЕ совпал — обновление отменено"
        rm -f "$tmp" "$sumf" "$tmpm"; return 1
      else
        ok "SHA-256 проверен: xkit_menu.sh $got"
      fi
    fi
  else
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      # K-02: fail-closed — без пломбы код не ставится
      err "xkit.sh.sha256 недоступен — обновление ОТМЕНЕНО (K-02: без суммы код не ставится)"
      err "Осознанный обход: XKIT_ALLOW_UNVERIFIED=1 xkit update"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    warn "xkit.sh.sha256 недоступен, но задан XKIT_ALLOW_UNVERIFIED=1 — ставлю без проверки"
  fi
  bash -n "$tmp" || { err "Новый файл не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1; }
  if [ -n "$tmpm" ]; then
    bash -n "$tmpm" || { err "Новый xkit_menu.sh не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf" "$tmpm"; return 1; }
  fi
  local nv; nv="$(grep -m1 '^XKIT_VERSION=' "$tmp" | cut -d'"' -f2)"; nv="${nv:-?}"
  if [ "$nv" = "$XKIT_VERSION" ] && [ "${XKIT_FORCE:-0}" != "1" ]; then
    ok "Уже установлена версия $nv (принудительно: XKIT_FORCE=1 xkit update)"
    rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
    return 0
  fi
  [ -f "$XKIT_BIN" ] && cp -f "$XKIT_BIN" "${XKIT_BIN}.bak"
  if ! install -m 700 "$tmp" "${XKIT_BIN}.new" || ! mv -f "${XKIT_BIN}.new" "$XKIT_BIN"; then
    err "Не удалось заменить $XKIT_BIN"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1
  fi
  if [ -n "$tmpm" ]; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || true
    [ -f "${XKIT_MENU_DIR}/xkit_menu.sh" ] && cp -f "${XKIT_MENU_DIR}/xkit_menu.sh" "${XKIT_MENU_DIR}/xkit_menu.sh.bak"
    if install -m 700 "$tmpm" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
       && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню обновлён: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось обновить ${XKIT_MENU_DIR}/xkit_menu.sh — меню докачается при первом запуске xkit"
    fi
  fi
  rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
  # v5.2: после ядра/меню атомарно обновляем модуль протоколов и TUI.
  xkit_extras_install || warn "Дополнительные компоненты обновятся при следующем запуске"
  ok "Обновлено: v${XKIT_VERSION} -> v${nv} ($XKIT_BIN); резервная копия: ${XKIT_BIN}.bak"
  ok "Конфиг nginx, состояние и подписки не тронуты"
  return 0
}

#=========================== МЕНЮ: МОДУЛЬНЫЙ UI (v5.0.0) ======================
# Меню живёт в отдельном файле xkit_menu.sh (UI-слой), чтобы xkit.sh не
# раздувался: правки меню не трогают ядро. Порядок поиска:
#   1) рядом с самим xkit.sh   2) $XKIT_MENU_DIR (/usr/local/lib/xkit)
#   3) каталог команды xkit    4) /etc/xkit
# Не нашли — докачиваем с XKIT_REPO_URL со сверкой SHA-256 (строка 2 пломбы).

# V-02 (аудит №2): код под root грузится ТОЛЬКО из доверенных мест — владелец
# root, без group/world-write, каталоги /tmp, /var/tmp, /dev/shm запрещены
xkit_dir_trusted() { # $1 каталог, $2 файл -> 0 = доверенный
  local d="$1" f="$2" st myuid
  case "$d" in /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run/shm*) return 1 ;; esac
  myuid="$(id -u 2>/dev/null || echo 0)"
  st="$(stat -Lc '%u %a' "$d" 2>/dev/null)" || return 1
  # владелец = root ИЛИ текущий пользователь (dev-каталог в своей домашке —
  # доверенно; ЧУЖОЙ владелец при запуске под root — нет)
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  st="$(stat -Lc '%u %a' "$f" 2>/dev/null)" || return 1
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  return 0
}

xkit_menu_src() { # -> печатает путь к найденному xkit_menu.sh; 1 = не нашли
  local d f self
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  # №19 (аудит №1): dirname вместо ${XKIT_BIN%/*} (без слэша давал мусорный путь)
  for d in "$(dirname "$self")" "${XKIT_MENU_DIR}" "$(dirname -- "${XKIT_BIN:-/usr/local/bin/xkit}" 2>/dev/null)" "/etc/xkit"; do
    [ -n "$d" ] || continue
    f="$d/xkit_menu.sh"
    [ -r "$f" ] || continue
    # V-02: подозрительное расположение (например, /tmp) — пропускаем кандидата
    if ! xkit_dir_trusted "$d" "$f"; then
      warn "Пропускаю $f: каталог/файл не доверенные (owner/mode, V-02)"
      continue
    fi
    printf '%s\n' "$f"; return 0
  done
  return 1
}

xkit_menu_fetch() { # авто-докачка меню (потеря файла / обновление со старой версии)
  local base="${XKIT_REPO_URL:-}"
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
  local tmp sumf want got
  tmp="$(mktemp /tmp/.xkit-menu.XXXXXX)" || return 1
  curl -fsSL "${base}/xkit_menu.sh" -o "$tmp" || { rm -f "$tmp"; return 1; }
  sumf="$(mktemp /tmp/.xkit-menu-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      err "SHA-256 xkit_menu.sh НЕ совпал — докачка отменена"
      rm -f "$tmp" "$sumf"; return 1
    fi
    if [ -z "$want" ]; then
      # K-02: без суммы докачка fail-open'ом больше не проходит
      err "В пломбе нет строки xkit_menu.sh — докачка отменена (K-02)"
      rm -f "$tmp" "$sumf"; return 1
    fi
  else
    err "Сумма xkit_menu.sh недоступна — докачка отменена (K-02; осознанный обход: XKIT_ALLOW_UNVERIFIED=1)"
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      rm -f "$tmp"; return 1
    fi
    warn "XKIT_ALLOW_UNVERIFIED=1 — ставлю меню без проверки"
  fi
  bash -n "$tmp" 2>/dev/null || { err "xkit_menu.sh не проходит bash -n — докачка отменена"; rm -f "$tmp" "$sumf"; return 1; }
  local rc=0
  # F-1 (аудит №2): раньше local rc=$? стоял после if и всегда был 0 —
  # неудачная установка меню маскировалась «ок»
  if install -m 700 "$tmp" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
     && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
    ok "Модуль меню докачан: ${XKIT_MENU_DIR}/xkit_menu.sh"
  else
    err "Не удалось установить xkit_menu.sh в ${XKIT_MENU_DIR}"
    rc=1
  fi
  rm -f "$tmp" "$sumf"
  return $rc
}

xkit_menu_install() { # положить модуль меню в $XKIT_MENU_DIR (вызывается установщиком)
  local self src
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")/xkit_menu.sh"
  if [ -r "$src" ] && xkit_dir_trusted "$(dirname "$src")" "$src"; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
    # F-2 (аудит №2): раньше cp без ветки неудачи — функция возвращала 0 даже при сбое
    if cp -f "$src" "${XKIT_MENU_DIR}/xkit_menu.sh" && chmod 700 "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось скопировать модуль меню в ${XKIT_MENU_DIR}"
      return 1
    fi
    return 0
  fi
  [ -r "$src" ] && warn "Локальный $src не доверенный (V-02) — меню будет докачано из репо"
  # рядом со скриптом нет (установка из пайпа) — докачаем с репо
  xkit_menu_fetch \
    || warn "xkit_menu.sh не найден рядом и не докачан — меню скачается при первом запуске xkit"
  return 0
}

xkit_load_menu() { # подключить модуль меню (source); 1 = не нашли (ошибка уже напечатана)
  local f
  if f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  # load_xkit_env при ОТСУТСТВИИ env-файла (свежая машина) затирает
  # XKIT_REPO_URL и выходит раньше восстановления — репо-адрес из внешнего
  # env (install.sh пробрасывает его явно) терялся, авто-докачка молчала
  local _repo="${XKIT_REPO_URL:-}"
  load_xkit_env >/dev/null 2>&1 || true
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  if xkit_menu_fetch && f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  err "Не найден файл меню xkit_menu.sh (ищу рядом со скриптом, в ${XKIT_MENU_DIR} и /etc/xkit)"
  err "Обновите установку:  sudo xkit update   либо переустановите через install.sh"
  return 1
}

#=========================== V5.2: TUI И ПРОТОКОЛЫ ============================
xkit_component_fetch() { # $1 имя в репо, $2 конечный файл; SHA-256 обязателен
  local base="${XKIT_REPO_URL:-}" name="$1" dst="$2" tmp sumf want got
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  case "$base" in http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;; http://*) return 1 ;; esac
  tmp="$(mktemp /tmp/.xkit-component.XXXXXX)" || return 1
  sumf="$(mktemp /tmp/.xkit-component-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  curl -fsSL "${base}/${name}" -o "$tmp" && curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" || { rm -f "$tmp" "$sumf"; return 1; }
  want="$(awk -v n="$name" '$2==n{print $1;exit}' "$sumf")"
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { err "SHA-256 ${name} не совпал или отсутствует"; rm -f "$tmp" "$sumf"; return 1; }
  case "$name" in *.sh) bash -n "$tmp" || { rm -f "$tmp" "$sumf"; return 1; } ;; esac
  mkdir -p "$(dirname "$dst")" && install -m 700 "$tmp" "${dst}.new" && mv -f "${dst}.new" "$dst" || { rm -f "$tmp" "$sumf"; return 1; }
  rm -f "$tmp" "$sumf"
  ok "Компонент установлен: $dst"
}

xkit_extras_install() { # протоколы + TUI текущей архитектуры
  local self src arch name rc=0
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")"
  mkdir -p "$XKIT_MENU_DIR" || return 1
  if [ -r "$src/xkit_protocols.sh" ] && xkit_dir_trusted "$src" "$src/xkit_protocols.sh"; then
    [ ! -f "$XKIT_PROTOCOLS_FILE" ] || cp -f "$XKIT_PROTOCOLS_FILE" "${XKIT_PROTOCOLS_FILE}.bak"
    install -m 700 "$src/xkit_protocols.sh" "$XKIT_PROTOCOLS_FILE" || rc=1
  else
    xkit_component_fetch xkit_protocols.sh "$XKIT_PROTOCOLS_FILE" || rc=1
  fi
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) warn "TUI: архитектура $(uname -m) не поддерживается"; return "$rc" ;; esac
  name="xkit-tui-linux-${arch}"
  if [ -r "$src/$name" ] && xkit_dir_trusted "$src" "$src/$name"; then
    [ ! -f "$XKIT_TUI_FILE" ] || cp -f "$XKIT_TUI_FILE" "${XKIT_TUI_FILE}.bak"
    install -m 700 "$src/$name" "$XKIT_TUI_FILE" || rc=1
  else
    xkit_component_fetch "$name" "$XKIT_TUI_FILE" || rc=1
  fi
  return "$rc"
}

xkit_protocols_load() {
  local f="$XKIT_PROTOCOLS_FILE" self
  if [ ! -r "$f" ]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    [ -r "$(dirname "$self")/xkit_protocols.sh" ] && f="$(dirname "$self")/xkit_protocols.sh"
  fi
  if [ -r "$f" ] && xkit_dir_trusted "$(dirname "$f")" "$f"; then
    XKIT_PROTOCOLS_FILE="$f"; . "$f"; return 0
  fi
  err "Модуль протоколов не найден или не доверен: $f (выполните xkit update)"
  return 1
}

xkit_tui_run() {
  [ "${XKIT_TUI:-1}" = 1 ] && [ "${FORCE_CLASSIC:-0}" != 1 ] || return 1
  [ -t 0 ] && [ -t 1 ] || return 1
  if [ ! -x "$XKIT_TUI_FILE" ]; then
    local self0 arch0
    self0="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    case "$(uname -m)" in x86_64) arch0=amd64 ;; aarch64|arm64) arch0=arm64 ;; *) arch0=unknown ;; esac
    [ -r "$(dirname "$self0")/xkit-tui-linux-${arch0}" ] && XKIT_TUI_FILE="$(dirname "$self0")/xkit-tui-linux-${arch0}"
  fi
  if [ ! -x "$XKIT_TUI_FILE" ] && [ "$(id -u)" = 0 ]; then
    load_xkit_env >/dev/null 2>&1 || true
    xkit_extras_install >/dev/null 2>&1 || true
  fi
  [ -x "$XKIT_TUI_FILE" ] && xkit_dir_trusted "$(dirname "$XKIT_TUI_FILE")" "$XKIT_TUI_FILE" || return 1
  local self; self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  "$XKIT_TUI_FILE" --xkit "$self"
}

xkit_snapshot() { # только агрегаты; без UUID, privateKey, паролей и токенов
  load_xkit_env >/dev/null 2>&1 || true
  local host="${XKIT_HOST:-}" mode=solo nodes=0 nodes_ok=0 clients=0 cert_days=-1 backup_hours=-1
  local nginx=false xui=false xray=false protocols='[]' inbounds='' nodes_metrics='[]' metrics_generated=0
  systemctl is-active --quiet nginx 2>/dev/null && nginx=true
  systemctl is-active --quiet x-ui 2>/dev/null && xui=true
  pgrep -x xray >/dev/null 2>&1 && xray=true
  if [ -r "$XKIT_NODES" ]; then nodes="$(jq 'length' "$XKIT_NODES" 2>/dev/null || echo 0)"; fi
  [[ "$nodes" =~ ^[0-9]+$ ]] || nodes=0
  [ "$nodes" -gt 0 ] && mode=master
  if [ -r "$XKIT_NODES_METRICS" ]; then
    # Явный whitelist: host, заметки, реквизиты панели и любые новые поля кэша
    # автоматически в snapshot не попадают.
    # (з.8, аудит v5.2.1): interval_up/interval_down в whitelist — иначе TUI не может
    # показать «↑/↓ за интервал» отдельно от общего
    nodes_metrics="$(jq -c '[.nodes[]?|{name,status,panel,latency_ms,cpu_pct,ram_pct,load1,total,clients,resources,rate_bps,interval_total,interval_up,interval_down}]' "$XKIT_NODES_METRICS" 2>/dev/null || echo '[]')"
    metrics_generated="$(jq -r '.generated // 0' "$XKIT_NODES_METRICS" 2>/dev/null || echo 0)"
    nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "$XKIT_NODES_METRICS" 2>/dev/null || echo 0)"
  elif [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
  fi
  [[ "$nodes_ok" =~ ^[0-9]+$ ]] || nodes_ok=0
  [[ "$metrics_generated" =~ ^[0-9]+$ ]] || metrics_generated=0
  if [ -r "${XKIT_CRT:-}" ]; then
    local end_epoch now_epoch
    end_epoch="$(date -d "$(openssl x509 -in "$XKIT_CRT" -noout -enddate 2>/dev/null | cut -d= -f2-)" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"; [ "$end_epoch" -gt 0 ] && cert_days=$(( (end_epoch-now_epoch)/86400 ))
  fi
  local latest; latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'xkit-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [ -n "$latest" ]; then backup_hours=$(( ($(date +%s)-$(stat -c %Y "$latest" 2>/dev/null || date +%s))/3600 )); fi
  if kit_session >/dev/null 2>&1; then
    inbounds="$(api_list 2>/dev/null || true)"
    clients="$(jq '[.[]?|(.settings|fromjson?|.clients[]?)|.email]|unique|length' <<<"$inbounds" 2>/dev/null || echo 0)"
  fi
  [[ "$clients" =~ ^[0-9]+$ ]] || clients=0
  if xkit_protocols_load >/dev/null 2>&1; then
    protocols="$(protocols_snapshot_json 2>/dev/null || echo '[]')"
  fi
  jq -nc --arg host "$host" --arg mode "$mode" --arg generated "$(date -Iseconds)" \
    --argjson nodes "$nodes" --argjson nodes_ok "$nodes_ok" --argjson clients "$clients" \
    --argjson nginx "$nginx" --argjson xui "$xui" --argjson xray "$xray" \
    --argjson cert_days "$cert_days" --argjson backup_hours "$backup_hours" --argjson protocols "$protocols" \
    --argjson nodes_metrics "$nodes_metrics" --argjson metrics_generated "$metrics_generated" \
    '{host:$host,mode:$mode,nodes:$nodes,nodes_ok:$nodes_ok,clients:$clients,nginx:$nginx,xui:$xui,xray:$xray,cert_days:$cert_days,backup_hours:$backup_hours,protocols:$protocols,nodes_metrics:$nodes_metrics,metrics_generated:$metrics_generated,generated:$generated}'
}
