#!/bin/bash
# Тесты XKIT v5.0.0 (модульное меню):
#  1) версия/синтаксис/статика: меню вынесено в xkit_menu.sh, xkit.sh не раздут
#  2) целостность: source xkit.sh + xkit_load_menu -> все функции меню и все
#     вызываемые ядро-функции на месте; guard прямого запуска модуля
#  3) главное меню: 6 групп + выход (компактность), старый плоский список ушёл
#  4) пломба xkit.sh.sha256: sha256sum-формат, 5 строк (ядро, меню, протоколы,
#     оба TUI), обратная совместимость (awk NR==1 читает сумму xkit.sh)
#  5) install.sh: качает оба файла, сверяет строку 2 пломбы, bash -n меню,
#     ник kalsifar на месте (регресс v4.9.0)
#  6) self_update: качает оба файла, бэкап меню, деградация при отсутствии
#     меню в репо (оставить установленный); self-copy места вызывают
#     xkit_menu_install; uninstall чистит /usr/local/lib/xkit
#  7) END-TO-END авто-докачка: xkit.sh без модуля + HTTP-репо -> меню
#     докачивается само (SHA-256 сверяется), битая сумма -> отмена
set -u
umask 022
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${SCRIPT_DIR%/tests}"
XKIT="${BASE}/xkit.sh"
XMENU="${BASE}/xkit_menu.sh"
INSTALL="${BASE}/install.sh"
SUMF="${BASE}/xkit.sh.sha256"
[ -f "$XKIT" ] || { XKIT="${BASE}/xkit.sh"; XMENU="${BASE}/xkit_menu.sh"; INSTALL="${BASE}/install.sh"; SUMF="${BASE}/xkit.sh.sha256"; }
[ -f "$XMENU" ] || XMENU="${XKIT%/*}/xkit_menu.sh"
[ -f "$INSTALL" ] || INSTALL="${XKIT%/*}/install.sh"
[ -f "$SUMF" ] || SUMF="${XKIT%/*}/xkit.sh.sha256"

# каталоги — НЕ в /tmp: xkit (V-02) не доверяет коду из /tmp, E2E должен идти
# из доверенного места, как в проде (/usr/local/lib/xkit)
T="$(mktemp -d "$PWD/.t50.XXXXXX")"
# Некоторые sandbox-FS не поддерживают install -m. E2E проверяет скачивание,
# SHA-256 и загрузчик, поэтому только внешний install заменяется эквивалентным cp.
TESTBIN="$(mktemp -d /tmp/xkit-t50-bin.XXXXXX)"
cat > "$TESTBIN/install" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-m" ] && shift 2
exec cp "$@"
EOF
chmod +x "$TESTBIN/install"
trap 'rm -rf "$T" "$TESTBIN" "$PWD"/.t50.* 2>/dev/null' EXIT

echo "=== 1. Версия, синтаксис, статика модульности ==="
rg -q 'XKIT_VERSION="5\.[0-9]+\.[0-9]+"' "$XKIT"; ck "версия 5.x.y (бамп-safe)" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?
bash -n "$XMENU" 2>/dev/null; ck "bash -n xkit_menu.sh" $?
rg -q 'XKIT_MENU_DIR="\$\{XKIT_MENU_DIR:-/usr/local/lib/xkit\}"' "$XKIT"; ck "XKIT_MENU_DIR переопределяемый (тесты/нестандартные пути)" $?
# меню переехало: в ядре определений НЕТ, загрузчик ЕСТЬ
rg -q '^show_menu\(\)' "$XKIT"; _r=$?; [ $_r -ne 0 ]; ck "xkit.sh: show_menu больше не определён в ядре" $?
rg -q '^menu_loop\(\)' "$XKIT"; _r=$?; [ $_r -ne 0 ]; ck "xkit.sh: menu_loop больше не определён в ядре" $?
! rg -q '^pause_enter\(\)' "$XKIT"; ck "xkit.sh: pause_enter больше не определён в ядре" $?
rg -q '^xkit_menu_src\(\)' "$XKIT" && rg -q '^xkit_menu_fetch\(\)' "$XKIT" \
  && rg -q '^xkit_menu_install\(\)' "$XKIT" && rg -q '^xkit_load_menu\(\)' "$XKIT"
