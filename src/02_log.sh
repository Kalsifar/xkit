
log()  { echo -e "${BLUE}[INFO] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK]   $*${NC}"; }
# warn — диагностика, а не данные: ВСЕГДА в stderr. Иначе warn внутри функции,
# чей stdout захватывается ($(...) / with_spinner -o), попадает в значение —
# например PANEL_SCHEME становился "[WARN] …\nhttp" и ломал api_url (ревью v4.7.0)
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERR ] $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

#=========================== UX-ХЕЛПЕРЫ УСТАНОВКИ =============================
# confirm «Вопрос [y/N]: " [y|n] — 0=да. Принимаются латинское y/yes,
# русское д/да и кириллическая у (визуально похожа на y). Любой другой ответ,
# включая «нет», означает отказ. XKIT_YES=1 (CI) = согласие на всё;
# EOF (Ctrl-D) = отмена, а не молчаливый дефолт
confirm() {
  local prompt="$1" default="${2:-n}" ans
  [ "${XKIT_YES:-0}" = "1" ] && return 0
  read -r -p "$prompt" ans || return 1
  ans="${ans:-$default}"
  # Не используем Unicode-символы внутри regex [...]: в C-локали байтовое
  # сравнение может ошибочно принять «нет». Явные префиксы безопасны.
  case "$ans" in
    y*|Y*|д*|Д*|у*|У*) return 0 ;;
    *)                  return 1 ;;
  esac
}

# шаги установки: [n/7] + 10-клеточный индикатор (non-TTY — просто текст)
STEP=0; STEPS=7
step() {
  STEP=$((STEP+1))
  local n=$(( STEP * 10 / STEPS )) bar="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$i" -le "$n" ]; then bar+="#"; else bar+="-"; fi
  done
  echo ""
  echo -e "${GREEN}[${STEP}/${STEPS}]${NC} $*  [${bar}]"
}

# временные файлы установки: регистрируются и снимаются trap'ом INT/TERM/EXIT
XKIT_TMPS=()
xkit_tmp_track() { XKIT_TMPS+=("$1"); }
xkit_install_cleanup() {
  local f
  for f in "${XKIT_TMPS[@]:-}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done
  return 0
}
xkit_install_traps_on() {
  trap 'xkit_install_cleanup; [ -n "${XKIT_LOG:-}" ] && printf "Прервано. Подробности: %s\n" "$XKIT_LOG" >&2; exit 130' INT TERM
  trap 'xkit_install_cleanup' EXIT
}
xkit_install_traps_off() { trap - INT TERM EXIT; }

# with_spinner "сообщение" cmd [args...] — спиннер на stderr, пока cmd работает;
# вывод cmd пишется в $XKIT_LOG, при ошибке хвост в терминал. Без TTY (или
# XKIT_NO_ANIM=1) — прозрачный прогон без анимации. Опция -o: stdout команды
# Возвращается вызывающему (для функций с результатом: detect_panel_scheme)
with_spinner() {
  local capture=0
  [ "${1:-}" = "-o" ] && { capture=1; shift; }
  local msg="$1"; shift
  if [ "${IS_TTY:-0}" != "1" ] || [ "${XKIT_NO_ANIM:-0}" = "1" ]; then
    "$@"
    return $?
  fi
  local tmplog pid rc=1 i=0
  tmplog="$(mktemp /tmp/xkit-spin.XXXXXX)" || { "$@"; return $?; }
  xkit_tmp_track "$tmplog"
  # -o (захват значения): stderr НЕ заворачиваем в tmplog — иначе диагностика
  # (warn/err) возвращается вызывающему вместе с данными и ломает значение
  # (ревью v4.7.0: PANEL_SCHEME = "[WARN] …\nhttp"). stderr идёт в терминал —
  # то же поведение, что и в non-TTY пути выше. Без -o — тишина: всё в tmplog.
  if [ "$capture" = "1" ]; then
    "$@" >"$tmplog" &
  else
    "$@" >"$tmplog" 2>&1 &
  fi
  pid=$!
  local marks='-\|/'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s[%s]%s %s   ' "$GREEN" "${marks:$i:1}" "$NC" "$msg" >&2
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  wait "$pid"; rc=$?
  printf '\r\033[K' >&2                      # стереть строку спиннера
  if [ "$capture" = "1" ]; then
    if [ $rc -eq 0 ]; then cat "$tmplog"; else tail -n 10 "$tmplog" >&2; fi
  else
    [ -n "${XKIT_LOG:-}" ] && cat "$tmplog" >>"$XKIT_LOG" 2>/dev/null
    if [ $rc -eq 0 ]; then
      printf '%s[OK]%s   %s\n' "$GREEN" "$NC" "$msg" >&2
    else
      printf '%s[ERR]%s  %s%s\n' "$RED" "$NC" "$msg" "${XKIT_LOG:+ (подробности: $XKIT_LOG)}" >&2
      tail -n 20 "$tmplog" | sed 's/^/       /' >&2
    fi
  fi
  rm -f "$tmplog"
  return $rc
}

