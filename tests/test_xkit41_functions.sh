#!/bin/bash
# Юнит-тесты XKIT v4.1: ноды (merge шаблона), Reality-скан, externalProxy,
# env с новыми ключами, генерация конфига (подписки панели + internal Reality)
set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/xkit.sh"
PASS=0; FAIL=0
chk()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got: '$2', want: '$3')"; fi; }
chki() { if [ "$2" -eq "$3" ] 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got: $2, want: $3)"; fi; }
chkc() { if echo "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (нет строки: $3)"; fi; }
chkn() { if echo "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 (нашлась запрещённая строка: $3)"; else PASS=$((PASS+1)); fi; }

source "$SCRIPT" || { echo "source failed"; exit 1; }

TD=$(mktemp -d)
XKIT_ROUTES="$TD/routes.tsv"
XKIT_ENV="$TD/xkit.env"
XKIT_NODES="$TD/nodes.json"
CAMO_DIR="$TD/camo"
export LC_ALL=C

# ===== 1. reality_expand_targets =====
chk "expand /30"      "$(reality_expand_targets 192.0.2.0/30 | tr '\n' ' ' | sed 's/ $//')" "192.0.2.1 192.0.2.2"
chk "expand /24 count" "$(reality_expand_targets 192.0.2.0/24 | wc -l)" 254
chk "expand too-big"  "$(reality_expand_targets 10.0.0.0/16)" "ERR:too-big"
chk "expand bad cidr" "$(reality_expand_targets 10.0.0.0/xx)" "ERR:bad-cidr"
chk "expand host list" "$(reality_expand_targets "1.1.1.1 example.com" | tr '\n' ' ' | sed 's/ $//')" "1.1.1.1 example.com"
chk "expand single ip" "$(reality_expand_targets 203.0.113.5)" "203.0.113.5"

# ===== 2. nodes_merge_template =====
NODE='{"name":"de1","host":"198.51.100.5","ssh_port":22,"ssh_user":"root","auth":"key","key_path":"/k",
 "panel":{"port":21000,"user":"u","pass":"p","base":"/"},
 "tunnel":{"port":443,"proto":"vless","net":"tcp","sec":"reality","uuid":"U-U-I-D","pbk":"PBK1","sid":"AB12CD34","sni":"cloudflare-dns.com","dest":"1.1.1.1:443","flow":"xtls-rprx-vision"},
 "outbound_tag":"node-de1"}'
TPL='{"log":{"loglevel":"warning"},"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"outboundTag":"block","ip":["geoip:private"]}]}}'

M="$(nodes_merge_template "$TPL" "[$NODE]" "inbound-2083" "roundRobin")"
chk "merge valid json"  "$(jq -e . >/dev/null 2>&1 <<<"$M" && echo y)" y
chkc "merge outbound"   "$(jq -r '.outbounds[].tag' <<<"$M" | tr '\n' ' ')" "node-de1"
chk "merge direct kept" "$(jq -r '[.outbounds[]|select(.tag=="direct")]|length' <<<"$M")" 1
chk "merge vnext addr"  "$(jq -r '.outbounds[]|select(.tag=="node-de1")|.settings.vnext[0].address' <<<"$M")" "198.51.100.5"
chk "merge vnext port"  "$(jq -r '.outbounds[]|select(.tag=="node-de1")|.settings.vnext[0].port' <<<"$M")" 443
chk "merge pbk"         "$(jq -r '.outbounds[]|select(.tag=="node-de1")|.streamSettings.realitySettings.publicKey' <<<"$M")" "PBK1"
chk "merge rule top"    "$(jq -r '.routing.rules[0].inboundTag[0]' <<<"$M")" "inbound-2083"
chk "merge rule balancer" "$(jq -r '.routing.rules[0].balancerTag' <<<"$M")" "XKIT_POOL"
chk "merge balancer sel" "$(jq -r '.routing.balancers[0].selector[0]' <<<"$M")" "node-"
chk "merge strategy"    "$(jq -r '.routing.balancers[0].strategy.type' <<<"$M")" "roundRobin"
chk "merge no obs RR"   "$(jq -r '.observatory // "absent"' <<<"$M")" "absent"

M2="$(nodes_merge_template "$M" "[$NODE]" "inbound-2083" "leastPing")"
chki "re-merge не дублирует outbounds" "$(jq '[.outbounds[]|select(.tag|startswith("node-"))]|length' <<<"$M2")" 1
chki "re-merge не дублирует rules"     "$(jq '[.routing.rules[]|select(.balancerTag=="XKIT_POOL")]|length' <<<"$M2")" 1
chki "re-merge не дублирует balancers" "$(jq '[.routing.balancers[]|select(.tag=="XKIT_POOL")]|length' <<<"$M2")" 1
chk "leastPing observatory" "$(jq -r '.observatory.probeUrl' <<<"$M2")" "https://www.google.com/generate_204"