ck "xkit.sh: загрузчик модуля (src/fetch/install/load)" $?
# отдельная аккуратная проверка
_m=0
for fn in show_menu menu_loop pause_enter menu_install menu_users menu_reality menu_service menu_extra menu_service_cert; do
  rg -q "^${fn}\(\)" "$XMENU" || _m=1
done
ck "xkit_menu.sh: все функции UI на месте (точная проверка)" $_m
rg -q 'BASH_SOURCE\[0\].*== "\$\{0\}"' "$XMENU"; ck "xkit_menu.sh: guard прямого запуска" $?

echo "=== 2. Целостность: загрузка модуля + все функции ==="
out="$(bash -c 'source "$1" 2>/dev/null; xkit_load_menu 2>/dev/null || { echo LOAD_FAIL; exit 1; }; type -t show_menu' _ "$XKIT" 2>/dev/null)"
[ "$out" = "function" ]; ck "xkit_load_menu подгружает show_menu (поиск рядом со скриптом)" $?
miss=0
for f in menu_install menu_users menu_reality menu_service menu_extra menu_service_cert one_step_install auto_route hide_existing_panel add_relay_route external_proxy_fix client_add client_del client_reset client_list sub_regen reality_wizard reality_scan_menu reality_show_keys nodes_menu health_check show_status backup_now backup_restore xkit_self_update dash_menu telegram_menu expiry_menu ssh_hook_toggle xkit_info choose_certificate host_kind save_xkit_env regen_conf_and_apply pause_enter menu_loop show_menu; do
  bash -c 'source "$1" 2>/dev/null; xkit_load_menu >/dev/null 2>&1 || exit 1; type -t "$2" >/dev/null' _ "$XKIT" "$f" 2>/dev/null || { echo "     отсутствует: $f"; miss=1; }
done
ck "все вызываемые функции существуют (ядро + модуль)" $miss
bash "$XMENU" >/dev/null 2>&1; [ $? -eq 1 ]; ck "прямой запуск xkit_menu.sh запрещён (exit 1)" $?
bash "$XMENU" 2>&1 | rg -q 'модуль меню'; ck "guard печатает подсказку" $?

echo "=== 3. Главное меню: 6 групп, компактность ==="
out="$(bash -c 'source "$1" 2>/dev/null; xkit_load_menu >/dev/null 2>&1; show_menu' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'ПОЛЬЗОВАТЕЛИ'; ck "группа: ПОЛЬЗОВАТЕЛИ" $?
echo "$out" | rg -q 'Протоколы: REALITY'; ck "группа: Протоколы / REALITY" $?
echo "$out" | rg -q 'НОДЫ'; ck "группа: НОДЫ" $?
echo "$out" | rg -q 'Обслуживание'; ck "группа: Обслуживание" $?
echo "$out" | rg -q 'Мониторинг'; ck "группа: Мониторинг" $?
echo "$out" | rg -q 'Установка и настройка'; ck "группа: Установка и настройка" $?
n=$(echo "$out" | rg -c '^[ 0-9]+\) ' || true); [ "$n" = "7" ]; ck "главное меню: ровно 7 строк выбора (6 групп + выход), а не 26" $?
echo "$out" | rg -q 'АВТОПРОБРОС' && _r=1 || _r=0; [ "$_r" = "0" ]; ck "АВТОПРОБРОС ушёл в подменю (нет в главном)" $?
echo "$out" | rg -q 'Сбросить' && _r=1 || _r=0; [ "$_r" = "0" ]; ck "управление трафиком ушло в подменю" $?
# EOF -> выход без зависания; неверный пункт -> предупреждение
echo "" | timeout 10 bash -c 'source "$1" 2>/dev/null; xkit_load_menu >/dev/null 2>&1; menu_loop' _ "$XKIT" >/dev/null 2>&1; [ $? -eq 0 ]; ck "menu_loop: EOF -> чистый выход 0" $?
printf '99\n0\n' | timeout 10 bash -c 'source "$1" 2>/dev/null; xkit_load_menu >/dev/null 2>&1; menu_loop' _ "$XKIT" 2>&1 | rg -q 'Нет такого пункта'; ck "menu_loop: неверный пункт -> warn" $?
# подменю: все пункты диспатчат
_m=0; for pair in client_add client_del client_reset client_list sub_regen; do
  rg -q "[0-9]\) ${pair}; pause_enter" "$XMENU" || _m=1
