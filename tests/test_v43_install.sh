#!/bin/bash
# Сценарные тесты install.sh v4.3
set -u
umask 022   # детерминизм: без этого 002 даёт group-write и V-02-гейт честно отсекает
PASS=0; FAIL=0
ck(){ if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"; else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
D="${SCRIPT_DIR%/tests}"
# каталоги тестов — НЕ в /tmp: install.sh (K-02/V-02) не доверяет файлам из /tmp
T="$(mktemp -d "$PWD/.t43inst.XXXXXX")"
trap 'rm -rf "$T" "$PWD"/.t43inst.* 2>/dev/null; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null' EXIT

# репозиторий-заглушка по HTTP
mkdir -p "$T/repo"
cp "$D/xkit.sh" "$D/xkit_menu.sh" "$D/xkit_protocols.sh" \
  "$D/xkit-tui-linux-amd64" "$D/xkit-tui-linux-arm64" "$T/repo/"
cp "$D/xkit.sh.sha256" "$T/repo/xkit.sh.sha256"
python3 -m http.server 18765 --directory "$T/repo" >/dev/null 2>&1 & SRV=$!
trap '[ -n "${SRV:-}" ] && kill $SRV 2>/dev/null; [ -n "${SRV2:-}" ] && kill $SRV2 2>/dev/null; true' EXIT
for _ in {1..150}; do curl -fsS -o /dev/null http://127.0.0.1:18765/xkit.sh && break; sleep 0.1; done

echo "=== T1: локальный xkit.sh рядом с install.sh ==="
mkdir -p "$T/t1"; cp "$D/install.sh" "$D/xkit.sh" "$D/xkit_menu.sh" \
  "$D/xkit_protocols.sh" "$D/xkit-tui-linux-amd64" "$D/xkit-tui-linux-arm64" "$T/t1/"
out="$(bash "$T/t1/install.sh" help </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "Использование"; ck "T1 локальные файлы -> help отработал" $?

echo "=== T2: скачивание по HTTP с sha256 (install.sh БЕЗ локального xkit.sh рядом) ==="
mkdir -p "$T/i2"; cp "$D/install.sh" "$T/i2/"
# депинированная копия: проверяем ПЛОМБУ из репо (в собранном install.sh pin главнее)
mkdir -p "$T/i3"; sed -E 's/^(XKIT_PIN_[A-Z0-9_]+)=.*/\1="@@\1@@"/' "$D/install.sh" > "$T/i3/install.sh"
out="$(XKIT_BASE=http://127.0.0.1:18765 bash "$T/i2/install.sh" help </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "SHA-256 проверен"; ck "T2 HTTP + sha256 ok" $?

echo "=== T3: битый sha256 -> отказ ==="
mkdir -p "$T/badrepo"; cp "$T/repo/"* "$T/badrepo/"
printf 'deadbeef  xkit.sh\n' > "$T/badrepo/xkit.sh.sha256"
python3 -m http.server 18766 --directory "$T/badrepo" >/dev/null 2>&1 & SRV2=$!
for _ in {1..150}; do curl -fsS -o /dev/null http://127.0.0.1:18766/xkit.sh && break; sleep 0.1; done
out="$(XKIT_BASE=http://127.0.0.1:18766 bash "$T/i3/install.sh" help </dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -q "НЕ совпал"; ck "T3 плохая сумма -> отказ" $?
kill $SRV2 2>/dev/null

echo "=== T4: прямой URL на xkit.sh первым аргументом ==="
out="$(bash "$D/install.sh" http://127.0.0.1:18765/xkit.sh help </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "Использование"; ck "T4 прямой URL" $?

echo "=== T5: curl|bash (stdin != tty) с аргументом help (из пустого каталога) ==="
mkdir -p "$T/i5"; cp "$D/install.sh" "$T/i5/"
out="$(cat "$T/i5/install.sh" | bash -s -- http://127.0.0.1:18765/xkit.sh help 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "Использование"; ck "T5 piped install" $?

echo "=== T6: стёртый ник (YOUR_USERNAME) без локального файла -> внятная ошибка ==="
# ник в install.sh уже вписан (kalsifar) — для проверки страховки делаем копию,
# где ник «испорчен» обратно в плейсхолдер
mkdir -p "$T/t6"
sed 's/kalsifar/YOUR_USERNAME/g' "$D/install.sh" > "$T/t6/install.sh"
out="$(bash "$T/t6/install.sh" </dev/null 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -q "не настроен"; ck "T6 стёртый ник -> ошибка (не 404-загадка)" $?
out="$(XKIT_BASE=http://127.0.0.1:18765 bash "$T/t6/install.sh" help </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ]; ck "T6b XKIT_BASE перекрывает стёртый ник" $?
out="$(bash "$D/install.sh" help </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ]; ck "T6c штатный install.sh (ник kalsifar) работает без XKIT_BASE" $?

echo "=== T7: временный каталог чистится (без exec) ==="
before="$(ls -1d /tmp/tmp.* 2>/dev/null | wc -l)"
mkdir -p "$T/i7"; cp "$D/install.sh" "$T/i7/"
bash "$T/i7/install.sh" http://127.0.0.1:18765/xkit.sh help </dev/null >/dev/null 2>&1
after="$(ls -1d /tmp/tmp.* 2>/dev/null | wc -l)"
[ "$after" -le "$before" ]; ck "WORKDIR не утекает ($before -> $after)" $?

echo ""
echo "install.sh: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
