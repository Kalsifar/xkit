#!/bin/bash
# Юнит-тесты XKIT v4.0 (source без запуска меню)
set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/xkit.sh"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got: '$2', want: '$3')"; fi; }
chki() { if [ "$2" -eq "$3" ] 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got: $2, want: $3)"; fi; }
chkc() { if echo "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (нет строки: $3)"; fi; }

source "$SCRIPT" || { echo "source failed"; exit 1; }
chki "source не запустил main" 0 0

# временные пути состояния
TD=$(mktemp -d)
XKIT_ROUTES="$TD/routes.tsv"
XKIT_ENV="$TD/xkit.env"

# 1. Валидаторы
chk "is_domain ok"        "$(is_domain vpn.example.com && echo y)" y
chk "is_domain без точки" "$(is_domain example && echo y || echo n)" n
chk "is_domain подчёркив." "$(is_domain exa_mple.com && echo y || echo n)" n
chk "is_ipv4 ok"          "$(is_ipv4 203.0.113.10 && echo y)" y
chk "is_ipv4 256"         "$(is_ipv4 256.1.1.1 && echo y || echo n)" n
chk "is_ipv4 3 октета"    "$(is_ipv4 1.2.3 && echo y || echo n)" n
chk "is_ipv4 999"         "$(is_ipv4 999.1.1.1 && echo y || echo n)" n
chk "host_kind ip первым" "$(host_kind 1.2.3.4)" ip
chk "host_kind domain"    "$(host_kind vpn.example.com)" domain
chk "host_kind bad"       "$(host_kind foo!)" bad
chk "is_port 65535"       "$(is_port 65535 && echo y)" y
chk "is_port 65536"       "$(is_port 65536 && echo y || echo n)" n
chk "is_port 0"           "$(is_port 0 && echo y || echo n)" n
chk "is_path ok"          "$(is_path /xk-ws-2083/ && echo y)" y
chk "is_path без слэша"   "$(is_path abc && echo y || echo n)" n
chk "is_path двойной //"  "$(is_path /a//b/ && echo y || echo n)" n
chk "safe_conf_name ../"  "$(safe_conf_name ../etc && echo y || echo n)" n
chk "safe_conf_name домен" "$(safe_conf_name vpn.example.com && echo y)" y
chk "normalize abc"       "$(normalize_panel_path abc)" /abc/
chk "normalize /abc"      "$(normalize_panel_path /abc)" /abc/

# 2. Версии и случайности
chk "ver_ge 1.26.3>=1.25.1" "$(ver_ge 1.26.3 1.25.1 && echo y)" y
chk "ver_ge 1.24.0>=1.25.1" "$(ver_ge 1.24.0 1.25.1 && echo y || echo n)" n
chk "ver_ge 5.3>=5.3"       "$(ver_ge 5.3 5.3 && echo y)" y
chk "rand_str длина"        "$(rand_str 16 | tr -d 'a-zA-Z0-9' | wc -c)" 0
chk "rand_str 32 длина"     "$([ "$(rand_str 32 | wc -c)" = "32" ] && echo y)" y
chk "new_uuid формат"       "$(new_uuid | grep -qc '^[0-9a-f-]\{36\}$' && echo y)" y

# 3. Пути и теги
chk "auto_path ws"     "$(auto_path_for ws 2083)" /xk-ws-2083/
chk "auto_path grpc"   "$(auto_path_for gr 2099)" /xk-gr-2099/
chk "net_tag splithttp" "$(net_tag splithttp)" xh
chk "net_tag httpupgrade" "$(net_tag httpupgrade)" hu
chk "net_tag tcp"      "$(net_tag tcp)" tc

