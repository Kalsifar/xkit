#!/bin/bash
# Тесты XKIT v4.9.0 (замечания с живой установки):
#  1) версия/синтаксис трёх скриптов
#  2) TTY-детект: цвета гаснут при не-терминале (поведенчески)
#  3) UX-хелперы поведенчески: confirm (XKIT_YES/EOF/дефолт), step (бар),
#     with_spinner (passthrough / -o захват stdout / ошибка rc)
#  4) preflight: меню «уже установлен» (0=выход/EOF, 3=поверх после подтверждения,
#     отмена), XKIT_FORCE, ресурс-проверки (диск/RAM — на живых данных)
#  5) uninstall: поведенчески в песочнице (переопределённые пути) — бэкап
#     создаётся, файлы удаляются, бэкапы сохраняются; отмена без YES;
#     --full статика (3X-UI пути, KEEP_BIN)
#  6) reinstall: статика цепочки; main-команды; usage
#  7) install.sh: -y/--yes/--force разбор, TTY-цвета, trap INT TERM
#  8) v3.2.1: with_spinner + deps_install обёрнут
#  9) фикс ревью v4.7.0 (блокер): warn -> stderr, with_spinner -o не
#     захватывает диагностику (PANEL_SCHEME = ровно http/https), лог
#     reinstall не затирается, uninstall --full сбрасывает failed-статус
#  10) правки ревью №2: node_add EOF=отмена (симметрия с v3.2.1),
#      проброс XKIT_YES/FORCE через sudo env в install.sh, warn -> stderr там же
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${SCRIPT_DIR%/tests}"
XKIT="${BASE}/xkit.sh"
V3="${BASE}/nginx-xray-manager-v3.sh"
INST="${BASE}/install.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
[ -f "$V3" ]   || V3="${SCRIPT_DIR%/tests}/nginx-xray-manager-v3.sh"
[ -f "$INST" ] || INST="${SCRIPT_DIR%/tests}/install.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия и синтаксис ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
! rg -q 'НОВОЕ В v[0-9]' "$XKIT"; ck "шапка ядра не содержит истории версий" $?
rg -q 'Документация: README.md' "$XKIT"; ck "шапка ядра ссылается на README.md" $?
rg -q 'XRAY MESH MANAGER  v3\.2\.1' "$V3"; ck "v3: версия 3.2.1" $?
[ -f "$BASE/GITHUB_SETUP.md" ] && rg -q 'raw.githubusercontent.com' "$BASE/GITHUB_SETUP.md"; ck "GITHUB_SETUP.md в пакете (one-line install)" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?
bash -n "$V3" 2>/dev/null; ck "bash -n v3" $?
bash -n "$INST" 2>/dev/null; ck "bash -n install.sh" $?

echo "=== 2. TTY-детект (цвета гаснут при не-терминале) ==="
# тест-харнесс сам пайповый: [ -t 1 ] ложно -> IS_TTY=0, цвета пусты.
# (живой pty в песочнице не воспроизводится — TTY-ветка покрыта статикой ниже)
out="$(bash -c 'source "$1" 2>/dev/null; echo "IS_TTY=$IS_TTY GREEN=[${GREEN}] NC=[${NC}]"' _ "$XKIT" 2>/dev/null)"
[ "$out" = "IS_TTY=0 GREEN=[] NC=[]" ]; ck "xkit: пайп -> цвета пустые, IS_TTY=0" $?
# TTY-ветка кода: ANSI-коды + IS_TTY=1 задаются, не-TTY — гасятся (статика)
rg -qF 'if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then' "$XKIT" \
  && rg -qF 'IS_TTY=1' "$XKIT" && rg -qF 'IS_TTY=0' "$XKIT" \
  && rg -qF "GREEN=''" "$XKIT"; ck "xkit: TTY-ветка задаёт цвета, не-TTY гасит (статика)" $?
# TTY-детект install.sh изолированно: source ТОЛЬКО шапки (до разбора аргументов) —
# иначе полный source с ником kalsifar реально скачивает xkit.sh (зависимость от сети)
awk '/# --- разбор аргументов/{exit} {print}' "$INST" > "$T/inst_head.sh"
out="$(bash -c 'source "$1" 2>/dev/null; printf "[%s][%s]" "$C_G" "$C_N"' _ "$T/inst_head.sh" 2>/dev/null)"
[ "$out" = "[][]" ]; ck "install.sh: пайп -> цвета пустые (шапка с TTY-детектом)" $?
rg -q 'XKIT_NO_COLOR' "$XKIT" && rg -q 'XKIT_NO_COLOR' "$INST"; ck "override XKIT_NO_COLOR в обоих" $?