# XKIT_LOG — полный лог долгоиграющей операции (установка/переустановка/
# удаление): всё, что оборачивается спиннером, попадает сюда. chmod 600 —
# установщики печатают реквизиты
xkit_log_begin() { # $1 = префикс имени (install|reinstall|uninstall)
  # Первый вызов открывает новый лог. Повторный вызов в том же процессе
  # (reinstall: uninstall -> install) переиспользует уже открытый файл и
  # НЕ очищает его — обе фазы остаются в одном логе, имя — по первой фазе
  # (ревью v4.7.0: раньше `: >` затирало лог фазы удаления).
  if [ -n "${XKIT_LOG:-}" ]; then
    [ -e "$XKIT_LOG" ] || : >"$XKIT_LOG" 2>/dev/null || true
    return 0
  fi
  XKIT_LOG="/var/log/xkit-$1-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$XKIT_LOG")" 2>/dev/null || true
  : >"$XKIT_LOG" 2>/dev/null || true
  chmod 600 "$XKIT_LOG" 2>/dev/null || true
}

CERTBOT_MIN_IP="5.3"                 # certbot для --ip-address
XUI_INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

# K-02 (аудит №2): установщик 3X-UI — по тегу ПОСЛЕДНЕГО РЕЛИЗА (master плавает
# и может измениться в любой момент). Переопределить: XKIT_3XUI_TAG=vX.Y.Z
xui_install_url() {
  local tag="${XKIT_3XUI_TAG:-}"
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null \
      | jq -r '.tag_name // ""' 2>/dev/null || true)"
  fi
  if [[ "$tag" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
    printf 'https://raw.githubusercontent.com/mhsanaei/3x-ui/%s/install.sh' "$tag"
  else
    warn "Не удалось определить тег релиза 3X-UI — качаю master (зафиксируйте: XKIT_3XUI_TAG=vX.Y.Z)" >&2
    printf '%s' "$XUI_INSTALLER_URL"
  fi
}
XKIT_DIR="/etc/xkit"
XKIT_ENV="${XKIT_DIR}/xkit.env"
XKIT_ROUTES="${XKIT_DIR}/routes.tsv"
XKIT_NODES="${XKIT_DIR}/nodes.json"
XKIT_EXPIRY="${XKIT_DIR}/expiry.tsv"     # сроки аренды: scope<TAB>id<TAB>date<TAB>note
XKIT_DASH_DIR="/var/lib/xkit/dash"        # веб-дашборд (index.html + data.json)
XKIT_NODES_METRICS="${XKIT_NODES_METRICS:-/var/lib/xkit/nodes-metrics.json}" # общий кэш TUI/дашборда
XKIT_DASH_HTPASSWD="/etc/nginx/.xkit-dash.htpasswd"  # Basic Auth дашборда
XKIT_INFO_FILE="/root/xkit-info.txt"      # сводка-реквизиты (терминал + файл)
XKIT_NOTIFY_STATE="${XKIT_DIR}/notify.state"  # состояние Telegram-алертов (гистерезис/дедуп)
XKIT_BIN="/usr/local/bin/xkit"
XKIT_MENU_DIR="${XKIT_MENU_DIR:-/usr/local/lib/xkit}"  # модули XKIT
XKIT_PROTOCOLS_FILE="${XKIT_PROTOCOLS_FILE:-${XKIT_MENU_DIR}/xkit_protocols.sh}"
XKIT_TUI_FILE="${XKIT_TUI_FILE:-${XKIT_MENU_DIR}/xkit-tui}"
SUBS_DIR="/var/lib/xkit/subs"
BACKUP_DIR="/var/backups/xkit"
# cron-файлы кита — переменные (не хардкод), чтобы uninstall и тесты работали
# с переопределёнными путями
XKIT_CRON_MAIN="/etc/cron.d/xkit"
XKIT_CRON_DASH="/etc/cron.d/xkit-dash"
XKIT_CRON_NOTIFY="/etc/cron.d/xkit-notify"
XKIT_CONF="/etc/nginx/sites-available/xkit.conf"
XKIT_CONF_LINK="/etc/nginx/sites-enabled/xkit.conf"
XUI_RESULT="/etc/x-ui/install-result.env"
XUI_DB="/etc/x-ui/x-ui.db"
