#!/bin/bash
# Тесты XKIT v4.4: аудит №3 дашборда/expiry + Basic Auth + сводка/реквизиты
set -u
PASS=0; FAIL=0
ck() { # ck "имя" 0/1
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия и базовые проверки ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?

echo "=== 2. is_cidr (allow-списки nginx) ==="
source "$XKIT" || { echo "source xkit.sh failed"; exit 1; }

# оверрайды ПОСЛЕ source (иначе константы их перезапишут);
# нужны ДО вызовов функций, которые делают load_xkit_env || die
export XKIT_DIR="$T/env" XKIT_ENV="$T/env/xkit.env" XKIT_NODES="$T/env/nodes.json" \
       XKIT_EXPIRY="$T/env/expiry.tsv" XKIT_INFO_FILE="$T/info.txt"
mkdir -p "$T/env"
printf 'XKIT_VERSION="4.4"\nXKIT_HOST="t.example.com"\nXKIT_DASH="1"\nXKIT_DASH_TOKEN="tk44"\n' > "$XKIT_ENV"
is_cidr "10.0.0.0/8";       ck "10.0.0.0/8 валиден" $?
is_cidr "203.0.113.9/32";   ck "/32 валиден" $?
is_cidr "2001:db8::/32";    ck "IPv6 CIDR валиден" $?
! is_cidr "1.2.3.4/33";     ck "/33 невалиден" $?
! is_cidr "1.2.3.4";        ck "без слэша невалиден" $?
! is_cidr "1.2.3.4/abc";    ck "маска не число — невалидна" $?
! is_cidr "999.0.0.0/8";    ck "кривой IP — невалиден" $?
! is_cidr "10.0.0.0/-1";    ck "отрицательная маска — невалидна" $?

echo "=== 3. human_bytes: одна функция, английские суффиксы ==="
[ "$(rg -c 'human_bytes\(\)' "$XKIT")" = "1" ]; ck "ровно одно определение human_bytes" $?
[ "$(human_bytes 2048)" = "2.0 KiB" ]; ck "2 KiB (англ.)" $?
[ "$(human_bytes 0)" = "0 B" ]; ck "0 B (англ.)" $?

echo "=== 4. node_api: пин сертификата (--pinnedpubkey) ==="
curl() { printf 'CURL:%s\n' "$*"; }
REC_PIN='{"host":"203.0.113.9","panel":{"port":20951,"user":"u","pass":"p","base":"/","tls":true,"pincert":"AbCdEf12"}}'
OUT="$(node_api "$REC_PIN" "panel/api/inbounds/list" GET "" "$T/ck")"
printf '%s' "$OUT" | grep -q -- '--pinnedpubkey sha256//AbCdEf12'; ck "пин передаётся в curl" $?
printf '%s' "$OUT" | grep -qv ' -k'; ! printf '%s' "$OUT" | grep -q ' -k$' && ! printf '%s' "$OUT" | grep -q ' -k '; ck "с пином -k НЕ используется" $?
REC_NP='{"host":"203.0.113.9","panel":{"port":20951,"user":"u","pass":"p","base":"/","tls":true}}'
OUT2="$(node_api "$REC_NP" "login" POST "{}" "$T/ck")"
printf '%s' "$OUT2" | grep -q ' -k'; ck "без пина — fallback -k" $?
! printf '%s' "$OUT2" | grep -q 'pinnedpubkey'; ck "без пина нет pinnedpubkey" $?
unset -f curl

echo "=== 5. node_add: UFW deny при пустом MYIP (критичный фикс №1) ==="
rg -q 'ufw deny "\$\{NPP\}/tcp"' "$XKIT"; ck "else-ветка: ufw deny NPP/tcp" $?
rg -q 'IP мастера неизвестен — панель ноды закрыта в ufw' "$XKIT"; ck "WARN в heredoc про закрытую панель" $?
rg -q 'Публичный IP мастера не определён' "$XKIT"; ck "WARN мастера: панель ЗАКРЫТА + ssh -L" $?
rg -q 'ssh -p \$\{nport\} -L \$\{np_port\}' "$XKIT"; ck "подсказка SSH-туннеля" $?

echo "=== 6. Скан ноды: notvalid вместо ss (№7) ==="
rg -q 'notvalid=yes' "$XKIT"; ck "notvalid=yes присутствует" $?
! rg -q 'ss=yes' "$XKIT"; ck "переменная ss=yes убрана" $?
rg -q '\$notvalid' "$XKIT"; ck "notvalid попадает в вывод таблицы" $?

echo "=== 7. nodes_ensure_pool: проверка маршрута nginx (№4) ==="
rg -qF 'grep -qF "location ${ppath}" "$XKIT_CONF"' "$XKIT"; ck "early-return только при живом маршруте" $?
rg -q 'маршрута в nginx нет' "$XKIT"; ck "warn о пересоздании pool" $?

echo "=== 8. Новые функции/команды ==="
declare -F nodes_repair >/dev/null; ck "nodes_repair определена" $?
declare -F node_repin >/dev/null;   ck "node_repin определена" $?
declare -F dash_rotate >/dev/null;  ck "dash_rotate определена" $?
declare -F cert_pin >/dev/null;     ck "cert_pin определена" $?
declare -F xkit_info >/dev/null;    ck "xkit_info определена" $?
rg -qF 'rotate|rekey) dash_rotate' "$XKIT"; ck "CLI: xkit dash rotate" $?
rg -qF 'repair) nodes_repair ;;' "$XKIT"; ck "CLI: xkit nodes repair" $?
rg -q 'repin\)  shift; node_repin' "$XKIT"; ck "CLI: xkit nodes repin" $?
rg -qF 'info)    require_root; xkit_info' "$XKIT"; ck "CLI: xkit info" $?
rg -q '4\) Ротация: новый токен URL' "$XKIT"; ck "dash_menu: пункт ротации" $?

echo "=== 9. node_repin: пин сохраняется в nodes.json (№8) ==="
export XKIT_NODES="$T/nodes.json"
cat > "$XKIT_NODES" <<'NODES'
[{"name":"de1","host":"h1","panel":{"port":20001,"user":"u","pass":"p","base":"/","tls":true}},
 {"name":"de2","host":"h2","panel":{"port":20002,"user":"u","pass":"p","base":"/","tls":false}}]
NODES
cert_pin() { echo "PINTEST=="; }
node_repin de1 >/dev/null 2>&1; ck "node_repin de1 отработал" $?
[ "$(jq -r '.[0].panel.pincert' "$XKIT_NODES")" = "PINTEST==" ]; ck "пин записан в реестр" $?
[ "$(jq -r '.[1].panel.pincert // ""' "$XKIT_NODES")" = "" ]; ck "HTTP-нода не пинуется" $?
node_repin "нет_такой" >/dev/null 2>&1; [ $? -ne 0 ]; ck "нет ноды -> ошибка" $?
node_repin all >/dev/null 2>&1; [ "$(jq -r '.[0].panel.pincert' "$XKIT_NODES")" = "PINTEST==" ]; ck "repin all не ломает реестр" $?
unset -f cert_pin

echo "=== 10. expiry_set: flock + sanitize note (№9) ==="
export XKIT_EXPIRY="$T/exp.tsv"; rm -f "$XKIT_EXPIRY" "$XKIT_EXPIRY.lock"
expiry_set master "-" "2027-01-01" "$(printf 'заметка\tс\tтабами')"; ck "expiry_set с табами в note" $?
[ "$(awk -F'\t' 'END{print NF}' "$XKIT_EXPIRY")" = "4" ]; ck "в файле ровно 4 поля (табы убраны)" $?
[ "$(expiry_note master -)" = "заметка с табами" ]; ck "note читается целиком" $?
[ -f "$XKIT_EXPIRY.lock" ]; ck "lock-файл создаётся" $?
expiry_set node "de1" "2027-06-01" "провайдер"; ck "вторая запись ок" $?
[ "$(awk 'END{print NR}' "$XKIT_EXPIRY")" = "2" ]; ck "обе записи на месте" $?
expiry_del master "-"; [ "$(awk 'END{print NR}' "$XKIT_EXPIRY")" = "1" ]; ck "expiry_del с flock работает" $?

echo "=== 11. dash_gen: lock в subshell (№3) ==="
! rg -q '^[[:space:]]*exec 9>' "$XKIT"; ck "exec 9> убран (fd не утекает из функции)" $?
rg -q '\) 9>"\$\{XKIT_DASH_DIR\}/\.lock"' "$XKIT"; ck "flock в subshell ( ... ) 9>lock" $?
rg -q 'dash_gen_locked' "$XKIT"; ck "тело выделено в dash_gen_locked" $?

echo "=== 12. generate_dash_block: Basic Auth + CIDR + валидация (№6) ==="
export XKIT_DASH_HTPASSWD="$T/ht" XKIT_DASH_TOKEN="tok44" XKIT_DASH_AUTH="1"
XKIT_DASH_USER="dashXX"; XKIT_DASH_PASS="pass123"
dash_htpasswd_write; ck "htpasswd создан" $?
grep -qF 'dashXX:$apr1$' "$XKIT_DASH_HTPASSWD"; ck "apr1-хэш в htpasswd" $?
XKIT_DASH_ALLOW="10.0.0.0/8,1.2.3.4,999.1.1.1,5.6.7.8/33"
BLK="$(generate_dash_block)"
printf '%s' "$BLK" | grep -q 'auth_basic "xkit-dashboard";'; ck "auth_basic в nginx-блоке" $?
printf '%s' "$BLK" | grep -q 'auth_basic_user_file'; ck "auth_basic_user_file" $?
printf '%s' "$BLK" | grep -q 'allow 10.0.0.0/8;'; ck "CIDR попадает в allow" $?
printf '%s' "$BLK" | grep -q 'allow 1.2.3.4;'; ck "одиночный IP в allow" $?
! printf '%s' "$BLK" | grep -q 'allow 999.1.1.1;'; ck "кривой IP пропущен (fail-closed)" $?
! printf '%s' "$BLK" | grep -q 'allow 5.6.7.8/33;'; ck "битая маска пропущена" $?
printf '%s' "$BLK" | grep -q 'deny all;'; ck "deny all остаётся" $?
[ -z "${_dash_ips+x}" ]; ck "_dash_ips не утекает в глобал (local)" $?
XKIT_DASH_AUTH="0"
BLK2="$(generate_dash_block)"
! printf '%s' "$BLK2" | grep -q 'auth_basic'; ck "AUTH=0 — basic-auth нет" $?
XKIT_DASH_AUTH="1"

echo "=== 13. Санитизация data.json (критичный фикс №2) ==="
BAD='[{"id":1,"tag":"inb","port":443,"protocol":"vless","enable":true,"up":10,"down":20,"total":30,
 "settings":"{\"clients\":[{\"id\":\"SECRET-UUID\",\"email\":\"u1\",\"subId\":\"SUBID1\",\"total\":999,\"expiryTime\":0}]}",
 "streamSettings":"{\"network\":\"ws\",\"security\":\"reality\",\"realitySettings\":{\"privateKey\":\"TOPSECRET-KEY\",\"dest\":\"x\"}}",
 "clientStats":[{"email":"u1","up":11,"down":22,"total":33}]}]'