echo "=== 3. UX-хелперы поведенчески ==="
# confirm: EOF=отмена, y/д/да/кириллическая у=да, «нет»=отказ,
# пусто использует дефолт, XKIT_YES=да без ввода
bash -c '
source "$1" 2>/dev/null
r=0; f=0
echo -n "" | confirm "q [y/N]: " n && f=$((f+1)) || r=$((r+1))      # EOF
echo "y" | confirm "q [y/N]: " n && r=$((r+1)) || f=$((f+1))       # y
echo "у" | confirm "q [y/N]: " n && r=$((r+1)) || f=$((f+1))       # кириллическая у
echo "д" | confirm "q [y/N]: " n && r=$((r+1)) || f=$((f+1))       # д
echo "да" | confirm "q [y/N]: " n && r=$((r+1)) || f=$((f+1))      # да
echo "нет" | confirm "q [y/N]: " n && f=$((f+1)) || r=$((r+1))     # нет
echo ""  | confirm "q [y/N]: " n && f=$((f+1)) || r=$((r+1))       # пусто, дефолт n
echo ""  | confirm "q [Y/n]: " y && r=$((r+1)) || f=$((f+1))       # пусто, дефолт y
XKIT_YES=1 confirm "q [y/N]: " n && r=$((r+1)) || f=$((f+1))       # CI-режим
echo "CONFIRM_PASS=$r"; echo "CONFIRM_FAIL=$f"
' _ "$XKIT" > "$T/confirm.txt" 2>/dev/null
p="$(sed -n 's/^CONFIRM_PASS=//p' "$T/confirm.txt")"; f="$(sed -n 's/^CONFIRM_FAIL=//p' "$T/confirm.txt")"
[ "${f:-1}" = "0" ] && [ "${p:-0}" = "9" ]; ck "confirm: 9 сценариев (EOF/y/русское да/нет/дефолты/XKIT_YES)" $?

# step: [n/7] + 10-клеточный бар
out="$(bash -c 'source "$1" 2>/dev/null; STEP=0; STEPS=7; step "Пакеты"' _ "$XKIT" 2>/dev/null)"
printf '%s' "$out" | grep -qE '\[1/7\] Пакеты +\[#+-{9}\]'; ck "step: [1/7] + бар 10 клеток (1#/9-)" $?
out="$(bash -c 'source "$1" 2>/dev/null; STEP=6; STEPS=7; step "Финал"' _ "$XKIT" 2>/dev/null)"
printf '%s' "$out" | grep -qE '\[7/7\] Финал +\[#-{2}#+\]|\[7/7\] Финал +\[#{9}-\]|\[7/7\] Финал +\[#{10}\]'; ck "step: [7/7] бар почти/полностью заполнен" $?

# with_spinner: non-TTY прозрачный прогон (stdout наружу, rc сохраняется)
out="$(bash -c 'source "$1" 2>/dev/null; with_spinner "тест" bash -c "echo out-ok; exit 0"' _ "$XKIT" 2>/dev/null)"
[ "$out" = "out-ok" ]; ck "with_spinner: non-TTY passthrough (stdout наружу)" $?
bash -c 'source "$1" 2>/dev/null; with_spinner "упадёт" bash -c "exit 7"' _ "$XKIT" >/dev/null 2>&1
[ "$?" = "7" ]; ck "with_spinner: код ошибки сохраняется" $?
# -o: stdout команды возвращается вызывающему (detect_panel_scheme-паттерн)
v="$(bash -c 'source "$1" 2>/dev/null; with_spinner -o "схема..." bash -c "echo https"' _ "$XKIT" 2>/dev/null)"
[ "$v" = "https" ]; ck "with_spinner -o: захват stdout (для функций со значением)" $?
# ошибка при XKIT_NO_ANIM=1 — тоже passthrough
out="$(bash -c 'source "$1" 2>/dev/null; XKIT_NO_ANIM=1 with_spinner "тест" bash -c "echo anim-off"' _ "$XKIT" 2>/dev/null)"
[ "$out" = "anim-off" ]; ck "with_spinner: XKIT_NO_ANIM=1 отключает анимацию" $?
# запись в XKIT_LOG идёт в TTY-режиме спиннера (статика: cat tmplog >> XKIT_LOG);
# при не-TTY вывод команды идёт в терминал целиком — то, что нужно curl|bash
rg -qF 'cat "$tmplog" >>"$XKIT_LOG"' "$XKIT"; ck "with_spinner: TTY-режим дописывает вывод в XKIT_LOG" $?