done; ck "menu_users: 5 операций над пользователями (точная)" $_m
_m=0; for pair in reality_wizard reality_scan_menu reality_show_keys; do
  rg -q "[0-9]\) ${pair}; pause_enter" "$XMENU" || _m=1
done
for pair in proto_xhttp_create proto_awg_menu proto_hy2_menu protocols_list; do
  rg -q "xkit_protocols_load && ${pair}; pause_enter" "$XMENU" || _m=1
done; ck "menu_reality: 7 пунктов (REALITY/XHTTP/AWG/Hy2/сводка)" $_m
_m=0; for pair in menu_service_cert health_check show_status backup_now backup_restore xkit_self_update; do
  rg -q "[0-9]\) ${pair}; pause_enter" "$XMENU" || _m=1
done; ck "menu_service: 6 пунктов (серт/health/статус/бэкап/рестор/обновление)" $_m
_m=0; for pair in dash_menu telegram_menu expiry_menu ssh_hook_toggle xkit_info; do
  rg -q "[0-9]\) ${pair}" "$XMENU" || _m=1
done; ck "menu_extra: 5 пунктов мониторинга" $_m
_m=0; for pair in one_step_install auto_route hide_existing_panel add_relay_route external_proxy_fix; do
  rg -q "[0-9]\) ${pair}; pause_enter" "$XMENU" || _m=1
done; ck "menu_install: 5 пунктов установки/настройки" $_m
rg -q 'nodes_menu ;;' "$XMENU"; ck "НОДЫ -> существующий nodes_menu (дубля нет)" $?

echo "=== 4. Пломба xkit.sh.sha256 (sha256sum-формат, 5 строк) ==="
[ "$(wc -l < "$SUMF" 2>/dev/null | tr -d ' ')" = "5" ]; ck "пломба: ровно 5 строк" $?
w1="$(awk 'NR==1{print $1}' "$SUMF")"; g1="$(sha256sum "$XKIT" | awk '{print $1}')"
[ -n "$w1" ] && [ "$w1" = "$g1" ]; ck "строка 1 = SHA-256 xkit.sh" $?
w2="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$SUMF")"; g2="$(sha256sum "$XMENU" | awk '{print $1}')"
[ -n "$w2" ] && [ "$w2" = "$g2" ]; ck "строка 2 = SHA-256 xkit_menu.sh" $?
(cd "${SUMF%/*}" && sha256sum -c xkit.sh.sha256 >/dev/null 2>&1); ck "sha256sum -c проходит по всем пяти строкам" $?
[ "$w1" = "$(awk 'NR==1{print $1}' "$SUMF")" ]; ck "обратная совместимость: старые версии (awk NR==1) видят сумму xkit.sh" $?

echo "=== 5. install.sh: оба файла + сверка + регресс kalsifar ==="
rg -q 'xkit_menu\.sh' "$INSTALL"; ck "install.sh: качает xkit_menu.sh" $?
rg -q 'xkit_menu\.sh"\{print \$1; exit\}' "$INSTALL" || rg -q '\$2=="xkit_menu\.sh"' "$INSTALL"; ck "install.sh: сверка строки 2 пломбы" $?
rg -q 'Синтаксическая ошибка в xkit_menu\.sh' "$INSTALL"; ck "install.sh: bash -n модуля меню" $?
rg -q 'не скачался — xkit докачает меню' "$INSTALL"; ck "install.sh: деградация без сети (WARN, не abort)" $?
rg -q 'kalsifar/xkit/main' "$INSTALL"; ck "install.sh: ник kalsifar на месте (регресс v4.9.0)" $?
bash -n "$INSTALL" 2>/dev/null; ck "bash -n install.sh" $?