# 4. Классификация инбаундов
mkib() { jq -nc --arg proto "$1" --arg stream "$2" '{id:11, port:2083, protocol:$proto, tag:"t", enable:true, settings:"{\"clients\":[]}", streamSettings:$stream}'; }
S_WS='{"network":"ws","security":"tls","wsSettings":{"path":"/p/"}}'
S_REAL='{"network":"tcp","security":"reality","realitySettings":{"serverNames":["www.google.com"],"shortIds":["ab"],"settings":{"publicKey":"PBK"}}}'
S_RAW='{"network":"tcp","security":"none"}'
S_TCPH='{"network":"tcp","security":"tls","tcpSettings":{"header":{"type":"http","request":{"path":["/rp/"]}}}}'
S_KCP='{"network":"kcp","security":"none"}'
chk "classify ws+tls routed"  "$(classify_inbound "$(mkib vless "$S_WS")" | cut -d'|' -f3)" routed
chk "classify reality direct" "$(classify_inbound "$(mkib vless "$S_REAL")" | cut -d'|' -f3)" direct
chk "classify kcp direct"     "$(classify_inbound "$(mkib vmess "$S_KCP")" | cut -d'|' -f3)" direct
chk "classify raw tcp direct" "$(classify_inbound "$(mkib vless "$S_RAW")" | cut -d'|' -f3)" direct
chk "classify tcp+http routed" "$(classify_inbound "$(mkib vless "$S_TCPH")" | cut -d'|' -f3)" routed
chk "classify ss direct"      "$(classify_inbound "$(mkib shadowsocks "$S_WS")" | cut -d'|' -f3)" direct
chk "classify grpc trojan routed" "$(classify_inbound "$(mkib trojan '{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"svc"}}')" | cut -d'|' -f3)" routed
chk "classify reality причина" "$(classify_inbound "$(mkib vless "$S_REAL")" | cut -d'|' -f4 | grep -c Reality)" 1

# 5. inbound_path
chk "inbound_path ws"    "$(inbound_path "$(jq -nc --arg s "$S_WS" '{streamSettings:$s}' --argjson x null 2>/dev/null | jq -c --arg s "$S_WS" '{streamSettings:$s}')" ws)" /p/
chk "inbound_path grpc"  "$(inbound_path "$(jq -nc --arg s '{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"my-svc"}}' '{streamSettings:$s}')" grpc)" my-svc
chk "inbound_path tcp массив" "$(inbound_path "$(jq -nc --arg s "$S_TCPH" '{streamSettings:$s}')" tcp)" /rp/

# 6. routes.tsv
routes_upsert 11 local ws /xk-ws-2083/ 127.0.0.1:2083 "tag1"
routes_upsert 22 local grpc /xk-gr-2084/ 127.0.0.1:2084 "tag2"
routes_upsert 11 local ws /xk-ws-9999/ 127.0.0.1:9999 "tag1-new"
chki "upsert не дублирует" "$(wc -l < "$XKIT_ROUTES")" 2
chkc "upsert обновил строку" "$(cat "$XKIT_ROUTES")" "/xk-ws-9999/"
chk "route_info mode" "$(route_info 11 | cut -d'|' -f1)" local
chk "route_info path" "$(route_info 11 | cut -d'|' -f3)" /xk-ws-9999/
routes_del 11
chki "routes_del удалил" "$(wc -l < "$XKIT_ROUTES")" 1