echo "=== 4. preflight: «уже установлен» и ресурсы ==="
# меню при существующем env: 0=выход, EOF=выход, 3+y=продолжить, 3+пусто=отмена
mk_env() { printf 'XKIT_VERSION="4.9.0"\nXKIT_HOST="t.example.com"\nXKIT_SUB_TOKEN="tok123"\n' > "$T/xkit.env"; }
run_menu() { mk_env; IN="$1" bash -c '
source "$1" 2>/dev/null
XKIT_ENV="'"$T"'/xkit.env"
printf "%b" "$IN" | preflight_installed_menu >/dev/null 2>&1; echo $?
' _ "$XKIT" 2>/dev/null; }
[ "$(run_menu '0\n')" = "1" ]; ck "меню: выбор 0 -> остановка установки" $?
[ "$(run_menu '')" = "1" ]; ck "меню: EOF -> остановка (безопасный дефолт)" $?
[ "$(run_menu '3\ny\n')" = "0" ]; ck "меню: 3 + y -> продолжить поверх (env подхватится)" $?
[ "$(run_menu '3\n\n')" = "1" ]; ck "меню: 3 + пусто -> отмена (не молчаливое продолжение)" $?
[ "$(run_menu '9\n')" = "1" ]; ck "меню: мусорный ввод -> остановка" $?
# Ветка 2 проходит реальное подтверждение «да», но destructive-операции заменены
# безопасной заглушкой: проверяем, что выполнение дошло именно до uninstall.
menu_reinstall_out="$(bash -c '
source "$1" 2>/dev/null
require_root(){ :; }
xkit_log_begin(){ :; }
xkit_uninstall(){ echo REINSTALL_UNINSTALL_REACHED; return 1; }
printf "2\nда\n" | preflight_installed_menu
' _ "$XKIT" 2>&1)"
rg -qF 'xkit_self_update; return 1' "$XKIT" && rg -qF 'xkit_reinstall; return 1' "$XKIT" \
  && grep -qF 'REINSTALL_UNINSTALL_REACHED' <<<"$menu_reinstall_out"
ck "меню: 2 + да -> reinstall дошёл до защищённого удаления" $?
# preflight: env существует + FORCE -> идём дальше (меню пропущено)
bash -c '
source "$1" 2>/dev/null
XKIT_ENV="'"$T"'/xkit.env"; XKIT_FORCE=1
# дальше ресурс-проверки: в песочнице порты свободны, места хватает;
# сеть может отсутствовать -> warns>0 -> confirm -> EOF -> return 1.
# ГЛАВНОЕ: не сработало меню «уже установлен» (нет «Выбор [0]» в выводе)
out="$(preflight </dev/null 2>&1)"; rc=$?
printf "%s" "$out" | grep -q "Выбор \[0\]" && echo MENU_SHOWN || echo MENU_SKIPPED
' _ "$XKIT" 2>/dev/null | grep -q MENU_SKIPPED; ck "preflight: XKIT_FORCE=1 пропускает меню" $?
# preflight без env (чистая установка): меню нет, доходит до ресурс-проверок
bash -c '
source "$1" 2>/dev/null
XKIT_ENV="'"$T"'/no-such.env"
out="$(preflight </dev/null 2>&1)"; rc=$?
printf "%s" "$out" | grep -q "уже установлен" && echo BAD_SHOWN || echo CLEAN_OK
' _ "$XKIT" 2>/dev/null | grep -q CLEAN_OK; ck "preflight: чистый сервер -> без меню" $?
rg -qF 'df -Pm /' "$XKIT" && rg -qF '/proc/meminfo' "$XKIT" && rg -qF 'ss -ltnpH' "$XKIT"; ck "preflight: диск/RAM/порты проверяются" $?
rg -qF 'curl -fsS --max-time 3' "$XKIT"; ck "preflight: проверка сети с таймаутом" $?

echo "=== 5. uninstall (поведенчески в песочнице) ==="
# переопределяем все пути: require_root и логи глушим, файлы — в $T
setup_sandbox() {
  rm -rf "$T/box"; mkdir -p "$T/box/backups" "$T/box/etc" "$T/box/lib/subs" "$T/box/lib/dash" "$T/box/cron"
  mkdir -p "$T/box/etc/xkit/ssh" "$T/box/nginx/sites-available" "$T/box/nginx/sites-enabled"
  printf 'XKIT_VERSION="4.9.0"\nXKIT_HOST="t.example.com"\nPANEL_PORT="2090"\nXKIT_SUB_TOKEN="tok"\n' > "$T/box/etc/xkit/xkit.env"
  echo "ssh-key-data" > "$T/box/etc/xkit/id_ed25519"
  echo "route" > "$T/box/etc/xkit/routes.tsv"
  echo "sub" > "$T/box/lib/subs/sub123"
  echo "cron" > "$T/box/cron/xkit"; echo "cron2" > "$T/box/cron/xkit-dash"; echo "cron3" > "$T/box/cron/xkit-notify"
  echo "conf" > "$T/box/nginx/sites-available/xkit.conf"
  ln -sf "$T/box/nginx/sites-available/xkit.conf" "$T/box/nginx/sites-enabled/xkit.conf"
  echo "htpasswd" > "$T/box/nginx/.xkit-dash.htpasswd"
  echo "info" > "$T/box/info.txt"
  echo "bin" > "$T/box/xkit-bin"
  # старый бэкап — должен выжить (find -mtime +13 его не тронет)
  echo "old-backup" > "$T/box/backups/xkit-20200101-000000.tar.gz"
}
run_uninstall() { # $1 = флаг uninstall, $2 = ввод stdin (строка), $3 = доп. env (XKIT_YES=1)
  setup_sandbox
  IN="${2:-}" bash -c '
source "$1" 2>/dev/null
require_root() { :; }
xkit_log_begin() { XKIT_LOG="/dev/null"; }
xkit_install_traps_on() { :; }
xkit_install_traps_off() { :; }
XKIT_DIR="'"$T"'/box/etc/xkit"; XKIT_ENV="$XKIT_DIR/xkit.env"
XKIT_CRON_MAIN="'"$T"'/box/cron/xkit"; XKIT_CRON_DASH="'"$T"'/box/cron/xkit-dash"; XKIT_CRON_NOTIFY="'"$T"'/box/cron/xkit-notify"
XKIT_CONF="'"$T"'/box/nginx/sites-available/xkit.conf"; XKIT_CONF_LINK="'"$T"'/box/nginx/sites-enabled/xkit.conf"
XKIT_DASH_HTPASSWD="'"$T"'/box/nginx/.xkit-dash.htpasswd"
XKIT_INFO_FILE="'"$T"'/box/info.txt"; XKIT_BIN="'"$T"'/box/xkit-bin"
SUBS_DIR="'"$T"'/box/lib/subs"
BACKUP_DIR="'"$T"'/box/backups"
'"$3"'
printf "%s\n" "${IN:-}" | xkit_uninstall '"$1"' >/dev/null 2>&1; echo $?
' _ "$XKIT" 2>/dev/null
}
rc="$(run_uninstall "" "YES" "")"
[ "$rc" = "0" ]; ck "uninstall: YES -> проходит (rc=0)" $?
# после успешного uninstall: файлы удалены, бэкапы (старый+свежий) живы
[ ! -e "$T/box/etc/xkit" ] && [ ! -e "$T/box/lib/subs" ] && [ ! -e "$T/box/cron/xkit" ] \
  && [ ! -e "$T/box/nginx/sites-available/xkit.conf" ] && [ ! -L "$T/box/nginx/sites-enabled/xkit.conf" ] \
  && [ ! -e "$T/box/nginx/.xkit-dash.htpasswd" ] && [ ! -e "$T/box/xkit-bin" ]
ck "uninstall: env/маршруты/подписки/cron/nginx-сайт/htpasswd/бин удалены" $?
[ -f "$T/box/backups/xkit-20200101-000000.tar.gz" ]; ck "uninstall: старый бэкап сохранён" $?
nb="$(ls "$T/box/backups"/xkit-*.tar.gz 2>/dev/null | wc -l)"
[ "$nb" -ge 2 ]; ck "uninstall: свежий бэкап создан перед удалением ($nb шт)" $?
rc="$(run_uninstall "" "" "")"
[ "$rc" = "1" ]; ck "uninstall: без YES (EOF) -> отмена, ничего не удалено" $?
[ -e "$T/box/etc/xkit/xkit.env" ] && [ -e "$T/box/xkit-bin" ]; ck "uninstall: отмена не тронула файлы" $?
rc="$(run_uninstall "" "" "XKIT_YES=1;")"
[ "$rc" = "0" ]; ck "uninstall: XKIT_YES=1 -> без вопросов (CI)" $?
rg -qF 'backup_now || { err "Бэкап не удался — удаление отменено (безопасность)"; return 1; }' "$XKIT"; ck "uninstall: провал бэкапа = отмена" $?
rg -qF 'ufw delete deny' "$XKIT"; ck "uninstall: UFW deny панели убирается" $?
rg -qF 'allow 22/80/443 не трогаем' "$XKIT" || rg -qF 'UFW-правила SSH/80/443' "$XKIT"; ck "uninstall: allow SSH/80/443 не трогаются (задокументировано)" $?
# --full статика: 3X-UI пути, KEEP_BIN для reinstall
rg -qF 'rm -rf /etc/systemd/system/x-ui.service.d /etc/x-ui /usr/local/x-ui /etc/nginx/ssl' "$XKIT"; ck "uninstall --full: 3X-UI + nginx/ssl сносятся" $?
rg -qF 'KEEP_BIN=1 xkit_uninstall --full' "$XKIT"; ck "reinstall: KEEP_BIN=1 (бин обновит установка)" $?

echo "=== 6. reinstall + main/usage ==="
rg -qF 'xkit_log_begin reinstall' "$XKIT" && rg -qF 'one_step_install   # $XKIT_ENV уже удалён' "$XKIT"; ck "reinstall: бэкап -> uninstall --full -> one_step_install" $?
rg -qF 'confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }' "$XKIT"; ck "reinstall: подтверждение перед сносом" $?
rg -qF 'reinstall) require_root; xkit_reinstall ;;' "$XKIT" && rg -qF 'uninstall) shift; require_root; xkit_uninstall' "$XKIT"; ck "main: субкоманды reinstall/uninstall" $?
rg -qF 'xkit reinstall' "$XKIT" && rg -qF 'xkit uninstall [--full]' "$XKIT"; ck "usage: reinstall/uninstall описаны" $?
rg -qF 'XKIT_FORCE=1 (установка поверх существующей без меню)' "$XKIT"; ck "usage: XKIT_YES/XKIT_FORCE описаны" $?
# one_step_install: preflight первым делом + env подхватывается при «поверх»
awk '/^one_step_install\(\)/{f=1} f && /preflight \|\| return 1/{p=1} f && /load_xkit_env 2>\/dev\/null \|\| true/{l=1} f && /^}$/{exit} END{exit !(p&&l)}' "$XKIT"
ck "one_step_install: preflight + load_xkit_env (сохранение состояния при «поверх»)" $?
rg -qF 'a="3"' "$XKIT" && rg -qF 'if [ "${XKIT_YES:-0}" = "1" ]; then' "$XKIT"; ck "«Что дальше?»: XKIT_YES=1 -> пункт 3 без вопросов" $?

echo "=== 7. install.sh ==="
rg -qF -- '-y|--yes)  export XKIT_YES=1 ;;' "$INST" && rg -qF -- '--force)   export XKIT_FORCE=1 ;;' "$INST"; ck "разбор -y/--yes/--force" $?
# behavior: флаги попадают в env дочернего процесса и НЕ попадают в XKIT_ARGS
out="$(bash -c 'set -a; . /dev/stdin <<"EOI"
# мини-копия разбора install.sh
URL_ARG=""; XKIT_ARGS=()
for a in "$@"; do
  case "$a" in
    -y|--yes)  export XKIT_YES=1 ;;
    --force)   export XKIT_FORCE=1 ;;
    *) if [ -z "$URL_ARG" ] && printf "%s" "$a" | grep -q "^https\?://"; then URL_ARG="$a"; else XKIT_ARGS+=("$a"); fi ;;
  esac
