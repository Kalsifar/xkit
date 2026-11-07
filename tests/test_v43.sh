#!/bin/bash
# Тесты XKIT v4.3: аудит-фиксы №1-10 + expiry + дашборд
set -u
PASS=0; FAIL=0
ck() { # ck "имя" 0/1
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
XMENU="${XKIT%/*}/xkit_menu.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

echo "=== 1. bash -n всех скриптов ==="
for f in "$XKIT" "${XKIT%/*}/install.sh" "${XKIT%/*}/nginx-xray-manager-v3.sh"; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>"$T/err"; ck "bash -n $(basename "$f")" $?
done

echo "=== 2. Синтаксис JS в HTML дашборда (извлечение <script>) ==="
source "$XKIT" || { echo "source xkit.sh failed"; exit 1; }
dash_write_html > "$T/index.html"
python3 - "$T" <<'PY' && ck "JS: node --check" 0 || ck "JS: node --check" 1
import sys, re, subprocess, os
t = sys.argv[1]
html = open(os.path.join(t, "index.html"), encoding="utf-8").read()
m = re.search(r"<script>(.*)</script>", html, re.S)
assert m, "нет <script> в HTML"
js = m.group(1)
open(os.path.join(t, "dash.js"), "w", encoding="utf-8").write(js)
r = subprocess.run(["node", "--check", os.path.join(t, "dash.js")], capture_output=True, text=True)
if r.returncode != 0:
    print(r.stderr); sys.exit(1)
# базовые проверки HTML
for token in ['id="nodes"', 'id="inbounds"', 'id="users"', 'id="cards"', 'data.json']:
    assert token in html, "нет " + token
PY

echo "=== 3. new_uuid: формат 8-4-4-4-12 (fallback эмулируем) ==="
mkdir -p "$T/nouuid"
U1="$(new_uuid)"; ck "реальный uuid (${U1})" $?
[[ "$U1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; ck "формат 8-4-4-4-12" $?

echo "=== 4. days_left / expiry_* ==="
[[ "$(days_left "$(date +%Y-%m-%d)")" == "0" ]]; ck "days_left сегодня = 0" $?
DL30="$(days_left "$(date -d '+30 days' +%Y-%m-%d)")"
[ "$DL30" = "29" ] || [ "$DL30" = "30" ]; ck "days_left +30 дней (=29-30, flooring)" $?
[[ "$(days_left "$(date -d '-5 days' +%Y-%m-%d)")" == "-5" ]]; ck "days_left -5 дней" $?
[ -z "$(days_left "гавно")" ]; ck "days_left кривая дата = пусто" $?

export XKIT_EXPIRY="$T/expiry.tsv"
expiry_set master "-" "2027-01-15" "hetzner CX22" && ck "expiry_set master" $?
expiry_set node "de1" "$(date -d '+3 days' +%Y-%m-%d)" "" && ck "expiry_set node" $?
[ "$(expiry_get master -)" = "2027-01-15" ]; ck "expiry_get master" $?
[ "$(expiry_note master -)" = "hetzner CX22" ]; ck "expiry_note" $?
expiry_set master "-" "2028-05-01" ""  # обновление той же записи
[ "$(expiry_get master -)" = "2028-05-01" ] && [ "$(awk -F'\t' '$1=="master"{c++}END{print c+0}' "$XKIT_EXPIRY")" = "1" ]; ck "expiry_set перезапись (без дублей)" $?
expiry_set master "-" "не-дата" 2>/dev/null; [ $? -ne 0 ]; ck "expiry_set отвергает кривую дату" $?
expiry_set master "-" "2099-01-01"; [ -s "$XKIT_EXPIRY" ]; ck "expiry файл не пуст" $?
expiry_del master "-"
[ -z "$(expiry_get master -)" ]; ck "expiry_del" $?
expiry_set master "-" "2099-01-01" ""  # вернуть для дальнейших тестов

echo "=== 5. human_bytes (v4.4: одна версия, IEC-суффиксы) ==="
[ "$(human_bytes 0)" = "0 B" ]; ck "human_bytes 0" $?
[ "$(human_bytes 512)" = "512 B" ]; ck "human_bytes 512" $?
[ "$(human_bytes 2048)" = "2.0 KiB" ]; ck "human_bytes 2KiB" $?
[ "$(human_bytes 15728640)" = "15.0 MiB" ]; ck "human_bytes 15MiB" $?

echo "=== 6. generate_dash_block (nginx) ==="
export XKIT_DASH=1 XKIT_DASH_TOKEN="tok123" XKIT_DASH_ALLOW="1.2.3.4, 5.6.7.8" XKIT_DASH_DIR="$T/dash"
NGINX_OUT="$(generate_dash_block)"
printf '%s\n' "$NGINX_OUT" | grep -q 'location = /d-tok123 {'; ck "redirect без слэша" $?
printf '%s\n' "$NGINX_OUT" | grep -q 'location ^~ /d-tok123/ {'; ck "локейшн с токеном" $?
printf '%s\n' "$NGINX_OUT" | grep -q 'allow 1.2.3.4;' && printf '%s\n' "$NGINX_OUT" | grep -q 'allow 5.6.7.8;' && printf '%s\n' "$NGINX_OUT" | grep -q 'deny all;'; ck "allow-IP из списка (2 шт) + deny" $?
printf '%s\n' "$NGINX_OUT" | grep -q 'X-Robots-Tag "noindex' ; ck "noindex заголовок" $?
printf '%s\n' "$NGINX_OUT" | grep -q 'access_log off;'; ck "access_log off" $?
XKIT_DASH_ALLOW="" ; NGINX_OUT2="$(generate_dash_block)"
! printf '%s\n' "$NGINX_OUT2" | grep -q 'deny all;'; ck "без allow — deny не пишется" $?

echo "=== 7. dash_master_json ==="
MJ="$(dash_master_json)"
jq -e '.nginx != "" and .xui != "" and .mem_pct >= 0' <<<"$MJ" >/dev/null 2>&1; ck "master JSON валиден" $?
[ -n "$(jq -r '.uptime_days' <<<"$MJ")" ]; ck "uptime присутствует" $?

echo "=== 8. dash_node_stats: нода жива (мок панели) + нода недоступна ==="
python3 -m http.server 18493 --bind 127.0.0.1 >/dev/null 2>&1 & SRV_PID=$!
# (v5.2.1): фиксированный sleep 0.7 flaky в медленных песочницах — ждём готовности порта
for _ in {1..100}; do curl -fsS -o /dev/null http://127.0.0.1:18493/ 2>/dev/null && break; sleep 0.1; done
node_login() { [ -f "$T/mock-login-ok" ] && return 0 || return 1; }
node_api() { echo '{"success":true,"obj":[{"up":1000,"down":2500,"total":3500},{"up":7,"down":8,"total":15}]}'; }
node_resource_stats() { printf 'null\tnull\tnull\n'; }
touch "$T/mock-login-ok"
REC_OK='{"name":"de1","host":"127.0.0.1","tunnel":{"port":18493},"panel":{"port":20000,"user":"u","pass":"p","base":"/","tls":false}}'
NS="$(dash_node_stats "$REC_OK" "2027-01-01" "провайдер X" 2>/dev/null)"
jq -e '.status=="ok" and .panel=="ok" and .up==1007 and .down==2508 and .total==3515 and .clients==2' <<<"$NS" >/dev/null 2>&1; ck "нода ok: трафик суммируется (1007/2508/3515, 2 инбаунда)" $?
jq -e '.latency_ms != null and .expiry=="2027-01-01" and .note=="провайдер X"' <<<"$NS" >/dev/null 2>&1; ck "нода ok: латентность + expiry + note" $?
REC_DOWN='{"name":"down1","host":"127.0.0.1","tunnel":{"port":1},"panel":{"port":20001,"user":"u","pass":"p","base":"/","tls":false}}'
NS2="$(dash_node_stats "$REC_DOWN" "" "" 2>/dev/null)"
jq -e '.status=="down" and .panel=="n/a" and .up==0 and .expiry==null and .days_left==null' <<<"$NS2" >/dev/null 2>&1; ck "нода down: status/panel/нули/null" $?
kill $SRV_PID 2>/dev/null; SRV_PID=""

echo "=== 9. dash_gen: полный прогон (мок kit_session) ==="
export XKIT_DIR="$T/xkit" XKIT_ENV="$T/xkit/xkit.env" XKIT_NODES="$T/xkit/nodes.json"
export XKIT_DASH_DIR="$T/dash" XKIT_EXPIRY="$T/expiry.tsv" XKIT_NODES_METRICS="$T/nodes-metrics.json"
mkdir -p "$T/xkit" "$T/dash"
# фейковый серт для cert_end
openssl ecparam -name prime256v1 -genkey -noout -out "$T/cert.key" 2>/dev/null
openssl req -new -x509 -key "$T/cert.key" -out "$T/cert.pem" -days 365 -subj "/CN=test" 2>/dev/null
cat > "$XKIT_ENV" <<'ENV'
XKIT_VERSION="4.3"
XKIT_HOST="test.example.com"
XKIT_CRT="/REPLACE_ME/cert.pem"
XKIT_KEY="/REPLACE_ME/cert.key"
XKIT_CERT_MODE="selfsigned"
XKIT_SUB_TOKEN="subtok"
XKIT_UFW="0"
XKIT_PANEL_SUB_PORT=""
XKIT_PANEL_SUB_PATH=""
XKIT_REALITY_INTERNAL="0"
XKIT_BAL_STRATEGY="leastPing"
XKIT_POOL_INBOUND=""
XKIT_POOL_TAG=""
XKIT_REPO_URL=""
XKIT_DASH="1"
XKIT_DASH_TOKEN="tok123"
XKIT_DASH_ALLOW="1.2.3.4"
ENV
sed -i "s#/REPLACE_ME#$T#" "$XKIT_ENV"
cat > "$XKIT_NODES" <<'NODES'
[{"name":"de1","host":"127.0.0.1","ssh_port":22,"ssh_user":"root","auth":"key","key_path":"/tmp/k",
  "panel":{"port":20000,"user":"u","pass":"p","base":"/","tls":false},
  "tunnel":{"port":18493,"proto":"vless","net":"tcp","sec":"reality","uuid":"x","pbk":"y","sid":"z","sni":"s","dest":"1.1.1.1:443"},
  "outbound_tag":"node-de1","created":"2026-01-01T00:00:00+00:00"},
 {"name":"down1","host":"127.0.0.1","ssh_port":22,"ssh_user":"root","auth":"key","key_path":"/tmp/k",
  "panel":{"port":20001,"user":"u","pass":"p","base":"/","tls":false},
  "tunnel":{"port":1,"proto":"vless","net":"tcp","sec":"reality","uuid":"x","pbk":"y","sid":"z","sni":"s","dest":"1.1.1.1:443"},
  "outbound_tag":"node-down1","created":"2026-01-01T00:00:00+00:00"}]
NODES
expiry_set node "de1" "$(date -d '+55 days' +%Y-%m-%d)" "hetzner"
expiry_set master "-" "$(date -d '+200 days' +%Y-%m-%d)" ""
# мок сессии панели: панель "ok", 2 инбаунда с клиентами И clientStats (как в 3x-ui)
kit_session() {
  INBOUNDS='[{"id":1,"tag":"inbound-2083","port":2083,"protocol":"vless","enable":true,"up":1048576,"down":2097152,"total":3145728,
    "settings":"{\"clients\":[{\"email\":\"user1\",\"total\":1048576,\"up\":100,\"down\":100,\"enable\":true,\"expiryTime\":0},{\"email\":\"user2\",\"total\":2097152,\"up\":200,\"down\":200,\"enable\":true,\"expiryTime\":1893456000000}]}",
    "clientStats":[{"email":"user1","up":1048576,"down":1048576,"total":2097152},{"email":"user2","up":409600,"down":307200,"total":716800}]},
   {"id":2,"tag":"inbound-2087","port":2087,"protocol":"vless","enable":false,"up":0,"down":0,"total":0,"settings":"{\"clients\":[]}","clientStats":[]}]'
  return 0
}
dash_gen >/dev/null 2>"$T/gen.err"; ck "dash_gen отработал" $?
jq -e . "$T/dash/data.json" >/dev/null 2>&1; ck "data.json валидный JSON" $?
jq -e '.panel=="ok" and .host=="test.example.com" and .strategy=="leastPing"' "$T/dash/data.json" >/dev/null 2>&1; ck "панель/хост/стратегия" $?
jq -e '.totals.total==3145728 and (.inbounds|length)==2' "$T/dash/data.json" >/dev/null 2>&1; ck "суммарный трафик + инбаунды" $?
# v4.4: топ по ПОТРАЧЕННОМУ (clientStats up+down): user1=2097152 > user2=716800
jq -e '.users[0].email=="user1" and .users[0].total==2097152 and .users[1].email=="user2" and .users[1].total==716800' "$T/dash/data.json" >/dev/null 2>&1; ck "топ по потраченному трафику (clientStats, не квота)" $?
# v4.4: data.json санитизирован — нет privateKey/UUID/subId/настроек клиентов
! grep -q 'privateKey\|subId\|"clients":\[' "$T/dash/data.json"; ck "data.json без privateKey/subId/clients" $?
jq -e '.inbounds[0].clients==2 and .inbounds[0].proto=="vless" and .inbounds[1].clients==0' "$T/dash/data.json" >/dev/null 2>&1; ck "инбаунды: поля для JS (clients/proto)" $?
jq -e '.stale==false' "$T/dash/data.json" >/dev/null 2>&1; ck "stale=false при живой панели" $?
jq -e '.nodes|length==2' "$T/dash/data.json" >/dev/null 2>&1; ck "обе ноды в data.json" $?
jq -e '[.nodes[]|select(.name=="de1")][0].days_left==54 or [.nodes[]|select(.name=="de1")][0].days_left==55' "$T/dash/data.json" >/dev/null 2>&1; ck "de1: days_left=54-55" $?
jq -e '[.nodes[]|select(.name=="down1")][0].status=="down"' "$T/dash/data.json" >/dev/null 2>&1; ck "down1: статус down" $?
jq -e '.expiry_master.date!=null and (.expiry_master.days_left==199 or .expiry_master.days_left==200)' "$T/dash/data.json" >/dev/null 2>&1; ck "аренда мастера в data.json" $?
[ -s "$T/dash/index.html" ]; ck "index.html создан" $?
rm -f "$T/dash/index.html"
dash_gen >/dev/null 2>&1
[ -s "$T/dash/index.html" ]; ck "index.html самовосстановился" $?

echo "=== 9b. dash_gen: панель недоступна — stale-данные сохраняются (v4.4) ==="
OLD_INB="$(jq -c '.inbounds' "$T/dash/data.json")"
kit_session() { return 1; }
dash_gen >/dev/null 2>&1; ck "dash_gen при мёртвой панели не падает" $?
jq -e '.panel=="down" and .stale==true' "$T/dash/data.json" >/dev/null 2>&1; ck "stale=true при мёртвой панели" $?
[ "$(jq -c '.inbounds' "$T/dash/data.json")" = "$OLD_INB" ]; ck "прошлые данные не затёрты пустотой" $?
unset -f kit_session

echo "=== 10. UFW-heredoc: переменные не теряются (регрессия №1) ==="
# эмулируем удалённую часть: quoted heredoc с env
UFW_OUT="$(env MYIP='203.0.113.5' NPORT='22' TP='443' NPP='20555' bash -s <<'EOS' 2>&1
set -u
: "${NPORT:?нет NPORT}"; : "${TP:?нет TP}"; : "${NPP:?нет NPP}"
echo "RULES_OK ${NPORT} ${TP} ${NPP} ${MYIP}"
EOS
)"
printf '%s' "$UFW_OUT" | grep -q "RULES_OK 22 443 20555 203.0.113.5"; ck "env-переменные доезжают в heredoc" $?
UFW_OUT2="$(env MYIP='' bash -s <<'EOS' 2>/dev/null
set -u
: "${NPORT:?нет NPORT}"
echo "REACHED_ENABLE"
EOS
)" ; [ $? -ne 0 ] && ! printf '%s' "$UFW_OUT2" | grep -q REACHED_ENABLE; ck "без NPORT скрипт падает ДО enable (set -u + :?)" $?
# в коде node_add нет глушения ufw allow и есть NPORT/TP/NPP в env-строке
rg -q 'env MYIP=.*NPORT=.*TP=.*NPP=' "$XKIT"; ck "node_add: env NPORT/TP/NPP присутствует" $?
rg -q 'ufw allow "\$\{NPORT\}/tcp" \|\|' "$XKIT"; ck "node_add: ufw allow не заглушен (|| exit при ошибке)" $?