# 7. Генерация конфига nginx (полный gen_xkit_conf)
XKIT_HOST="vpn.example.com"
SUBS_DIR="$TD/subs"
mkdir -p "$TD/ssl" "$TD/subs"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$TD/ssl/privkey.pem" -out "$TD/ssl/fullchain.pem" -days 30 -subj "/CN=vpn.example.com" 2>/dev/null
XKIT_CRT="$TD/ssl/fullchain.pem"; XKIT_KEY="$TD/ssl/privkey.pem"
PANEL_PORT=2090; PANEL_WBP="/abcd1234/"; PANEL_SCHEME=http
XKIT_SUB_TOKEN="tok123456"
routes_upsert 11 local ws    /xk-ws-2083/  127.0.0.1:2083 "wstag"
routes_upsert 22 local grpc  /xk-gr-2084/  127.0.0.1:2084 "grtag"
routes_upsert 33 local xhttp /xk-xh-2085/  127.0.0.1:2085 "xhtag"
routes_upsert 44 local tcp   /my-tc-path/  127.0.0.1:2086 "tctag"
routes_upsert m1 relay ws    /relay1/      localhost:8443 "relay"
CONF=$(gen_xkit_conf); rc=$?
chk "gen_xkit_conf rc" "$rc" 0
chkc "conf: listen 80"          "$CONF" "listen 80;"
chkc "conf: server_name"        "$CONF" "server_name vpn.example.com"
chkc "conf: ssl_certificate"    "$CONF" "ssl_certificate $TD/ssl/fullchain.pem"
chkc "conf: панель location"    "$CONF" "location /abcd1234/ {"
chkc "conf: панель proxy_pass"  "$CONF" "proxy_pass http://127.0.0.1:2090;"
chkc "conf: подписки location"  "$CONF" "location ^~ /s-tok123456/ {"
chkc "conf: подписки alias"     "$CONF" "alias $TD/subs/;"
chkc "conf: ws proxy_pass"      "$CONF" "proxy_pass http://127.0.0.1:2083;"
chkc "conf: ws upgrade-проверка" "$CONF" 'if ($http_upgrade != "websocket")'
chkc "conf: grpc_pass"          "$CONF" "grpc_pass grpc://127.0.0.1:2084;"
chkc "conf: grpc проверка content-type" "$CONF" 'if ($content_type !~ "application/grpc")'
chkc "conf: xhttp location"     "$CONF" "location /xk-xh-2085/ {"
chkc "conf: tcp блок"           "$CONF" "location /my-tc-path/ {"
chkc "conf: tcp без upgrade"    "$CONF" "TCP/HTTP-obfs"
chkc "conf: relay https"        "$CONF" "proxy_pass https://localhost:8443;"
chkc "conf: relay ssl_name"     "$CONF" "proxy_ssl_name localhost"
chk  "conf: нет literal \\n"    "$(echo "$CONF" | grep -cF '\\n')" 0
chk  "conf: один try_files в 443" "$(echo "$CONF" | grep -c 'try_files \$uri')" 1
chk  "conf: один return 301"    "$(echo "$CONF" | grep -c 'return 301')" 1
chk  "conf: заканчивается }"    "$(echo "$CONF" | tail -n1 | xargs)" "}"

# панель на / не должна создавать второй try_files-локейшн
PANEL_WBP="/"
CONF2=$(gen_xkit_conf 2>/dev/null)
chk "панель на /: один try_files" "$(echo "$CONF2" | grep -c 'try_files \$uri')" 1

# 8. Ссылки-шаринг
IB_WS='{"id":11,"port":2083,"protocol":"vless","tag":"wstag","enable":true,"settings":"{\"clients\":[{\"id\":\"11111111-2222-3333-4444-555555555555\",\"flow\":\"\",\"email\":\"alice\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"subalice12345678\",\"reset\":0}]}","streamSettings":"{\"network\":\"ws\",\"security\":\"tls\",\"wsSettings\":{\"path\":\"/xk-ws-2083/\"}}"}'
routes_upsert 11 local ws /xk-ws-2083/ 127.0.0.1:2083 "wstag"
CL=$(jq -c '.settings|fromjson|.clients[0]' <<<"$IB_WS")
L1=$(link_for_client "$IB_WS" "$CL")
chkc "vless схема"       "$L1" "vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?"
chkc "vless type=ws"     "$L1" "type=ws&security=tls"
chkc "vless path"        "$L1" "path=/xk-ws-2083/"
chkc "vless sni"         "$L1" "sni=vpn.example.com"
chkc "vless email"       "$L1" "#alice"

IB_REAL='{"id":22,"port":8443,"protocol":"vless","tag":"rtag","enable":true,"settings":"{\"clients\":[{\"id\":\"99999999-8888-7777-6666-555555555555\",\"flow\":\"xtls-rprx-vision\",\"email\":\"bob\",\"subId\":\"subbob1234567890\"}]}","streamSettings":"{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"serverNames\":[\"www.google.com\"],\"shortIds\":[\"ab12\"],\"settings\":{\"publicKey\":\"PBK123base64\"}}}"}'
routes_del 22
CL2=$(jq -c '.settings|fromjson|.clients[0]' <<<"$IB_REAL")
L2=$(link_for_client "$IB_REAL" "$CL2")
chkc "reality порт прямой"  "$L2" "@vpn.example.com:8443?"
chkc "reality security"     "$L2" "security=reality"
chkc "reality pbk"          "$L2" "pbk=PBK123base64"
chkc "reality sid"          "$L2" "sid=ab12"
chkc "reality sni"          "$L2" "sni=www.google.com"
chkc "reality flow"         "$L2" "flow=xtls-rprx-vision"