done
echo "ARGS=${XKIT_ARGS[*]-}|YES=${XKIT_YES:-0}|FORCE=${XKIT_FORCE:-0}|URL=${URL_ARG:-}"
EOI
' _ install -y --force 2>/dev/null)"
[ "$out" = "ARGS=install|YES=1|FORCE=1|URL=" ]; ck "флаги пробрасываются, субкоманда не съедается" $?
rg -qF "trap 'rm -rf \"\$WORK\"' EXIT" "$INST" && rg -qF "exit 130' INT TERM" "$INST"; ck "trap EXIT + INT/TERM" $?
rg -qF 'if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then' "$INST"; ck "install.sh: TTY-детект" $?
rg -qF 'Обнаружен установленный xkit' "$INST"; ck "install.sh: ранняя подсказка при установленном xkit" $?

echo "=== 8. v3.2.1 ==="
rg -q '^with_spinner\(\)' "$V3"; ck "v3: with_spinner есть" $?
rg -qF 'with_spinner "Установка пакетов..." env DEBIAN_FRONTEND=noninteractive' "$V3"; ck "v3: deps_install обёрнут в спиннер" $?
rg -qF '[ ! -t 2 ]' "$V3"; ck "v3: спиннер гвардится TTY" $?
rg -qF 'XMESH_NO_ANIM' "$V3"; ck "v3: override XMESH_NO_ANIM" $?
# v3 спиннер поведенчески (non-TTY из теста = passthrough)
out="$(bash -c 'source "$1" 2>/dev/null; with_spinner "тест" bash -c "echo v3-ok"' _ "$V3" 2>/dev/null | tail -1)"
[ "$out" = "v3-ok" ]; ck "v3: with_spinner non-TTY passthrough" $?

