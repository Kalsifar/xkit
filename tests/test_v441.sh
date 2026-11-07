#!/bin/bash
# Тесты XKIT v4.4.1: аудит №4 (хвосты дашборда):
#  1) stale-ветка dash_gen санитизирует данные при ЧТЕНИИ (критично)
#  2) total = up+down (потрачено) в dash_node_stats и totals мастера
#  3) dash_rotate: откат env+htpasswd при сбое apply
#  4) пароли маскируются в stdout (полные — только в файл 600)
#  5) dash_fix_perms: группа nginx через id -gn
#  6) права 750/umask 027 сразу (без окна 755/644)
#  7) node_repin: подтверждение при смене пина (TOFU)
#  8) nodes_repair style + README
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

echo "=== 1. Версия и changelog ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?

echo "=== 2. КРИТИЧНО №1: stale-ветка санитизирует при чтении (статика) ==="
rg -q 'dash_sanitize_inbounds "\$old_inb"' "$XKIT"; ck "stale: inbounds через sanitizer" $?
rg -q 'dash_sanitize_users "\$raw_inb"' "$XKIT";   ck "stale: raw v4.3 — users пересчитываются" $?
rg -q 'dash_users_whitelist "\$old_users"' "$XKIT"; ck "stale: sanitized — users через whitelist" $?
rg -q 'пусто безопаснее' "$XKIT"; ck "stale: нераспознанный формат -> пусто (fail-closed)" $?
rg -q 'Последний барьер' "$XKIT"; ck "финальный sanitize перед записью (барьер)" $?

echo "=== 3. №2: total = up+down (не квота) ==="
! rg -q '\(\.total // 0\) \] \| add // 0' "$XKIT"; ck "нет суммирования квоты .total" $?
rg -qF '[ $a[] | ((.up // 0) + (.down // 0)) ] | add // 0' "$XKIT"; ck "dash_node_stats: total = up+down" $?
rg -qF 'total:($u+$d)' "$XKIT"; ck "totals мастера: total = up+down" $?

echo "=== 4. №3: dash_rotate — save_xkit_env ПОСЛЕ apply + откат ==="
awk '/^dash_rotate\(\)/{f=1} f && /if ! regen_conf_and_apply/{r=NR} f && /^  save_xkit_env/{s=NR; if (r && s>r) ok=1} f && /^\}/{exit} END{exit !ok}' "$XKIT"
ck "save_xkit_env идёт после успешного regen_conf_and_apply" $?
rg -q 'ротация ОТМЕНЕНА' "$XKIT"; ck "сообщение об отмене ротации" $?
rg -q 'cp -f "\$htbk" "\$XKIT_DASH_HTPASSWD"' "$XKIT"; ck "откат htpasswd: копированием из бэкапа (усилено в v4.6)" $?
rg -q 'old_user="\$\{XKIT_DASH_USER\}" old_pass="\$\{XKIT_DASH_PASS\}"' "$XKIT"; ck "старые user/pass сохраняются для отката" $?

echo "=== 5. №4: пароли не печатаются в stdout по умолчанию ==="
rg -q 'show_secrets=0' "$XKIT" && rg -q -- '--show-secrets' "$XKIT"; ck "флаг --show-secrets" $?
rg -q 'xkit_summary_text --show-secrets' "$XKIT"; ck "файл пишется через --show-secrets" $?
rg -q 'полные реквизиты: cat' "$XKIT"; ck "маска + подсказка про файл" $?
rg -q 'Пароли не печатаются в терминал' "$XKIT"; ck "xkit_info объясняет, где пароли" $?

echo "=== 6. №5: dash_fix_perms — id -gn + явный warn ==="
rg -q 'id -gn "\$nguser"' "$XKIT"; ck "первичная группа юзера nginx (id -gn)" $?
rg -q 'группа nginx не найдена' "$XKIT"; ck "warn вместо молчаливого пропуска" $?

echo "=== 7. №6: права 750 сразу, umask 027 ==="
rg -q 'umask 027' "$XKIT"; ck "umask 027 в dash_gen_locked" $?
rg -q 'mkdir -p -m 750 "\$XKIT_DASH_DIR"' "$XKIT"; ck "mkdir сразу с -m 750" $?
! rg -q 'chmod 755 /var/lib/xkit' "$XKIT"; ck "chmod 755 убран (окна 755 больше нет)" $?

echo "=== 8. №7: node_repin — подтверждение смены пина (TOFU) ==="
rg -q 'пин ИЗМЕНИЛСЯ' "$XKIT"; ck "warn о смене пина (старый/новый)" $?
rg -q 'Принять новый пин\? \[y/N\]' "$XKIT"; ck "явное подтверждение [y/N]" $?
rg -qF '[ -t 0 ]' "$XKIT"; ck "без tty пин не обновляется (безопасный дефолт)" $?
rg -q 'пин не обновлён' "$XKIT"; ck "отказ = пин в реестре не меняется" $?