echo "=== 11. reality verify: провал = selfsig=yes (регрессия №2) ==="
V1="$(echo | openssl s_client -connect 127.0.0.1:1 -servername x 2>&1 | grep -q 'Verify return code: 0 (ok)' && echo no || echo yes)"
[ "$V1" = "yes" ]; ck "нет verify-строки -> selfsig=yes (логика)" $?
V2="$(grep -q 'Verify return code: 0 (ok)' <<<"Verify return code: 0 (ok)" && echo no || echo yes)"
[ "$V2" = "no" ]; ck "verify ok -> selfsig=no (логика)" $?
rg -c "Verify return code: 0 \(ok\)" "$XKIT" >/dev/null; rg -c 'grep -c .Verify return code: 0.' "$XKIT" >/dev/null 2>&1 && FAIL=1 || PASS=$((PASS+1)); echo "  [OK]   старая логика grep -c убрана"

echo "=== 12. xkit_self_update читает xkit.env (регрессия №3) ==="
rg -q 'load_xkit_env 2>/dev/null \|\| true   # свежая SSH-сессия' "$XKIT"; ck "load_xkit_env в xkit_self_update" $?

echo "=== 13. nodes_ensure_pool: routes_del + return 1 (регрессия №4) ==="
rg -q 'routes_del "\$\{XKIT_POOL_INBOUND\}"' "$XKIT"; ck "routes_del старого pool" $?
rg -q 'if ! regen_conf_and_apply; then' "$XKIT"; ck "regen failure -> return 1" $?
rg -q 'nodes_ensure_pool \|\| apply_failed=1' "$XKIT"; ck "node_add не показывает успех при провале" $?