echo "=== 9. ФИКС РЕВЬЮ v4.7.0: warn/stderr + чистый захват -o ==="
# warn — диагностика: stdout пуст, [WARN] уходит в stderr
out="$(bash -c 'source "$1" 2>/dev/null; warn пред-текст' _ "$XKIT" 2>/dev/null)"
[ -z "$out" ]; ck "warn: stdout чистый (не попадает в \$(...))" $?
e="$(bash -c 'source "$1" 2>/dev/null; warn пред-текст' _ "$XKIT" 2>&1 1>/dev/null)"
case "$e" in *"[WARN] пред-текст"*) r=0;; *) r=1;; esac; ck "warn: [WARN] виден на stderr" $r
# КЛЮЧЕВАЯ РЕГРЕССИЯ: with_spinner -o вокруг функции, которая warn'ит и
# echo'ит значение (паттерн detect_panel_scheme). Оба пути спиннера.
run_scheme() { bash -c '
  source "$1" 2>/dev/null
  '"$1"'
  f() { warn "Панель не отвечает — предполагаю http"; echo "http"; }
  v="$(with_spinner -o "схема..." f)" || v=http
  printf "[%s]" "$v"
  ' _ "$XKIT" 2>/dev/null; }
[ "$(run_scheme '')" = "[http]" ]; ck "-o non-TTY: захват = ровно http (без [WARN])" $?
[ "$(run_scheme 'IS_TTY=1')" = "[http]" ]; ck "-o TTY-ветка: захват = ровно http (без [WARN])" $?
# TTY-ветка статикой: в capture-режиме stderr НЕ редиректится в tmplog
rg -qF 'if [ "$capture" = "1" ]; then' "$XKIT" && rg -qF '"$@" >"$tmplog" &' "$XKIT" \
  && rg -qF '"$@" >"$tmplog" 2>&1 &' "$XKIT"; ck "спиннер: -o без 2>&1, обычный режим — с 2>&1 (статика)" $?
# живой detect_panel_scheme на мёртвом порту: значение чистое, warn виден
v="$(bash -c 'source "$1" 2>/dev/null; PANEL_WBP="/WBP/login"; detect_panel_scheme 59999' _ "$XKIT" 2>/dev/null)"
[ "$v" = "http" ]; ck "detect_panel_scheme (мёртвый порт): ровно http" $?
e="$(bash -c 'source "$1" 2>/dev/null; PANEL_WBP="/WBP/login"; detect_panel_scheme 59999' _ "$XKIT" 2>&1 1>/dev/null)"
case "$e" in *"[WARN] Панель не отвечает"*) r=0;; *) r=1;; esac; ck "detect_panel_scheme: диагностика на stderr жива" $r
# xkit_log_begin: повторный вызов не затирает лог (фазы reinstall в одном файле)
bash -c '
source "$1" 2>/dev/null
XKIT_LOG="'"$T"'/log-reuse.txt"
xkit_log_begin uninstall; echo "удаление" >>"$XKIT_LOG"
xkit_log_begin install;  echo "установка" >>"$XKIT_LOG"
grep -q удаление "$XKIT_LOG" && grep -q установка "$XKIT_LOG" && echo KEPT
' _ "$XKIT" 2>/dev/null | grep -q KEPT; ck "log_begin: повторный вызов НЕ очищает файл" $?
rg -qF 'XKIT_LOG=""' "$XKIT" && rg -qF 'xkit_log_begin reinstall' "$XKIT"; ck "reinstall: лог строго xkit-reinstall-* (сброс перед begin)" $?
# uninstall --full: failed-статус x-ui сбрасывается
rg -qF 'systemctl reset-failed x-ui' "$XKIT"; ck "uninstall --full: reset-failed x-ui" $?
# мёртвый код убран
! rg -qF 'local a yes' "$XKIT"; ck "preflight_installed_menu: неиспользуемая yes убрана" $?

