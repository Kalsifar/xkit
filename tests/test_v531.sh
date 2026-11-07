#!/bin/bash
# XKIT v5.3.1: модуляризация ядра (§8.3 CHANGES.md) — src/ → xkit.sh.
# Приёмочный тест маршрута src/+build: сборка из src/ обязана давать
# байт-в-байт текущий xkit.sh; пин-книга и пломба обязаны сходиться.
set -u
PASS=0; FAIL=0
ck(){ if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  [OK]   $1"; else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; BASE="${SCRIPT_DIR%/tests}"

echo '=== 1. Сборка ядра из src/ (§8.3) ==='
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat "$BASE"/src/[0-9][0-9]_*.sh > "$T/xkit.sh" 2>/dev/null
cmp -s "$T/xkit.sh" "$BASE/xkit.sh"; ck 'сборка из src/ байт-в-байт равна xkit.sh' $?
# идемпотентность: повторная сборка даёт тот же файл
cat "$BASE"/src/[0-9][0-9]_*.sh > "$T/xkit2.sh" 2>/dev/null
cmp -s "$T/xkit.sh" "$T/xkit2.sh"; ck 'сборка воспроизводима (дважды — один результат)' $?
# шебанг — строка 1 собранного файла
[ "$(head -1 "$BASE/xkit.sh")" = "#!/bin/bash" ]; ck 'шебанг — первая строка сборки' $?

echo '=== 2. Целостность модулей ==='
n=0; badn=0
for m in "$BASE"/src/[0-9][0-9]_*.sh; do
  if bash -n "$m" 2>/dev/null; then n=$((n+1)); else badn=$((badn+1)); echo "  невалиден: $(basename "$m")"; fi
done
[ "$badn" -eq 0 ]; ck "bash -n: все $n модулей src/ валидны" $?
tot_x="$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) ?\{' "$BASE/xkit.sh")"
tot_s="$(cat "$BASE"/src/[0-9][0-9]_*.sh | grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) ?\{')"
[ "$tot_x" = "$tot_s" ] && [ "$tot_x" -gt 200 ]; ck "функции не потеряны: xkit.sh=$tot_x == src=$tot_s" $?
# в сборке нет маркеров склейки и пустых модулей
[ "$(find "$BASE/src" -name '[0-9][0-9]_*.sh' -size -10c | wc -l)" = 0 ]; ck 'пустых модулей нет' $?
grep -q 'XKIT_VERSION="5\.' "$BASE/src/01_header.sh"; ck 'версия живёт в src/01_header.sh' $?

echo '=== 3. Согласованность версий ==='
v_x="$(grep -m1 '^XKIT_VERSION=' "$BASE/xkit.sh" | cut -d'"' -f2)"
v_s="$(grep -m1 '^XKIT_VERSION=' "$BASE/src/01_header.sh" | cut -d'"' -f2)"
v_g="$(grep -m1 'const version' "$BASE/tui/main.go" | sed 's/.*"\(.*\)".*/\1/')"
v_m="$(grep -m1 'КЛАССИЧЕСКОЕ МЕНЮ' "$BASE/xkit_menu.sh" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
v_p="$(head -2 "$BASE/xkit_protocols.sh" | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[ "$v_x" = "5.3.1" ] && [ "$v_s" = "5.3.1" ] && [ "$v_g" = "5.3.1" ] \
  && [ "$v_m" = "5.3.1" ] && [ "$v_p" = "5.3.1" ]
ck "версии 5.3.1 согласованы: xkit=$v_x src=$v_s tui=$v_g menu=$v_m proto=$v_p" $?

echo '=== 4. K-02: пин-книга и пломба ==='
for pair in "xkit.sh:XKIT_PIN_SHA256" "xkit_menu.sh:XKIT_PIN_MENU_SHA256" \
            "xkit_protocols.sh:XKIT_PIN_PROTOCOLS_SHA256" \
            "xkit-tui-linux-amd64:XKIT_PIN_TUI_AMD64_SHA256" \
            "xkit-tui-linux-arm64:XKIT_PIN_TUI_ARM64_SHA256"; do
  f="${pair%%:*}"; var="${pair##*:}"
  pin="$(grep -m1 "^$var=" "$BASE/install.sh" | cut -d'"' -f2)"
  got="$(sha256sum "$BASE/$f" | awk '{print $1}')"
  [ "$pin" = "$got" ]; ck "pin $var == sha256($f)" $?
done
sha256sum -c "$BASE/xkit.sh.sha256" >/dev/null 2>&1; ck 'xkit.sh.sha256 подтверждает все компоненты' $?
# TUI-бинарник содержит актуальную версию
strings "$BASE/xkit-tui-linux-amd64" | grep -q '5\.3\.1'; ck 'TUI-бинарник собран из const version 5.3.1' $?

echo '=== 5. Права артефактов (V-02/install_trust) ==='
bad_mode=0
for f in xkit.sh xkit.sh.sha256 xkit-tui-linux-amd64 xkit-tui-linux-arm64; do
  st="$(stat -Lc '%a' "$BASE/$f" 2>/dev/null)"
  [ $(( 8#${st:-777} & 8#022 )) -eq 0 ] || { bad_mode=1; echo "  group/other-writable: $f ($st)"; }
done
[ "$bad_mode" -eq 0 ]; ck 'артефакты не group/other-writable (права нормализует build.sh)' $?

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
