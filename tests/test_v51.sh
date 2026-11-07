#!/bin/bash
# Тесты XKIT v5.1.0 (security-релиз: аудит №1 подтверждённые + аудит №2 P0/P1):
#  1) версия/синтаксис/changelog
#  2) K-01: is_nginx_path, parse_hostport (включая F-3 IPv6), отказ генераторов
#     на мусорных пути/таргете, is_port для PANEL_PORT (статика)
#  3) K-02: fail-closed в install.sh/xkit update/докачке меню; http:// наружу
#     запрещён (localhost — можно); pin-хэши в install.sh; 3X-UI по тегу
#  4) V-01: валидация токенов в reality_expand_targets; TARGETS уходит base64
#  5) V-02: xkit_dir_trusted (owner/mode, /tmp — запрет); меню из /tmp не грузится
#  6) V-03: секреты вне argv (статика) + openssl passwd -stdin
#  7) V-05: node_ssh_host_key до коннекта (статика)
#  8) V-06: tar-члены/symlink/YES при чужом бэкапе (статика)
#  9) S-03: sshd -T; S-04: 750/640 в v3; V-04: mktemp в v3
# 10) №1: смешанный stale data.json НЕ теряет пользователей (функциональный)
# 11) №7/N-04: is_ipv6 без python3 через getent (функциональный)
# 12) мелочи: №2 №3 №4 №9 №12 №15 №18 №19 №22 №23 №24, F-1/F-2 (статика)
# 13) пломба: 5 строк (v5.2.0 расширяет security-релиз новыми компонентами)
set -u
umask 022   # детерминизм: без этого 002 даёт group-write и V-02-гейт честно отсекает
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}
no() { # строка НЕ должна встречаться (поддержка формы "FILE -- PAT")
  local f="$1" p="$2"
  [ "$p" = "--" ] && p="$3"
  if rg -q "$p" "$f" 2>/dev/null; then return 1; else return 0; fi
}
yes() { rg -q "${3:-$2}" "$1" 2>/dev/null; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${SCRIPT_DIR%/tests}"
XKIT="${BASE}/xkit.sh"; XMENU="${BASE}/xkit_menu.sh"
INSTALL="${BASE}/install.sh"; V3="${BASE}/nginx-xray-manager-v3.sh"
SUMF="${BASE}/xkit.sh.sha256"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия, синтаксис, changelog ==="
yes "$XKIT" 'XKIT_VERSION="5\.[0-9]+\.[0-9]+"'; ck "версия 5.x.y (бамп-safe)" $?
yes "$XKIT" 'История:      CHANGES\.md'; ck "история вынесена в CHANGES.md" $?
bash -n "$XKIT" && bash -n "$XMENU" && bash -n "$INSTALL" && bash -n "$V3"
ck "bash -n всех четырёх файлов" $?

echo "=== 2. K-01: валидаторы и генераторы ==="
out="$(bash -c 'source "$1" 2>/dev/null
is_nginx_path "/Abc.123-x_y/v2" && echo A
is_nginx_path "/a//b" && echo B
is_nginx_path "/a/../etc" && echo C
is_nginx_path "/~x" && echo D
is_nginx_path "/loc* {alias /etc;}" && echo E
is_nginx_path "nopath" && echo F' _ "$XKIT" 2>/dev/null)"
[ "$out" = "A" ]; ck "is_nginx_path: разрешает безопасное, режет // .. ~ * и голый путь" $?
out="$(bash -c 'source "$1" 2>/dev/null
parse_hostport "1.2.3.4:2097" && echo "$R_HOST|$R_PORT"
parse_hostport "[2001:db8::1]:443" && echo "$R_HOST|$R_PORT"
parse_hostport "example.com:443" && echo "$R_HOST|$R_PORT"
parse_hostport "[2001:db8::1]:443" >/dev/null 2>&1 && echo "V6OK:$R_HOST"
parse_hostport "2001:db8::1:443" 2>/dev/null && echo BAD1
parse_hostport "1.2.3.4:99999" 2>/dev/null && echo BAD2
parse_hostport "x y:80" 2>/dev/null && echo BAD3' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q '^1\.2\.3\.4\|2097$' ; ck "parse_hostport: ipv4:port" $?
echo "$out" | rg -q '^2001:db8::1\|443$'; ck "parse_hostport: [v6]:port — F-3 закрыт" $?
echo "$out" | rg -q '^example\.com\|443$'; ck "parse_hostport: домен:порт" $?
echo "$out" | rg -q '^BAD' && _r=1 || _r=0; [ "$_r" = "0" ]
ck "parse_hostport: голый v6/плохой порт/пробел — отказ" $?
out="$(bash -c 'source "$1" 2>/dev/null
generate_location_block 2 "/leak { alias /etc/; }" "127.0.0.1:2097" true; echo "rc=$?"' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'rc=1'; ck "K-01: location-блок с инъекцией в path — отказ" $?
out="$(bash -c 'source "$1" 2>/dev/null
generate_location_block 2 "/ok" "1.2.3.4\x27; id; \x27" true; echo "rc=$?"' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'rc=1'; ck "K-01: таргет с кавычкой — отказ" $?
out="$(bash -c 'source "$1" 2>/dev/null
generate_location_block 2 "/ws-path" "127.0.0.1:2097" true' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'location /ws-path \{'; ck "K-01: нормальный блок генерируется" $?
echo "$out" | no /dev/stdin 'alias /etc'; ck "K-01: в нормальном блоке нет alias-мусора" $?
out="$(bash -c 'source "$1" 2>/dev/null
generate_web_proxy_block "Панель" "/\n}\nlocation /leak { alias /var/lib/xkit/; }\n#" "127.0.0.1:2097" http; echo "rc=$?"' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'rc=1'; ck "K-01: web-блок с \\\\n-инъекцией в webBasePath — отказ" $?
yes "$XKIT" 'is_port "\$PANEL_PORT"'; ck "K-01: PANEL_PORT проверяется is_port" $?
yes "$XKIT" 'is_nginx_path "\$PANEL_WBP"'; ck "K-01: webBasePath проверяется" $?
yes "$XKIT" 'путь tcp\+http нестандартный'; ck "K-01: tcp+http путь — отказ маршрута" $?

echo "=== 3. K-02: supply chain fail-closed ==="
yes "$INSTALL" 'XKIT_PIN_SHA256="'; ck "install.sh: pin-хэш присутствует" $?
no  "$INSTALL" '^XKIT_PIN_SHA256="@@'; ck "install.sh: pin xkit.sh заполнен при сборке" $?
no  "$INSTALL" '^XKIT_PIN_MENU_SHA256="@@'; ck "install.sh: menu-pin заполнен при сборке" $?
yes "$INSTALL" 'K-02: http://-источники запрещены'; ck "install.sh: http:// наружу запрещен" $?
yes "$INSTALL" 'http://127\.0\.0\.1\*'; ck "install.sh: localhost-зеркала разрешены (тесты)" $?
yes "$INSTALL" 'XKIT_ALLOW_UNVERIFIED'; ck "install.sh: осознанный обход существует" $?
yes "$XKIT" 'K-02: обновление по http:// запрещено'; ck "update: http:// наружу запрещен" $?
yes "$XKIT" 'K-02: без суммы код не ставится'; ck "update: без пломбы — отказ" $?
yes "$XKIT" 'В пломбе нет строки xkit_menu.sh — докачка отменена'; ck "докачка меню: без суммы — отказ" $?
yes "$XKIT" 'xui_install_url\(\)'; ck "K-02: установщик 3X-UI по тегу (мастер)" $?
yes "$XKIT" 'releases/latest'; ck "K-02: тег берется из GitHub releases" $?
yes "$V3" 'релиз \$\{tag\} \(не master'; ck "K-02: v3 тоже качает по тегу" $?
no  "$XKIT" 'raw\.githubusercontent\.com/mhsanaei/3x-ui/master/install\.sh -o "\$DL"'; ck "K-02: нода больше не качает master напрямую" $?

echo "=== 4. V-01: TARGETS ==="
out="$(bash -c 'source "$1" 2>/dev/null; reality_expand_targets "1.1.1.1\x27; id; echo \x27"' _ "$XKIT" 2>/dev/null)"
[ "$out" = "ERR:bad-target" ]; ck "V-01: кавычка в таргете -> ERR:bad-target" $?
out="$(bash -c 'source "$1" 2>/dev/null; reality_expand_targets "8.8.8.8 example.com" 2>/dev/null; reality_expand_targets "10.0.0.0/30" 2>/dev/null' _ "$XKIT" 2>/dev/null)"
n="$(echo "$out" | grep -c .)"; [ "$n" -ge 3 ] && ! echo "$out" | rg -q 'ERR:'; ck "V-01: IP/домен/CIDR проходят" $?
yes "$XKIT" 'TARGETS_B64'; ck "V-01: список уходит base64 (вне shell-строки)" $?
no  "$XKIT" "env TARGETS='"; ck "V-01: старая shell-строка исчезла" $?

echo "=== 5. V-02: доверие каталогов ==="
out="$(bash -c 'source "$1" 2>/dev/null
mkdir -p "'"$T"'/d" && printf "#!/bin/bash\n" > "'"$T"'/d/xkit_menu.sh"
xkit_dir_trusted "'"$T"'/d" "'"$T"'/d/xkit_menu.sh" && echo TRUST1
chmod 777 "'"$T"'/d"
xkit_dir_trusted "'"$T"'/d" "'"$T"'/d/xkit_menu.sh" || echo NOTRUST1
xkit_dir_trusted "/tmp" "/tmp/nothing" || echo NOTRUST2' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'TRUST1' && echo "$out" | rg -q 'NOTRUST1' && echo "$out" | rg -q 'NOTRUST2'
ck "V-02: root-каталог доверенный; 777 и /tmp — нет" $?
mkdir -p "$T/tmpmenu" && chmod 777 "$T/tmpmenu" && printf 'pwn() { echo PWNED; }\n' > "$T/tmpmenu/xkit_menu.sh"
out="$(bash -c 'source "$1" 2>/dev/null; xkit_menu_src' _ "$XKIT" 2>/dev/null)"
! echo "$out" | rg -q "$T/tmpmenu"; ck "V-02: меню из world-writable каталога не выбирается" $?

echo "=== 6. V-03: секреты вне argv ==="
no  "$XKIT" '--data-urlencode "password='; ck "логин панели: пароль не в argv" $?
yes "$XKIT" 'application/x-www-form-urlencoded. --data @-'; ck "логин панели: тело через stdin" $?
no  "$XKIT" 'a\+=\(-H .Content-Type: application/json. -d "\$body"\)'; ck "node_api: тело не в argv" $?
yes "$XKIT" 'openssl passwd -apr1 -stdin'; ck "htpasswd: пароль через stdin" $?
yes "$XKIT" 'nodes_file="\$\(mktemp /tmp/\.xkit-nodes'; ck "nodes.json -> tmpfile 600" $?
yes "$V3" -- 'username=%s&password=%s'; ck "v3 panel_login: тело через stdin" $?
yes "$V3" 'panel/api.*--data @-|Content-Type: application/json. --data @-'; ck "v3 panel_call: тело через stdin" $?
no  "$V3" '--data-urlencode "password='; ck "v3: пароль не в argv" $?

echo "=== 7. V-05: SSH TOFU ==="
yes "$XKIT" 'node_ssh_host_key\(\)'; ck "node_ssh_host_key определен" $?
bash -c '
  f="$1"
  a=$(grep -n "node_ssh_host_key \"\$host\"" "$f" | head -n1 | cut -d: -f1)
  b=$(grep -n "SSHPASS=\"\$NODE_SSH_PASS\"" "$f" | head -n1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
' _ "$XKIT"; ck "V-05: отпечаток подтверждается ДО отправки пароля" $?
yes "$V3" 'v3_ssh_host_key\(\)'; ck "v3: TOFU-хелпер есть" $?
bash -c '
  f="$1"
  a=$(grep -n "v3_ssh_host_key \"\$host\"" "$f" | head -n1 | cut -d: -f1)
  b=$(grep -n "SSHPASS=\"\$pw\"" "$f" | head -n1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
' _ "$V3"; ck "v3: ssh_deploy_key — подтверждение до пароля" $?

echo "=== 8. V-06: восстановление бэкапа ==="
yes "$XKIT" 'Архив содержит небезопасные пути'; ck "V-06: ../ и абсолютные пути отсекаются" $?
yes "$XKIT" 'Архив содержит symlink наружу'; ck "V-06: symlink наружу отсекается" $?
yes "$XKIT" 'xkit.env в архиве содержит командную подстановку'; ck "V-06: env с \$() не исполняется" $?
yes "$XKIT" 'Чужой бэкап может выполнить команды от root'; ck "V-06: чужой архив — только через YES" $?

echo "=== 9. S-03/S-04/V-04 ==="
yes "$XKIT" 'sshd -T'; ck "S-03: порт SSH из sshd -T" $?
yes "$XKIT" 'UFW НЕ включаю \(риск заблокировать себя\)'; ck "S-03: не определили порт — UFW не включаем" $?
yes "$V3" 'chmod 750 "\$XMESH_SUBS_DIR"'; ck "S-04: каталог подписок 750" $?
yes "$V3" 'chmod 640 "\$\{XMESH_SUBS_DIR\}/\$\{token\}"'; ck "S-04: файлы подписок 640" $?
no  "$V3" '/tmp/\.xmesh_nginx_t'; ck "V-04: фиксированный /tmp-путь исчез" $?
yes "$V3" 'mktemp /tmp/\.xmesh-nginx-t'; ck "V-04: mktemp вместо фиксированного пути" $?

echo "=== 10. №1: смешанный stale data.json ==="
out="$(bash -c '
source "$1" 2>/dev/null
XKIT_HOST="test.local"
kit_session(){ return 1; }
nodes_load(){ printf "[]"; }
dash_master_json(){ printf "{}"; }
expiry_get(){ :; }
expiry_note(){ :; }
export XKIT_DASH_DIR="'"$T"'/dash" XKIT_NODES_METRICS="'"$T"'/nodes-metrics.json"
mkdir -p "$XKIT_DASH_DIR"
# фикстура собирается самим jq — без shell-экранирования
jq -n "{inbounds:[
  {listen:\"127.0.0.1\",port:2097,protocol:\"vless\",tag:\"tagA\",
   settings:({clients:[{email:\"a@x\",enable:true}]}|tostring),
   streamSettings:({network:\"ws\"}|tostring),
   clientStats:([{email:\"a@x\",up:10,down:20}]|tostring)},
  {port:2098,protocol:\"vless\",tag:\"tagB\",up:5,down:5,enable:true}
],users:[{email:\"a@x\",ib:\"tagA\",up:1,down:2,total:3},
         {email:\"b@x\",ib:\"tagB\",up:5,down:5,total:10}]}" > "$XKIT_DASH_DIR/data.json"
dash_gen_locked >/dev/null 2>&1
jq -r "[.users[].email] | join(\",\")" "$XKIT_DASH_DIR/data.json" 2>/dev/null
' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'a@x' && echo "$out" | rg -q 'b@x'
ck "№1: users из raw И sanitized элементов (a@x + b@x)" $?

echo "=== 11. №7/N-04: is_ipv6 без python3 ==="
BIN="$T/bin"; mkdir -p "$BIN"
# зеркало всех бинарей КРОМЕ python* (симуляция сервера без python3)
for d in /usr/bin /bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    case "$b" in python*) ;; *) [ -e "$BIN/$b" ] || ln -sf "$f" "$BIN/$b" 2>/dev/null ;; esac
  done
done
out="$(env PATH="$BIN" bash -c '
source "$1" 2>/dev/null
is_ipv6 "::1" && echo V1
is_ipv6 "2001:db8::1" && echo V2
is_ipv6 ":::" || echo I1
is_ipv6 "1234:" || echo I2
is_ipv6 "1:2:3:4:5:6:7:8:9" || echo I3
is_ipv6 "fe80::1%eth0" || echo I4
' _ "$XKIT" 2>/dev/null)"
echo "$out" | rg -q 'V1' && echo "$out" | rg -q 'V2' \
  && echo "$out" | rg -q 'I1' && echo "$out" | rg -q 'I2' \
  && echo "$out" | rg -q 'I3' && echo "$out" | rg -q 'I4'
ck "is_ipv6 без python3 (getent): валидные/мусор/зона" $?

echo "=== 12. Мелочи аудита №1 + F-1/F-2 ==="
yes "$XKIT" 'api_del_inbound "\$id" 2>/dev/null'; ck "№2: pool_remove_force через api_del_inbound" $?
yes "$XKIT" 'hosts/list: нестандартный ответ панели'; ck "№18: warn при нестандартном hosts/list" $?
yes "$XKIT" 'dirname -- "\$\{XKIT_BIN:-/usr/local/bin/xkit\}"'; ck "№19: dirname вместо %/*" $?
yes "$XKIT" '№22: фолбэк ДО чтения env'; ck "№22: ранний фолбэк XKIT_REPO_URL" $?
yes "$XKIT" '\[::ffff:127\\\.0\\\.0\\\.1\\\]'; ck "№24: ::ffff:127.0.0.1 исключен" $?
yes "$XKIT" 'ротация отменена, ничего не изменено'; ck "№4: ротация без бэкапа — отмена" $?
yes "$XKIT" 'unique_by\(\(\.email // "\?"\)\+"\\u0000"'; ck "№1: дедуп users при склейке" $?
yes "$V3" 'ACTIVE_\$\{g\}=\$\{active\} не найдена в реестре'; ck "№3: ACTIVE на удалённой ноде -> block + warn" $?
yes "$V3" 'xmesh@\.service\.bak\.\$\(date'; ck "№23: бэкап юнита перед перезаписью" $?
yes "$V3" 'Архив содержит symlink наружу'; ck "№15: symlink-члены tar в v3" $?
yes "$XKIT" 'rc=1$'; ck "F-1: явный rc=1 при неудаче установки меню" $?
yes "$XKIT" 'Не удалось скопировать модуль меню'; ck "F-2: cp без ветки неудачи больше не маскируется" $?
yes "$XKIT" 'TG-токен в env невалиден'; ck "№9: TG-токен из env валидируется" $?
yes "$XKIT" 'tonumber\? // 0'; ck "№12: tonumber в client_list" $?

echo "=== 13. Пломба ==="
[ "$(wc -l < "$SUMF" 2>/dev/null | tr -d ' ')" = "5" ] \
  && [ "$(awk 'NR==1{print $2}' "$SUMF" 2>/dev/null)" = "xkit.sh" ] \
  && [ "$(awk 'NR==2{print $2}' "$SUMF" 2>/dev/null)" = "xkit_menu.sh" ] \
  && [ "$(awk 'NR==3{print $2}' "$SUMF" 2>/dev/null)" = "xkit_protocols.sh" ] \
  && [ "$(awk 'NR==4{print $2}' "$SUMF" 2>/dev/null)" = "xkit-tui-linux-amd64" ] \
  && [ "$(awk 'NR==5{print $2}' "$SUMF" 2>/dev/null)" = "xkit-tui-linux-arm64" ]
ck "пломба: 5 строк (ядро + меню + протоколы + оба TUI)" $?
w="$(awk 'NR==1{print $1}' "$SUMF")"; g="$(sha256sum "$XKIT" | awk '{print $1}')"
[ "$w" = "$g" ]; ck "пломба строка 1 = xkit.sh" $?
w="$(awk 'NR==2{print $1}' "$SUMF")"; g="$(sha256sum "$XMENU" | awk '{print $1}')"
[ "$w" = "$g" ]; ck "пломба строка 2 = xkit_menu.sh" $?

echo ""
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