echo "=== 10. ПРАВКИ РЕВЬЮ №2: node_add EOF, sudo env, warn install.sh ==="
# --- node_add: EOF (Ctrl-D) на любом вводе = отмена, а не молчаливый дефолт
# харнесс: глушим root/env/session, read_host не читает stdin (в xkit он
# и так die'ит на EOF), nodes_load пуст; marker «Доступ:» — обычный echo,
# печатается ТОЛЬКО если функция прошла все read'ы хоста/порта/юзера
na_run() { IN="$1" bash -c '
  source "$1" 2>/dev/null
  require_root() { :; }
  load_xkit_env() { return 0; }
  kit_session() { return 0; }
  read_host() { printf "1.2.3.4"; return 0; }
  nodes_load() { echo "[]"; }
  XKIT_DIR="'"$T"'/na-etc"
  printf "%b" "$IN" | node_add 2>&1
  echo "RC=$?"
' _ "$XKIT" 2>/dev/null; }
o="$(na_run '')"
printf '%s' "$o" | grep -q 'RC=1' && ! printf '%s' "$o" | grep -q 'Доступ:'
ck "node_add: EOF на имени -> отмена, без продолжения" $?
o="$(na_run 'de1\n')"
printf '%s' "$o" | grep -q 'RC=1' && ! printf '%s' "$o" | grep -q 'Доступ:'
ck "node_add: EOF на SSH-порту -> отмена (раньше — дефолт 22 и коннект)" $?
o="$(na_run 'de1\n22\n')"
printf '%s' "$o" | grep -q 'RC=1' && ! printf '%s' "$o" | grep -q 'Доступ:'
ck "node_add: EOF на SSH-юзере -> отмена (раньше — дефолт root)" $?
o="$(na_run 'de1\n\n\n\n\n')"
printf '%s' "$o" | grep -q 'Пустой пароль' && printf '%s' "$o" | grep -q 'RC=1' \
  && ! printf '%s' "$o" | grep -qE '\[ERR \] ?(Порт|SSH-пользователь)'
ck "node_add: Enter-дефолты живы (22/root/1), пустой пароль ловится" $?
o="$(na_run 'de1\n\n\n2\n')"
printf '%s' "$o" | grep -q 'RC=1' && ! printf '%s' "$o" | grep -q 'Ключ не найден' \
  && ! printf '%s' "$o" | grep -q 'Проверяю SSH-доступ'
ck "node_add: EOF на пути ключа -> отмена, без попытки коннекта" $?
rg -qF 'read -r -p "SSH порт [22]: " nport || { echo; return 1; }' "$XKIT" \
  && rg -qF 'read -r -p "SSH пользователь [root]: " nuser || { echo; return 1; }' "$XKIT"
ck "node_add: || { echo; return 1; } на порту/юзере (статика)" $?

# --- install.sh: проброс env через sudo (sudo env НЕ наследует переменные)
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sudo" <<'EOS'
#!/bin/bash
# фейковый sudo: -n true -> успех; иначе лог аргументов + честный запуск
if [ "${1:-}" = "-n" ]; then shift; exec "$@"; fi
printf '%s\n' "$@" >> "${SUDO_LOG:?}"
exec "$@"
EOS
chmod +x "$FAKEBIN/sudo"
sudo_run() { # $1 = имя лога, остальное — аргументы install.sh
  SUDO_LOG="$T/$1"; : >"$SUDO_LOG"; shift
  PATH="$FAKEBIN:$PATH" SUDO_LOG="$SUDO_LOG" bash "$INST" "$@" >/dev/null 2>&1
  printf '%s' "$SUDO_LOG"
}
L="$(sudo_run sudo-yes.log -y install)"
grep -qF 'XKIT_YES=1' "$L" && grep -qF 'XKIT_FORCE=0' "$L" \
  && grep -qF 'XKIT_REPO_URL=' "$L" && grep -qF 'env' "$L"
ck "install.sh: -y от не-root доезжает до xkit через sudo env" $?
L="$(sudo_run sudo-plain.log install)"
grep -qF 'XKIT_YES=0' "$L" && grep -qF 'XKIT_FORCE=0' "$L"
ck "install.sh: без флагов — XKIT_YES=0/FORCE=0 (интерактивный режим сохранён)" $?
L="$(sudo_run sudo-force.log --force install)"
grep -qF 'XKIT_FORCE=1' "$L" && grep -qF 'XKIT_YES=0' "$L"
ck "install.sh: --force доезжает, -y не появляется" $?
# корневой путь (curl | sudo bash -s -- -y): env наследуется — экспорт на месте
rg -qF 'export XKIT_YES=1' "$INST" && rg -qF 'export XKIT_FORCE=1' "$INST"
ck "install.sh: root-путь — экспорт XKIT_YES/FORCE (наследование env)" $?
rg -qF 'sudo env XKIT_YES=' "$INST" \
  && rg -qF 'XKIT_REPO_URL="$XKIT_REPO_URL" bash "$WORK/xkit.sh"' "$INST"
ck "install.sh: sudo env пробрасывает YES/FORCE/NO_COLOR/NO_ANIM/REPO_URL" $?
# warn -> stderr (симметрия с xkit.sh)
rg -qF 'warn(){ echo -e "${C_Y}[!]${C_N} $*" >&2; }' "$INST"
ck "install.sh: warn пишет в stderr (симметрия с xkit.sh)" $?
rg -qF 'bash -s -- -y' "$INST"; ck "install.sh: шапка документирует bash -s -- -y для пайпа" $?

echo "=== 11. ЗАМЕЧАНИЯ С ЖИВОЙ УСТАНОВКИ: choose_host, certbot-авто, цикл серта, ник ==="
# --- choose_host: реальный IP как пункт 1, Enter = согласиться, 2 = вручную
ch_run() { STUB="${2:-}"; IN="$1" bash -c '
  source "$1" 2>/dev/null
  pubip() { printf "203.0.113.7"; }
  '"$STUB"'
  # ВАЖНО: не пайп (subshell съел бы CHOSEN_HOST), а process substitution
  choose_host "Адрес этого сервера" >/dev/null 2>&1 < <(printf "%b" "$IN")
  echo "HOST=[$CHOSEN_HOST]"
' _ "$XKIT" 2>/dev/null; }
[ "$(ch_run '1\n')" = "HOST=[203.0.113.7]" ]; ck "choose_host: пункт 1 -> определённый IP" $?
[ "$(ch_run '\n')" = "HOST=[203.0.113.7]" ]; ck "choose_host: Enter -> IP по умолчанию" $?
[ "$(ch_run '2\nvpn.example.com\n')" = "HOST=[vpn.example.com]" ]; ck "choose_host: пункт 2 -> домен вручную (read_host живой)" $?
[ "$(ch_run '9\n1\n')" = "HOST=[203.0.113.7]" ]; ck "choose_host: мусор -> переспрос, потом IP" $?
[ "$(ch_run 'vpn.example.com\n' 'pubip() { :; }')" = "HOST=[vpn.example.com]" ]; ck "choose_host: IP не определился -> ручной ввод как раньше" $?
rg -qF '1) IP этого сервера — $myip' "$XKIT" && rg -qF 'XKIT_HOST="$CHOSEN_HOST"' "$XKIT"
ck "choose_host: меню показывает реальный IP; один_step_install/hide берут CHOSEN_HOST" $?
[ "$(grep -cF 'XKIT_HOST="$CHOSEN_HOST"' "$XKIT")" -ge 2 ]; ck "choose_host: обе точки вызова переведены (install + hide_panel)" $?

# --- certbot: обновление в шаге 1/7, вопрос посреди установки убран
rg -qF 'python3-venv python3-pip' "$XKIT"; ck "пакеты: python3-venv/python3-pip ставятся сразу" $?
awk '/^one_step_install\(\)/{f=1} f && /if ! certbot_supports_ip; then/{p=1} f && /with_spinner "Обновление certbot/{s=1} f && /step "Домен\/IP/{exit} END{exit !(p&&s)}' "$XKIT"
ck "one_step_install: авто-обновление certbot ДО шага с адресом/сертом" $?
! rg -qF 'Обновить certbot автоматически через pip/venv' "$XKIT"; ck "интерактивный вопрос про certbot в issue_cert_le_ip УБРАН" $?
awk '/^issue_cert_le_ip\(\)/{f=1} f && /certbot_upgrade;/{p=1} f && /^}$/{exit} END{exit !p}' "$XKIT"
ck "issue_cert_le_ip: авто-попытка certbot_upgrade без вопросов" $?

# --- choose_certificate: провал серта НЕ убивает установку (цикл меню)
awk '/^choose_certificate\(\)/{f=1} f && /while :; do/{w=1} f && /try=\$\(\(try\+1\)\)/{t=1} f && /-gt 5/{m=1} f && /^}$/{exit} END{exit !(w&&t&&m)}' "$XKIT"
ck "choose_certificate: цикл меню с лимитом 5 попыток" $?
rg -qF 'Ввод прерван (EOF) — беру самоподписанный (пункт 4)' "$XKIT"
ck "choose_certificate: EOF -> пункт 4 (самоподписанный, CI не встаёт)" $?
rg -qF 'err "Не вышло — выберите другой вариант"; continue' "$XKIT"
ck "choose_certificate: провал выпуска -> меню снова (return 1 убран)" $?
# email только для 1/3: сам read с вопросом встречается ровно один раз (не считая changelog)
[ "$(grep -cF 'read -r -p "Email для Let' "$XKIT")" = "1" ]
ck "email спрашивается в одном месте (после выбора, только для LE)" $?

# --- install.sh: ник вписан сразу
rg -qF 'raw.githubusercontent.com/kalsifar/xkit/main' "$INST"
ck "install.sh: ник kalsifar вписан (one-line без правок)" $?
rg -qF 'kalsifar/xkit/main/xkit.sh' "$INST"; ck "install.sh: подсказка с ником в страховке" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "V49 ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $([ "$FAIL" = "0" ]; echo $?)