IB_VMESS='{"id":11,"port":2083,"protocol":"vmess","tag":"vtag","enable":true,"settings":"{\"clients\":[{\"id\":\"12121212-3434-5656-7878-909090909090\",\"email\":\"carol\",\"subId\":\"subcarol12345678\"}]}","streamSettings":"{\"network\":\"ws\",\"security\":\"tls\",\"wsSettings\":{\"path\":\"/xk-ws-2083/\"}}"}'
CL3=$(jq -c '.settings|fromjson|.clients[0]' <<<"$IB_VMESS")
L3=$(link_for_client "$IB_VMESS" "$CL3")
chkc "vmess префикс" "$L3" "vmess://"
VJ=$(printf '%s' "${L3#vmess://}" | base64 -d 2>/dev/null)
chk "vmess add"  "$(jq -r '.add' <<<"$VJ" 2>/dev/null)" vpn.example.com
chk "vmess port" "$(jq -r '.port' <<<"$VJ" 2>/dev/null)" 443
chk "vmess net"  "$(jq -r '.net' <<<"$VJ" 2>/dev/null)" ws
chk "vmess tls"  "$(jq -r '.tls' <<<"$VJ" 2>/dev/null)" tls
chk "vmess path" "$(jq -r '.path' <<<"$VJ" 2>/dev/null)" /xk-ws-2083/
chk "vmess id"   "$(jq -r '.id' <<<"$VJ" 2>/dev/null)" 12121212-3434-5656-7878-909090909090

IB_TROJ='{"id":33,"port":2085,"protocol":"trojan","tag":"ttag","enable":true,"settings":"{\"clients\":[{\"password\":\"trojpass123\",\"email\":\"dave\",\"subId\":\"subdave123456789\"}]}","streamSettings":"{\"network\":\"grpc\",\"security\":\"tls\",\"grpcSettings\":{\"serviceName\":\"xk-gr-2085\"}}"}'
routes_upsert 33 local grpc /xk-gr-2085/ 127.0.0.1:2085 "ttag"
CL4=$(jq -c '.settings|fromjson|.clients[0]' <<<"$IB_TROJ")
L4=$(link_for_client "$IB_TROJ" "$CL4")
chkc "trojan схема"     "$L4" "trojan://trojpass123@vpn.example.com:443?"
chkc "trojan serviceName" "$L4" "serviceName=xk-gr-2085"

# 9. TCP/HTTP блоки
B4=$(generate_location_block 4 /tc1/ 127.0.0.1:2086 true)
chkc "tcp блок заголовок"  "$B4" "TCP/HTTP-obfs"
chk "tcp блок БЕЗ upgrade" "$(echo "$B4" | grep -c 'websocket')" 0
chkc "tcp блок proxy_pass" "$B4" "proxy_pass http://127.0.0.1:2086;"
B2=$(generate_location_block 2 /ws1/ 127.0.0.1:2083 true)
chkc "ws блок upgrade"     "$B2" 'if ($http_upgrade != "websocket")'
chk "ws блок нет literal \\n" "$(echo "$B2" | grep -cF '\\n')" 0

# 10. env: сохранение/чтение
XKIT_HOST_SAVE="$XKIT_HOST"
XKIT_HOST="test.host"; XKIT_CRT="/c.pem"; XKIT_KEY="/k.pem"; XKIT_CERT_MODE="1"; XKIT_SUB_TOKEN="toksave"; XKIT_UFW=1
XKIT_ENV="$TD/xkit.env"
save_xkit_env >/dev/null
XKIT_HOST=""; XKIT_SUB_TOKEN=""
load_xkit_env
chk "env host"  "$XKIT_HOST" test.host
chk "env token" "$XKIT_SUB_TOKEN" toksave
XKIT_HOST="$XKIT_HOST_SAVE"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "UNIT ALL PASSED" || exit 1
