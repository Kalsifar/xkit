#!/bin/bash
# Тесты XKIT v4.4.2 (хвост аудита №4): dash_sanitize_inbounds — clients для
# ВСЕХ форматов + всегда валидный JSON на выходе:
#  1) raw API (клиенты внутри settings-строки)   -> счётчик верный
#  2) settings-объект (не строка)                -> счётчик верный
#  3) .clients-массив (полу-sanitized)           -> длина массива
#  4) .clients-число (sanitized v4.4+)           -> без изменений
#  5) .clients null / битый settings / пусто     -> 0, без падений
#  6) идемпотентность sanitized -> sanitized (барьер перед записью)
#  7) comment-предохранитель у umask 027 в dash_gen_locked
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?

echo "=== 2. Поведение dash_sanitize_inbounds (реальные вызовы) ==="
# изолированный env, чтобы не задеть реальную систему
export XKIT_DIR="$T/env" XKIT_ENV="$T/env/xkit.env" XKIT_NODES="$T/env/nodes.json" \
       XKIT_EXPIRY="$T/env/expiry.tsv" XKIT_INFO_FILE="$T/env/info.txt" \
       XKIT_DASH_DIR="$T/env/dash"
mkdir -p "$T/env/dash"

run_san() { # JSON на stdin -> stdout sanitized
  bash -c 'source "'"$XKIT"'" 2>/dev/null; dash_sanitize_inbounds "$(cat)"' 2>/dev/null
}

RAW='[{"tag":"a","port":443,"protocol":"vless","settings":"{\"clients\":[{\"email\":\"x\"},{\"email\":\"y\"}]}","streamSettings":"{\"network\":\"tcp\"}","enable":true,"up":100,"down":200}]'
out="$(run_san <<<"$RAW")"
jq -e '.[0].clients==2 and .[0].total==300 and .[0].proto=="vless"' <<<"$out" >/dev/null 2>&1
ck "raw API: settings-строка -> clients=2, total=up+down" $?

SOBJ='[{"tag":"e","port":700,"protocol":"vless","settings":{"clients":[{"email":"q"},{"email":"w"},{"email":"r"}]}}]'
out="$(run_san <<<"$SOBJ")"
jq -e '.[0].clients==3' <<<"$out" >/dev/null 2>&1
ck "settings-объект -> clients=3" $?

ARR='[{"tag":"d","port":99,"proto":"vless","clients":[{"email":"z"},{"email":"v"}],"up":1,"down":2}]'
out="$(run_san <<<"$ARR")"
jq -e '.[0].clients==2 and .[0].total==3' <<<"$out" >/dev/null 2>&1
ck "clients-массив (полу-sanitized) -> clients=2 (раньше молча 0)" $?

NUM='[{"tag":"c","port":80,"proto":"vmess","clients":5,"enable":false}]'
out="$(run_san <<<"$NUM")"
jq -e '.[0].clients==5 and .[0].enable==false' <<<"$out" >/dev/null 2>&1
ck "clients-число + enable:false -> без изменений (// true съедал false)" $?

DISABLED_USERS='[{"tag":"g","port":443,"protocol":"vless","settings":"{\"clients\":[{\"email\":\"on\",\"enable\":true},{\"email\":\"off\",\"enable\":false}]}","clientStats":"[{\"email\":\"on\",\"up\":10,\"down\":5},{\"email\":\"off\",\"up\":0,\"down\":0}]"}]'
out="$(bash -c 'source "'"$XKIT"'" 2>/dev/null; dash_sanitize_users "$(cat)"' <<<"$DISABLED_USERS" 2>/dev/null)"
jq -e '[.[] | select(.email=="off")][0].enable==false and [.[] | select(.email=="on")][0].enable==true' <<<"$out" >/dev/null 2>&1
ck "dash_sanitize_users: enable:false пользователя сохраняется" $?

out="$(bash -c 'source "'"$XKIT"'" 2>/dev/null; dash_users_whitelist "$(cat)"' <<<'[{"email":"off","ib":"g","up":0,"down":0,"total":0,"enable":false,"expiryTime":0}]' 2>/dev/null)"
jq -e '.[0].enable==false' <<<"$out" >/dev/null 2>&1
ck "dash_users_whitelist: enable:false сохраняется" $?

NULLC='[{"tag":"b","port":8443,"proto":"vless","clients":null,"up":1,"down":2}]'
out="$(run_san <<<"$NULLC")"
jq -e '.[0].clients==0 and .[0].total==3' <<<"$out" >/dev/null 2>&1
ck "clients:null -> 0 (не падаем)" $?

JUNK='[{"tag":"f","port":701,"protocol":"vless","settings":"не-json"}]'
out="$(run_san <<<"$JUNK")"
jq -e '.[0].clients==0' <<<"$out" >/dev/null 2>&1
ck "битый settings (не JSON) -> clients=0" $?

out="$(run_san <<<"$RAW")"; out2="$(run_san <<<"$out")"
[ "$out" = "$out2" ]
ck "идемпотентность sanitized -> sanitized" $?

for t in '' 'null' '{}' 'не-json' '[]' '   '; do
  out="$(run_san <<<"$t")"
  jq -e 'type=="array"' <<<"$out" >/dev/null 2>&1
  ck "краевой вход «${t:-пусто}» -> валидный JSON-массив" $?
done

out="$(printf '%s' "$RAW" | run_san)"
printf '%s' "$out" | rg -q 'privateKey|"id"|subId'; [ $? -ne 0 ]
ck "утечка privateKey/UUID/subId исключена" $?

echo "=== 3. Предохранитель umask (статика) ==="
rg -q 'НЕ выносить umask в dash_gen вне subshell' "$XKIT"
ck "комментарий-предохранитель у umask 027" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "V442 ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $([ "$FAIL" = "0" ]; echo $?)