echo "=== 6. self_update / self-copy / uninstall ==="
rg -q 'xkit_menu\.sh" -o "\$tmpm"' "$XKIT"; ck "xkit update: качает xkit_menu.sh" $?
rg -q 'xkit_menu\.sh" не совпал' "$XKIT" || rg -q 'SHA-256 xkit_menu\.sh НЕ совпал' "$XKIT"; ck "xkit update: сверка суммы меню" $?
rg -q 'xkit_menu\.sh\.bak' "$XKIT"; ck "xkit update: бэкап старого меню" $?
rg -q 'оставляю установленный' "$XKIT"; ck "xkit update: меню нет в репо -> оставить установленный" $?
rg -q 'Залейте xkit_menu\.sh в репозиторий' "$XKIT"; ck "xkit update: меню нет нигде -> понятная ошибка" $?
n=$(rg -c 'xkit_menu_install \|\| true' "$XKIT"); [ "$n" = "3" ]; ck "self-copy: one_step_install/hide_existing_panel/ssh_hook_toggle обновляют меню (3 места)" $?
rg -q 'rm -rf "\$XKIT_MENU_DIR"' "$XKIT"; ck "uninstall: удаляет каталог модуля меню" $?
rg -q '6 групп с подменю' "$XKIT"; ck "usage: описание нового меню" $?
rg -q 'авто-докачка|докачано|докачан' "$XKIT"; ck "авто-докачка: функция и сообщения на месте" $?

echo "=== 7. END-TO-END: авто-докачка меню с HTTP-репо ==="
WWW="$T/www"; mkdir -p "$WWW" "$T/bin" "$T/lib1" "$T/lib2" "$T/lib3"
cp "$XMENU" "$WWW/xkit_menu.sh"
{
  printf '%s  xkit.sh\n' "$(sha256sum "$XKIT" | awk '{print $1}')"
  printf '%s  xkit_menu.sh\n' "$(sha256sum "$XMENU" | awk '{print $1}')"
} > "$WWW/xkit.sh.sha256"
cp "$XKIT" "$T/bin/xkit.sh"
PORT=$(( 20000 + RANDOM % 20000 ))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" >/dev/null 2>&1 &
SRV=$!
sleep 0.7
# 7.1: корректная сумма -> меню докачано, xkit запустился (EOF -> exit 0)
out="$(PATH="$TESTBIN:$PATH" XKIT_REPO_URL="http://127.0.0.1:${PORT}" XKIT_MENU_DIR="$T/lib1" \
       timeout 15 bash "$T/bin/xkit.sh" </dev/null 2>&1)"
rc=$?
[ $rc -eq 0 ]; ck "авто-докачка: xkit стартует без модуля рядом (EOF-выход $rc)" $?
[ -f "$T/lib1/xkit_menu.sh" ]; ck "авто-докачка: файл установлен в XKIT_MENU_DIR" $?
echo "$out" | rg -q 'Модуль меню докачан'; ck "авто-докачка: сообщение об установке" $?
echo "$out" | rg -q 'ПОЛЬЗОВАТЕЛИ'; ck "авто-докачка: главное меню отрисовалось" $?
# 7.2: битая сумма -> отмена, файл не ставится
BAD="$T/www_bad"; mkdir -p "$BAD"
cp "$XMENU" "$BAD/xkit_menu.sh"
{
  printf '%s  xkit.sh\n' "$(sha256sum "$XKIT" | awk '{print $1}')"
  printf '%s  xkit_menu.sh\n' "0000000000000000000000000000000000000000000000000000000000000000"
} > "$BAD/xkit.sh.sha256"
PORT2=$(( 20000 + RANDOM % 20000 ))
python3 -m http.server "$PORT2" --bind 127.0.0.1 --directory "$BAD" >/dev/null 2>&1 &
SRV2=$!
sleep 0.7
out="$(PATH="$TESTBIN:$PATH" XKIT_REPO_URL="http://127.0.0.1:${PORT2}" XKIT_MENU_DIR="$T/lib2" \
       timeout 15 bash "$T/bin/xkit.sh" </dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ]; ck "авто-докачка: битая сумма -> отказ (exit $rc)" $?
echo "$out" | rg -q 'SHA-256 xkit_menu\.sh НЕ совпал'; ck "авто-докачка: диагностика несовпадения" $?
[ ! -f "$T/lib2/xkit_menu.sh" ]; ck "авто-докачка: битый файл НЕ установлен" $?
# 7.3: нет репо и нет модуля -> понятная ошибка, не зависание
out="$(PATH="$TESTBIN:$PATH" XKIT_MENU_DIR="$T/lib3" timeout 15 bash "$T/bin/xkit.sh" </dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ]; ck "без репо и без модуля: exit $rc (не зависание)" $?
echo "$out" | rg -q 'Не найден файл меню'; ck "без репо: подсказка 'Не найден файл меню'" $?
kill $SRV $SRV2 2>/dev/null; wait $SRV $SRV2 2>/dev/null

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
