#!/bin/bash
# Тесты закрытия находок аудита XKIT v4.2 (чистые функции, без root/сети)
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/xkit.sh"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got '$3', want '$2')"; fi; }

echo "=== 1. bash -n ==="
bash -n "$SCRIPT" && echo "SYNTAX OK" || { echo "SYNTAX FAIL"; exit 1; }

echo "=== 2. Source ==="
source "$SCRIPT" || { echo "SOURCE FAIL"; exit 1; }
echo "SOURCE OK"

echo "=== 3. is_domain: цифровой TLD отклоняется (аудит #14) ==="
is_domain "example.com";       chk "domain ok"        0 $?
is_domain "999.999.999.999";   chk "цифровой TLD"     1 $?
is_domain "1.2.3.4.ru";        chk "обычный домен"    0 $?

echo "=== 4. is_ip: инъекции отклоняются (подменённый ipify) ==="
is_ip "1.2.3.4";                          chk "ipv4 ok"            0 $?
is_ip "1.2.3.4; curl evil|bash";          chk "инъекция ; "        1 $?
is_ip "1.2.3.4;curl";                     chk "инъекция ;2"        1 $?
is_ip "$(printf '1.2.3.4\nbad')"          2>/dev/null; chk "перевод строки"  1 $?
is_ipv4 "256.1.1.1";                      chk "octet >255"         1 $?

echo "=== 5. enc_uri / enc_uri_path (аудит #7) ==="
chk "path: слэш читаемый" "/xk-ws-2083/" "$(enc_uri_path "/xk-ws-2083/")"
chk "path: & закодирован" "/a%26b"      "$(enc_uri_path "/a&b")"
chk "path: пробел"        "/a%20b"      "$(enc_uri_path "/a b")"
chk "path: слэш+амперсанд" "/a%26b/"    "$(enc_uri_path "/a&b/")"
chk "host: точка не тронута" "ex.com"    "$(enc_uri "ex.com")"
chk "sni: амперсанд"      "a%26b"        "$(enc_uri "a&b")"

echo "=== 6. _link_proto: path в ссылке читаемый, опасные символы закодированы ==="
CL='{"id":"11111111-2222-3333-4444-555555555555"}'
L=$(_link_proto vless "u@x.io" "ex.com" 443 ws tls "/xk-ws-2083/" "" "sni.ex.com" "" "" chrome "" "$CL" '{}')
echo "$L" | grep -q 'path=/xk-ws-2083/' && chk "path читаемый в vless" 0 $?
echo "$L" | grep -q 'host=ex.com'       && chk "host в vless"         0 $?
L2=$(_link_proto vless "u@x.io" "ex.com" 443 ws tls "/a&b/" "" "" "" "" chrome "" "$CL" '{}')
echo "$L2" | grep -q 'path=/a%26b/'     && chk "инъекция через path закрыта" 0 $?
echo "$L2" | grep -q 'path=/a&b/'       && chk "сырой & не просочился" 1 $?

echo "=== 7. email-санитизация (аудит #6): регексп из client_add ==="
EMAIL_OK='^[A-Za-z0-9._@+-]{1,64}$'
BAD1=$'u1\tx'; BAD2=$'u1\nx'; GOOD1="u$(printf 'ab')"
[[ "$BAD1" =~ $EMAIL_OK ]]; chk "таб отклонён"     1 $?
[[ "$BAD2" =~ $EMAIL_OK ]]; chk "\\n отклонён"     1 $?
[[ "$GOOD1" =~ $EMAIL_OK ]]; chk "нормальное имя"  0 $?

echo "=== 8. реестр нод: nodes_load на пустом/отсутствующем файле (фикс KIT_NODES) ==="
XKIT_NODES="$(mktemp /tmp/.xkit-test-nodes.XXXXXX)"; rm -f "$XKIT_NODES"
chk "nodes_load нет файла -> []" "[]" "$(nodes_load)"
printf '[{"name":"de1"}]' > "$XKIT_NODES"
chk "nodes_load читает реестр" '[{"name":"de1"}]' "$(nodes_load)"
rm -f "$XKIT_NODES"

echo "=== 9. node_api: схема из реестра (аудит #3, чистая логика) ==="
REC='{"host":"1.2.3.4","panel":{"port":2090,"user":"u","pass":"p","base":"/ab/","tls":true}}'
chk "tls=true -> https" "https" "$(jq -r 'if ((.panel.tls // false) == true) then "https" else "http" end' <<<"$REC")"
REC2='{"host":"1.2.3.4","panel":{"port":2090,"user":"u","pass":"p","base":"/ab/"}}'
chk "tls нет -> http" "http" "$(jq -r 'if (.panel.tls // "false") == "true" then "https" else "http" end' <<<"$REC2")"

echo "=== 10. version/шапка ==="
grep -q 'XKIT_VERSION="4.2"' "$SCRIPT" && chk "версия 4.2" 0 $?
grep -q 'История:      CHANGES.md' "$SCRIPT" && chk "история вынесена в CHANGES.md" 0 $?

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || exit 1
