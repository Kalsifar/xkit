#!/bin/bash
# Тесты nginx-xray-manager-v3 v3.2 (аудит №3):
#  1) версия/синтаксис/selftest
#  2) read -r везде; EOF-обработка всех 6 меню (Ctrl-D не валит set -u)
#  3) bash -c: безопасный паттерн в обеих пробах
#  4) node_add: валидация SSH-пользователя
#  5) install_self: cp/chmod с проверкой
#  6) backup_restore: tar-проверка на ../ и абсолютные пути
#  7) xray_test_config удалён; local_g -> watch_g; NOTE в install_3xui
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V3="${SCRIPT_DIR%/tests}/nginx-xray-manager-v3.sh"
[ -f "$V3" ] || V3="${BASE}/nginx-xray-manager-v3.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия, синтаксис, selftest ==="
rg -q 'XRAY MESH MANAGER  v3\.2' "$V3"; ck "заголовок v3.2" $?
rg -q 'XRAY MESH MANAGER v3\.2\.1 — мастер-узел' "$V3"; ck "баннер меню v3.2.1" $?
rg -q 'ИЗМЕНЕНИЯ v3\.2' "$V3"; ck "changelog v3.2" $?
bash -n "$V3" 2>/dev/null; ck "bash -n" $?
bash "$V3" --selftest >/dev/null 2>&1; ck "--selftest проходит" $?

echo "=== 2. read: -r везде, EOF в меню ==="
[ "$(grep -v '^#' "$V3" | grep -c 'read -p ')" = "0" ]; ck "нет read без -r (в коде)" $?
[ "$(grep -cF 'read -r -p "Выбор: " c || { echo; return 0; }' "$V3")" = "6" ]; ck "6 меню с EOF-обработкой" $?
# поведенчески: Ctrl-D в подменю — чистый выход, без unbound variable
out="$(bash -c 'set -u; source "$1" 2>/dev/null; menu_nodes </dev/null >/dev/null 2>&1 && echo MENU_EOF_OK' _ "$V3" 2>&1)"
[ "$out" = "MENU_EOF_OK" ]; ck "menu_nodes при EOF: rc=0, set -u не падает" $?
out="$(bash -c 'set -u; source "$1" 2>/dev/null; main_menu </dev/null >/dev/null 2>&1 && echo MAIN_EOF_OK' _ "$V3" 2>&1)"
[ "$out" = "MAIN_EOF_OK" ]; ck "main_menu при EOF: чистый выход" $?

echo "=== 3. bash -c пробы ==="
[ "$(grep -c 'bash -c "exec 3<>/dev/tcp' "$V3")" = "0" ]; ck "нет интерполяции в dev/tcp" $?
[ "$(grep -c "bash -c 'exec 3<>/dev/tcp/" "$V3")" = "2" ]; ck "обе пробы безопасны" $?

echo "=== 4. node_add: SSH-пользователь ==="
rg -qF '[[ "$sshuser" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]]' "$V3"; ck "sshuser-regex на месте" $?
rg -qF 'только латиница/цифры/._-' "$V3"; ck "понятное сообщение об ошибке" $?

echo "=== 5. install_self ==="
rg -qF 'if cp -f "$SELF_PATH" /usr/local/bin/xray-mesh && chmod 700 /usr/local/bin/xray-mesh; then' "$V3"; ck "cp/chmod с проверкой" $?
rg -qF 'Не удалось установить в /usr/local/bin/xray-mesh' "$V3"; ck "ошибка при неудаче" $?

echo "=== 6. backup_restore: tar-проверка ==="
rg -qF "tar -tzf \"\$f\" 2>/dev/null | grep -qE '(^/|(^|/)\\.\\.(/|\$))'" "$V3"; ck "проверка ../ и абсолютных путей" $?
rg -qF 'восстановление отменено' "$V3"; ck "отказ при небезопасном архиве" $?

echo "=== 7. Чистка и комментарии ==="
[ "$(grep -v '^#' "$V3" | grep -c 'xray_test_config')" = "0" ]; ck "мёртвая xray_test_config удалена (в коде)" $?
[ "$(grep -v '^#' "$V3" | grep -c 'local_g')" = "0" ]; ck "local_g переименован (в коде)" $?
rg -q 'watch_gj' "$V3"; ck "watch_g/watch_gj в демоне" $?
rg -qF 'XUI_NONINTERACTIVE=1 здесь НЕ ставим' "$V3"; ck "NOTE про XUI_NONINTERACTIVE" $?

echo "=== 8. Ревью v3.2: EOF в node_add, tar-флаги ==="
# 4 ввода с дефолтом (SSH-порт, SSH-пользователь, Reality-порт, SNI) — при
# Ctrl-D отмена, а не молчаливое продолжение с дефолтом
n="$(awk '/^node_add\(\)/,/^}$/' "$V3" | grep -c 'read -r -p .* || { echo; return 1; }')"
[ "$n" = "4" ]; ck "node_add: 4 read с EOF-отменой (не молчаливый дефолт)" $?
# №15 (аудит №1): распаковка в staging + отказ от symlink наружу + перенос
rg -qF 'tar xzf "$f" -C "$rst" --no-same-owner' "$V3"; ck "backup_restore: распаковка в staging (не /) без владельцев" $?
rg -qF 'Архив содержит symlink наружу' "$V3"; ck "backup_restore: symlink наружу — отказ (№15)" $?
rg -qF 'cp -a "$rst"/. /' "$V3"; ck "backup_restore: перенос из staging" $?
# поведенчески: EOF сразу после имени/IP — отмена (rc=1), файл ноды не создан
mkdir -p "$T/g" "$T/n"; echo '{}' > "$T/g/g1.json"
rc="$(printf 'node1\n1.2.3.4\n' | bash -c '
  set -u
  source "$1" 2>/dev/null
  XMESH_GROUPS_DIR="$2/g"; XMESH_NODES_DIR="$2/n"
  node_add g1 >/dev/null 2>&1; echo $?' _ "$V3" "$T" 2>/dev/null)"
[ "$rc" = "1" ] && [ ! -f "$T/n/node1.json" ]; ck "node_add: EOF на SSH-порту — отмена, нода не создана" $?

echo "=== 10. Аудит v5.2.1 (v3): парность серта/ключа ==="
rg -q 'не читается как сертификат' "$V3"; ck "install_cert_files: пустой вывод openssl не считается парой" $?
rg -q 'fullchain.pem и privkey.pem не парные' "$V3"; ck "install_cert_files: проверка парности ключа присутствует" $?
rg -q 'pkey -pubout' "$V3"; ck "install_cert_files: pubkey сравнивается с privkey" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "V32 ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $([ "$FAIL" = "0" ]; echo $?)