M3="$(nodes_merge_template "$TPL" "[$NODE]" "inbound-2083" "leastLoad")"
chk "leastLoad burst" "$(jq -r '.burstObservatory.pingConfig.destination' <<<"$M3")" "https://www.google.com/generate_204"
chk "leastLoad нет observatory" "$(jq -r '.observatory // "absent"' <<<"$M3")" "absent"
chk "bad strategy -> RR" "$(jq -r '.routing.balancers[0].strategy.type' <<<"$(nodes_merge_template "$TPL" "[$NODE]" "" "hack")")" "roundRobin"

M4="$(nodes_merge_template "$M" "[]" "inbound-2083" "roundRobin")"
chki "пустые ноды: outbound удалён" "$(jq '[.outbounds[]|select(.tag|startswith("node-"))]|length' <<<"$M4")" 0
chki "пустые ноды: rule удалён"     "$(jq '[.routing.rules[]|select(.balancerTag=="XKIT_POOL")]|length' <<<"$M4")" 0
chki "пустые ноды: balancer удалён" "$(jq '[.routing.balancers[]|select(.tag=="XKIT_POOL")]|length' <<<"$M4")" 0
chk "пустые ноды: obs нет" "$(jq -r '.observatory // "absent"' <<<"$M4")" "absent"

M5="$(nodes_merge_template "$TPL" "[$NODE]" "" "roundRobin")"
chki "нет pool_tag: rule не ставится" "$(jq '[.routing.rules[]|select(.balancerTag=="XKIT_POOL")]|length' <<<"$M5")" 0

# ===== 3. nodes.json upsert/del (как в node_add/nodes_del) =====
printf '%s' "[$NODE]" > "$XKIT_NODES"
NODE2='{"name":"de2","host":"198.51.100.6","outbound_tag":"node-de2"}'
jq -c --argjson r "$NODE2" 'map(select(.name != $r.name)) + [$r]' < "$XKIT_NODES" > "$TD/n.tmp" && mv "$TD/n.tmp" "$XKIT_NODES"
chki "upsert добавил" "$(jq 'length' < "$XKIT_NODES")" 2
jq -c --arg n "de1" 'map(select(.name != $n))' < "$XKIT_NODES" > "$TD/n.tmp" && mv "$TD/n.tmp" "$XKIT_NODES"
chki "del удалил" "$(jq 'length' < "$XKIT_NODES")" 1
chk "del удалил нужную" "$(jq -r '.[0].name' < "$XKIT_NODES")" "de2"

# ===== 4. externalProxy JSON (как в external_proxy_fix) =====
EP="$(jq -nc --arg d "vpn.example.com" --argjson p 443 '[{"dest":$d,"port":$p,"remark":"xkit"}]')"
chk "ep json" "$(jq -r '.[0].dest' <<<"$EP")" "vpn.example.com"
chk "ep port" "$(jq -r '.[0].port' <<<"$EP")" 443
IB='{"id":5,"port":2083,"listen":"127.0.0.1","externalProxy":[{"dest":"127.0.0.1","port":2083,"remark":""}]}'
chk "ep patch" "$(jq -c --argjson ep "$EP" '.externalProxy = $ep' <<<"$IB" | jq -r '.externalProxy[0].port')" 443

# ===== 5. env round-trip с новыми ключами =====
XKIT_HOST="vpn.example.com"; XKIT_CRT="/tmp/c.pem"; XKIT_KEY="/tmp/k.pem"; XKIT_CERT_MODE="1"
XKIT_SUB_TOKEN="tok123"; XKIT_UFW=1; XKIT_PANEL_SUB_PORT=41234; XKIT_PANEL_SUB_PATH="/sub-tok123/"
XKIT_REALITY_INTERNAL=1; XKIT_BAL_STRATEGY="leastPing"; XKIT_POOL_INBOUND=7; XKIT_POOL_TAG="inbound-2083"
save_xkit_env >/dev/null
XKIT_HOST=""; XKIT_BAL_STRATEGY=""; XKIT_PANEL_SUB_PORT=""; XKIT_REALITY_INTERNAL="0"
load_xkit_env
chk "env host"        "$XKIT_HOST" "vpn.example.com"
chk "env sub port"    "$XKIT_PANEL_SUB_PORT" "41234"
chk "env sub path"    "$XKIT_PANEL_SUB_PATH" "/sub-tok123/"
chk "env reality int" "$XKIT_REALITY_INTERNAL" "1"
chk "env strategy"    "$XKIT_BAL_STRATEGY" "leastPing"
chk "env pool id"     "$XKIT_POOL_INBOUND" "7"
chk "env pool tag"    "$XKIT_POOL_TAG" "inbound-2083"
chk "env perms"       "$(stat -c %a "$XKIT_ENV")" "600"