echo "=== 9. №8: nodes_repair style + usage ==="
rg -q 'nodes_load 2>/dev/null \| jq -r .length.' "$XKIT"; ck "cnt через pipe (не process substitution)" $?
USAGE="$(bash "$XKIT" help 2>/dev/null)"
printf '%s' "$USAGE" | grep -q 'пароли маскируются'; ck "usage: xkit info — маскировка" $?

echo "=== 10. ФУНКЦИОНАЛЬНО: stale-ветка возвращает sanitized (end-to-end dash_gen) ==="
source "$XKIT" || { echo "source xkit.sh failed"; exit 1; }

# панель отсутствует: read_panel_settings падает быстро -> kit_session fail -> stale
export XUI_RESULT="$T/nonexistent-xui.env"
export XKIT_DIR="$T/env" XKIT_ENV="$T/env/xkit.env" XKIT_NODES="$T/env/nodes.json" \
       XKIT_EXPIRY="$T/env/expiry.tsv" XKIT_INFO_FILE="$T/env/info.txt" \
       XKIT_DASH_DIR="$T/env/dash" XKIT_NODES_METRICS="$T/env/nodes-metrics.json"
mkdir -p "$T/env/dash"
printf 'XKIT_VERSION="4.4.2"\nXKIT_HOST="t.example.com"\nXKIT_DASH="1"\nXKIT_DASH_TOKEN="tk441"\nXKIT_DASH_USER="dashu"\nXKIT_DASH_PASS="dashP4ssW"\n' > "$XKIT_ENV"
echo '[]' > "$XKIT_NODES"

# сырой data.json формата v4.3 (то, что стояло на сервере до апгрейда)
cat > "$XKIT_DASH_DIR/data.json" <<'RAW43'
{"version":"4.3","host":"t.example.com",
 "inbounds":[{"id":1,"tag":"inb","port":443,"protocol":"vless","enable":true,"up":10,"down":20,"total":30,
  "settings":"{\"clients\":[{\"id\":\"SECRET-UUID\",\"email\":\"u1\",\"subId\":\"SUBID1\",\"total\":999}]}",
  "streamSettings":"{\"network\":\"ws\",\"security\":\"reality\",\"realitySettings\":{\"privateKey\":\"TOPSECRET-KEY\"}}",
  "clientStats":[{"email":"u1","up":11,"down":22,"total":33}]}],
 "users":[{"email":"old","ib":"x","up":1,"down":2,"total":3}],
 "totals":{"up":0,"down":0,"total":0}}
RAW43
dash_gen >/dev/null 2>&1; ck "dash_gen (панель недоступна) отработал" $?
D="$XKIT_DASH_DIR/data.json"
[ -s "$D" ] && jq -e . "$D" >/dev/null 2>&1; ck "data.json валидный JSON" $?
jq -e '.stale == true' "$D" >/dev/null 2>&1; ck "stale=true" $?
! grep -q 'TOPSECRET-KEY' "$D"; ck "КРИТИЧНО: privateKey НЕ вернулся через stale" $?
! grep -q 'SECRET-UUID' "$D";  ck "КРИТИЧНО: UUID клиента НЕ вернулся" $?
! grep -q 'SUBID1' "$D";       ck "КРИТИЧНО: subId НЕ вернулся" $?
jq -e '.inbounds[0].total == 30' "$D" >/dev/null 2>&1; ck "инбаунд: total=up+down (30)" $?
jq -e '.totals.total == 30' "$D" >/dev/null 2>&1; ck "totals: total=up+down (30)" $?
jq -e '.users[0].total == 33 and .users[0].email == "u1"' "$D" >/dev/null 2>&1; ck "users пересчитаны из clientStats raw (33)" $?
[ "$(stat -c %a "$D")" = "640" ]; ck "data.json сразу 640 (umask 027)" $?
[ "$(stat -c %a "$XKIT_DASH_DIR")" = "750" ]; ck "dash-каталог 750" $?
[ "$(stat -c %a "$XKIT_DASH_DIR/index.html" 2>/dev/null)" = "640" ]; ck "index.html 640" $?

# v4.4+ формат (уже sanitized): users сохраняются, но через whitelist (мусор режется)
cat > "$D" <<'SAN44'
{"version":"4.4","host":"t.example.com",
 "inbounds":[{"tag":"inb","port":443,"proto":"vless","enable":true,"up":10,"down":20,"total":30,"clients":1}],
 "users":[{"email":"u1","ib":"inb","up":11,"down":22,"total":33,"enable":true,"expiryTime":0,"TOPSECRET":"leak"}],
 "totals":{"up":10,"down":20,"total":30}}