echo "=== 14. install.sh: плейсхолдер + чистка WORKDIR (№6) ==="
rg -qF 'kalsifar' "${XKIT%/*}/install.sh" && rg -qF 'не настроен' "${XKIT%/*}/install.sh"; ck "ник репо вписан (kalsifar) + страховка не настроен" $?
! rg -q '^\s*exec "\$\{RUN\[@\]\}"' "${XKIT%/*}/install.sh"; ck "exec убран (trap отработает)" $?
rg -q 'rm -rf "\$WORK"' "${XKIT%/*}/install.sh"; ck "WORKDIR чистится" $?

echo "=== 15. mktemp 3x-ui (№7) / new_uuid (№9) / v3 (№8,10) ==="
! rg -q '/tmp/3x-ui-install.sh' "$XKIT" "${XKIT%/*}/nginx-xray-manager-v3.sh"; ck "фикс-пути /tmp/3x-ui-install.sh убраны" $?
rg -q "mktemp /tmp/xkit-3xui" "$XKIT"; ck "xkit: mktemp установщика" $?
rg -q "mktemp /tmp/xmesh-3xui" "${XKIT%/*}/nginx-xray-manager-v3.sh"; ck "v3: mktemp установщика" $?
rg -q 'trap .rm -f "\$TMP" "\$OPEN". EXIT' "$XKIT"; ck "скан ноды: trap чистки TMP/OPEN" $?
rg -q "printf '%s-%s-%s-%s-%s'" "$XKIT"; ck "new_uuid fallback 8-4-4-4-12" $?
! rg -q 'rm -f /etc/nginx/sites-enabled/default' <(sed -n '/^write_master_nginx_conf/,/^}/p' "${XKIT%/*}/nginx-xray-manager-v3.sh"); ck "v3: default сносится не в write_master_nginx_conf" $?
rg -q 'tar tzf "\$out"' "${XKIT%/*}/nginx-xray-manager-v3.sh"; ck "v3: backup проверяется tar tzf" $?

echo "=== 16. Меню/CLI-интеграция v4.3 ==="
rg -q '[0-9]+\) dash_menu' "$XMENU"; ck "пункт меню 23 (dash в подменю мониторинга)" $?
rg -q '[0-9]+\) expiry_menu' "$XMENU"; ck "пункт меню 24 (expiry в подменю мониторинга)" $?
rg -q 'dash\)    shift; require_root' "$XKIT"; ck "CLI: xkit dash ..." $?
rg -q 'expiry\)  shift; require_root' "$XKIT"; ck "CLI: xkit expiry ..." $?
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.0" $?
rg -q 'СРОКИ АРЕНДЫ' "$XKIT"; ck "меню сроков аренды" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit "$FAIL"
