#!/bin/bash
# Тестовый харнесс v3 (актуальный API): валидаторы, urienc, generate_location_block,
# nginx_insert_block (guard'ы), cli_switch (path traversal), group-хелперы
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/nginx-xray-manager-v3.sh"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got '$3', want '$2')"; fi; }

echo "=== 1. bash -n ==="
bash -n "$SCRIPT" && echo "SYNTAX OK" || { echo "SYNTAX FAIL"; exit 1; }

echo "=== 2. Source ==="
source "$SCRIPT" || { echo "SOURCE FAIL"; exit 1; }
echo "SOURCE OK"

echo "=== 3. Валидаторы ==="
is_domain "rus.tunnel.ru";      chk "domain ok"          0 $?
is_domain "999.999.999.999";    chk "domain: цифровой TLD отклонён" 1 $?
is_domain "not_a_domain";       chk "domain: underscore отклонён"   1 $?
is_ipv4 "1.2.3.4";              chk "ipv4 ok"            0 $?
is_ipv4 "1.2.3.999";            chk "ipv4 999"           1 $?
is_ipv6 "::1";                  chk "ipv6 ok"            0 $?
is_port "443";                  chk "port ok"            0 $?
is_port "99999";                chk "port big"           1 $?
is_path "/grpc-1";              chk "path ok"            0 $?
is_path "/sub/";                chk "path trailing"      0 $?
host_kind "1.2.3.4";            chk "kind ip"            "ip" "$(host_kind 1.2.3.4)"
host_kind "example.com";        chk "kind domain"        "domain" "$(host_kind example.com)"
safe_name "de1";                chk "safe_name ok"       0 $?
safe_name "../etc";             chk "safe_name traversal" 1 $?
safe_name "a/b";                chk "safe_name slash"    1 $?
ver_ge "5.9.0" "5.3";           chk "ver_ge"             0 $?
ver_ge "5.1.0" "5.3";           chk "ver_ge ниже"        1 $?

echo "=== 4. urienc ==="
chk "urienc space" "%20"  "$(urienc " ")"
chk "urienc amp"   "%26"  "$(urienc "&")"
chk "urienc slash" "%2F"  "$(urienc "/")"
chk "urienc plain" "abc"  "$(urienc "abc")"

echo "=== 5. generate_location_block (transport-блоки) ==="
B=$(generate_location_block 1 /g 127.0.0.1:2055 true)
echo "$B" | grep -q 'grpc_pass grpc://127.0.0.1:2055';          chk "grpc local"          0 $?
echo "$B" | grep -qF '\n';                                      chk "no literal \\n"      1 $?
B2=$(generate_location_block 2 /w 127.0.0.1:2056 true)
echo "$B2" | grep -q 'proxy_pass http://127.0.0.1:2056';        chk "ws local"            0 $?

echo "=== 6. nginx_insert_block: guard'ы (аудит #10) ==="
TMPD=$(mktemp -d); CF="$TMPD/conf"
printf 'server {\n  listen 443 ssl;\n  # tail\n}\n' > "$CF"
nginx_insert_block "$CF" "  # inserted" && chk "insert ok" 0 $?
grep -q '# inserted' "$CF" && chk "insert применился" 0 $?
tail -n 1 "$CF" | grep -q '}' && chk "файл кончается на }" 0 $?
printf 'server {\n' > "$CF"                       # 1 строка — слишком короткий
nginx_insert_block "$CF" "  # x" 2>/dev/null;     chk "короткий файл отклонён"  1 $?
printf 'listen 80;\n' > "$CF"                     # не заканчивается на }
nginx_insert_block "$CF" "  # x" 2>/dev/null;     chk "без } отклонён"          1 $?
rm -rf "$TMPD"

echo "=== 7. cli_switch: path traversal закрыт (аудит #5) ==="
cli_switch "../../etc/evil" "" 2>/dev/null;       chk "traversal группа отклонён"  1 $?
cli_switch "ok_but_absent"  "../evil" 2>/dev/null; chk "traversal нода отклонён"   1 $?

echo "=== 8. group-хелперы ==="
XMESH_GROUPS_DIR="$(mktemp -d)/groups"   # не пишем в /etc/xmesh без root
chk "group_file формат" "$XMESH_GROUPS_DIR/de.json" "$(group_file de)"
mkdir -p "$XMESH_GROUPS_DIR"
printf 'de-1\n' | read_name "x: " >/dev/null 2>&1; chk "read_name работает" 0 $?

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || exit 1