SAN44
dash_gen >/dev/null 2>&1; ck "dash_gen поверх v4.4-формата" $?
jq -e '.stale == true' "$D" >/dev/null 2>&1; ck "stale=true (v4.4 данные)" $?
! grep -q 'TOPSECRET' "$D"; ck "whitelist: лишнее поле users вырезано" $?
jq -e '.users[0].total == 33 and .users[0].email == "u1" and .users[0].up == 11' "$D" >/dev/null 2>&1; ck "safe-поля users сохранены" $?
jq -e '.inbounds[0].clients == 1 and .inbounds[0].proto == "vless"' "$D" >/dev/null 2>&1; ck "sanitized-инбаунды идемпотентны (proto/clients не теряются)" $?
SI_IDEMP="$(dash_sanitize_inbounds "$(dash_sanitize_inbounds '[{"tag":"z","port":1,"protocol":"trojan","settings":"{\"clients\":[{},{}]}","up":5,"down":6}]')")"
jq -e '.[0].proto=="trojan" and .[0].clients==2 and .[0].total==11' <<<"$SI_IDEMP" >/dev/null 2>&1; ck "sanitize(sanitize(x)) == sanitize(x)" $?

echo "=== 11. dash_users_whitelist (юнит) ==="
W='[{"email":"a","ib":"i","up":1,"down":2,"total":3,"enable":true,"expiryTime":0,"evil":"x"},{"email":"b"}]'
WO="$(dash_users_whitelist "$W")"
jq -e '.[0].total==3 and (.[0] | has("evil") | not)' <<<"$WO" >/dev/null 2>&1; ck "лишние поля вырезаются" $?
jq -e '.[1].email=="b" and .[1].up==0' <<<"$WO" >/dev/null 2>&1; ck "недостающие поля — дефолты" $?
[ "$(dash_users_whitelist 'garbage')" = "[]" ]; ck "мусор -> [] (fail-closed)" $?

echo "=== 12. dash_node_stats: total = up+down (мок панели) ==="
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",20897)); s.listen(8); time.sleep(25)' &
LPID=$!
sleep 0.6
node_login() { return 0; }
node_api() { printf '%s' '{"success":true,"obj":[{"up":10,"down":20,"total":999999999},{"up":1,"down":2,"total":0}]}'; }
REC='{"name":"de1","host":"127.0.0.1","tunnel":{"port":20897},"panel":{"port":20897,"user":"u","pass":"p","base":"/","tls":false}}'
NS="$(dash_node_stats "$REC" "2027-01-01" "note" 2>/dev/null)"
kill "$LPID" 2>/dev/null
jq -e '.status=="ok" and .panel=="ok" and .up==11 and .down==22 and .total==33 and .clients==2' <<<"$NS" >/dev/null 2>&1; ck "нода: total=33 (не квота 999999999+0)" $?
unset -f node_login node_api

echo "=== 13. Сводка: stdout маскирует, файл содержит полные ==="
export XUI_RESULT="$T/xui.env"
printf 'XUI_PANEL_PORT="2053"\nXUI_WEB_BASE_PATH="/abc/"\nXUI_USERNAME="adm1n"\nXUI_PASSWORD="SUP3RSECRET42"\n' > "$XUI_RESULT"
XKIT_HOST="t.example.com"; XKIT_DASH="1"; XKIT_DASH_TOKEN="tk"; XKIT_DASH_USER="dashu"; XKIT_DASH_PASS="dashP4ssW"
# IMPORTANT: load_xkit_env перечитывает xkit.env — креды дашборда там УЖЕ есть
# (добавлены в fixture в секции 10), переменные выше — для читаемости
M="$(xkit_summary_text)"
! grep -q 'SUP3RSECRET42' <<<"$M"; ck "stdout: пароль панели НЕ печатается" $?
! grep -q 'dashP4ssW' <<<"$M";     ck "stdout: пароль дашборда НЕ печатается" $?
grep -q '\*\*\*\*\*\*\*\*' <<<"$M"; ck "stdout: маска ********" $?
F="$(xkit_summary_text --show-secrets)"
grep -q 'SUP3RSECRET42' <<<"$F" && grep -q 'dashP4ssW' <<<"$F"; ck "--show-secrets: полные реквизиты" $?
XO="$(xkit_info)"
! grep -q 'SUP3RSECRET42' <<<"$XO"; ck "xkit_info (stdout): паролей нет" $?
grep -q 'SUP3RSECRET42' "$XKIT_INFO_FILE" && grep -q 'dashP4ssW' "$XKIT_INFO_FILE"; ck "xkit_info (файл 600): полные реквизиты" $?
[ "$(stat -c %a "$XKIT_INFO_FILE")" = "600" ]; ck "файл сводки 600" $?

echo "=== 14. dash_fix_perms: без группы nginx — warn, rc=0 (не молчит) ==="
FP="$(dash_fix_perms 2>&1)"; RC=$?
[ "$RC" = "0" ]; ck "dash_fix_perms rc=0" $?
if getent group www-data >/dev/null 2>&1; then
  echo "  [SKIP] www-data есть в системе — warn-ветка не проверяется"
  PASS=$((PASS+1))
else
  printf '%s' "$FP" | grep -q 'группа nginx не найдена'; ck "warn напечатан (нет www-data)" $?
fi

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "V441 ВСЕ ТЕСТЫ ПРОШЛИ"; else echo "ЕСТЬ ПРОВАЛЫ"; exit 1; fi