SI="$(dash_sanitize_inbounds "$BAD")"
jq -e '.[0].tag=="inb" and .[0].port==443 and .[0].proto=="vless" and .[0].total==30 and .[0].clients==1' <<<"$SI" >/dev/null 2>&1; ck "инбаунд: агрегаты для JS" $?
! grep -q 'TOPSECRET-KEY\|SECRET-UUID\|SUBID1' <<<"$SI"; ck "нет privateKey/UUID/subId" $?
SU="$(dash_sanitize_users "$BAD")"
jq -e '.[0].email=="u1" and .[0].total==33 and .[0].up==11 and .[0].down==22' <<<"$SU" >/dev/null 2>&1; ck "юзер: total = clientStats up+down (не квота 999)" $?
! grep -q 'SUBID1' <<<"$SU"; ck "в юзерах нет subId" $?
# clientStats строкой (бывает в некоторых версиях API)
BAD2='[{"tag":"i2","port":1,"protocol":"vless","settings":"{\"clients\":[{\"email\":\"u2\"}]}","clientStats":"[{\"email\":\"u2\",\"up\":5,\"down\":6}]"}]'
SU2="$(dash_sanitize_users "$BAD2")"
jq -e '.[0].total==11' <<<"$SU2" >/dev/null 2>&1; ck "clientStats-строка парсится" $?
# settings-строка без clients — не падает
dash_sanitize_inbounds '[{"tag":"x","port":1,"protocol":"vless","settings":"{}"}]' >/dev/null 2>&1; ck "пустые settings не ломают фильтр" $?