# ===== 6. gen_xkit_conf: подписки панели + internal Reality-сервер =====
XKIT_HOST="vpn.example.com"
touch "$TD/c.pem" "$TD/k.pem"; XKIT_CRT="$TD/c.pem"; XKIT_KEY="$TD/k.pem"
PANEL_PORT="2095"; PANEL_WBP="/ab12cd/"; PANEL_SCHEME="http"
XKIT_PANEL_SUB_PORT=41234; XKIT_PANEL_SUB_PATH="/sub-tok123/"; XKIT_REALITY_INTERNAL=1
routes_upsert 11 local ws /xk-ws-2083/ 127.0.0.1:2083 "t1"
CONF_OUT="$(gen_xkit_conf)" && rc=$? || rc=$?
chki "gen conf rc" "$rc" 0
chkc "gen: подл. панели"  "$CONF_OUT" "127.0.0.1:41234"
chkc "gen: путь подписок" "$CONF_OUT" "/sub-tok123/"
chkc "gen: internal 8444" "$CONF_OUT" "listen 127.0.0.1:8444 ssl"
chkc "gen: camo root"     "$CONF_OUT" "/var/www/camo"
chkc "gen: ws маршрут"    "$CONF_OUT" "location /xk-ws-2083/"
chkn "gen: без X-Ray-тега" "$CONF_OUT" "vless://"

# а теперь выключаем флаги — блоков быть не должно
XKIT_PANEL_SUB_PORT=""; XKIT_REALITY_INTERNAL=0
CONF_OUT2="$(gen_xkit_conf)"
chkn "gen: без подписок панели" "$CONF_OUT2" "127.0.0.1:41234"
chkn "gen: без internal"        "$CONF_OUT2" "127.0.0.1:8444"

# ===== 7. camo_site_install =====
camo_site_install
chk "camo создан"      "$([ -s "$CAMO_DIR/index.html" ] && echo y)" y
chk "camo права"       "$(stat -c %a "$CAMO_DIR/index.html")" "644"
chkc "camo содержание" "$(cat "$CAMO_DIR/index.html")" "Coming soon"

# ===== 8. reality_known_pick / вспомогательные (без интерактива — только список) =====
chk "reality pbk extract" "$(reality_pbk '{"network":"tcp","security":"reality","realitySettings":{"settings":{"publicKey":"PBKX"}}}')" "PBKX"
chk "reality sid extract" "$(reality_sid '{"realitySettings":{"shortIds":["SID1"]}}')" "SID1"
chk "reality sni extract" "$(reality_sni '{"realitySettings":{"serverNames":["sni.example"]}}')" "sni.example"

# ===== 9. структура реестра нод после merge в node_add (tunnel/outbound_tag) =====
REC='{"name":"de1","host":"198.51.100.5","ssh_port":22,"ssh_user":"root","auth":"key","key_path":"/k"}'
REC2="$(jq -c --argjson tport 443 --arg uuid "U-U-I-D" --arg pbk "PBK" --arg sid "S1" \
        --arg sni "cloudflare-dns.com" --arg dest "1.1.1.1:443" --arg tag "node-de1" \
  '.tunnel = {port:$tport, uuid:$uuid, pbk:$pbk, sid:$sid, sni:$sni, dest:$dest, flow:"xtls-rprx-vision"}
   | .outbound_tag = $tag' <<<"$REC")"
chk "rec tunnel uuid" "$(jq -r '.tunnel.uuid' <<<"$REC2")" "U-U-I-D"
chk "rec outbound"    "$(jq -r '.outbound_tag' <<<"$REC2")" "node-de1"
chk "rec tunnel json valid" "$(jq -e . >/dev/null 2>&1 <<<"$REC2" && echo y)" y

# ===== 10. sub_path / нативные подписки: путь нормализуется =====
chk "normalize sub path" "$(normalize_panel_path "/sub-abc")" "/sub-abc/"
chk "normalize base"     "$(normalize_panel_path "xb/")" "/xb/"

rm -rf "$TD"
echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "V41 UNIT ALL PASSED" || { echo "V41 UNIT FAILED"; exit 1; }