echo "=== 14. Сводка/реквизиты (терминал + txt) ==="
SUM_OUT="$(xkit_info)"
printf '%s' "$SUM_OUT" | grep -q 'XKIT v4.4'; ck "сводка печатается в терминал" $?
[ -s "$XKIT_INFO_FILE" ]; ck "файл сводки создан" $?
[ "$(stat -c %a "$XKIT_INFO_FILE")" = "600" ]; ck "файл сводки chmod 600" $?
xkit_summary_save >/dev/null 2>&1; [ -s "$XKIT_INFO_FILE" ]; ck "xkit_summary_save обновляет файл" $?

echo "=== 15. env round-trip с кредами дашборда ==="
XKIT_HOST="t.example.com"; XKIT_DASH_USER="dash1a2b"; XKIT_DASH_PASS="s3cret"; XKIT_DASH_AUTH="1"; XKIT_DASH="1"; XKIT_DASH_TOKEN="tk"
save_xkit_env >/dev/null 2>&1
XKIT_DASH_USER=""; XKIT_DASH_PASS=""; XKIT_DASH_AUTH=""; XKIT_DASH="0"; XKIT_DASH_TOKEN=""
load_xkit_env >/dev/null 2>&1
[ "$XKIT_DASH_USER" = "dash1a2b" ] && [ "$XKIT_DASH_PASS" = "s3cret" ]; ck "логин/пароль дашборда в xkit.env" $?
[ "$XKIT_DASH_AUTH" = "1" ] && [ "$XKIT_DASH" = "1" ] && [ "$XKIT_DASH_TOKEN" = "tk" ]; ck "AUTH/флаг/токен в xkit.env" $?

echo "=== 16. Права и прочее ==="
rg -q 'chmod 750 /var/lib/xkit' "$XKIT"; ck "subs: каталог 750 (не 755)" $?
rg -q 'dash_fix_perms' "$XKIT"; ck "dash_fix_perms вызывается" $?
rg -q 'chown root:"\$ngu"' "$XKIT"; ck "файлы дашборда root:www-data 640" $?
USAGE="$(bash "$XKIT" help 2>/dev/null)"
printf '%s' "$USAGE" | grep -q 'xkit info'; ck "usage: xkit info" $?
printf '%s' "$USAGE" | grep -q 'rotate'; ck "usage: dash rotate" $?
printf '%s' "$USAGE" | grep -q 'nodes repair'; ck "usage: nodes repair" $?
printf '%s' "$USAGE" | grep -q 'xkit-info.txt\|XKIT_INFO_FILE'; ck "usage: файл сводки в Файлах" $?
# stale-логика уже покрыта в test_v43.sh (секция 9b)

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "V44 ВСЕ ТЕСТЫ ПРОШЛИ"; else echo "ЕСТЬ ПРОВАЛЫ"; exit 1; fi
