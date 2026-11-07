#!/bin/bash
# Тесты XKIT v4.6.0 (аудит №5 + А1-А3):
#  1) версия/синтаксис всех трёх скриптов
#  2) bash -c инъекции: безопасный паттерн во всех /dev/tcp-пробах (xkit + v3),
#     поведенческая проверка: connect работает, инъекция блокируется
#  3) поведение: rand_str, is_ipv6 (inet_pton), nodes_load (битый JSON),
#     notify_disk_verdict, notify_svc_trans, notify_state (ключи с «.»),
#     xui_env_val (БЕЗ source), v6_listen_enabled + build_h2_block v6
#  4) статика: nodes_health ssh_fails, api_del_inbound в ensure_pool, flock
#     в sub_regen, dash_rotate htbk, node_own_key chmod 700, sshuser-regex,
#     read_panel_settings без source, python3 в зависимостях, IPv6-listen,
#     алерты сервисов/диска, install.sh
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${SCRIPT_DIR%/tests}"
XKIT="${BASE}/xkit.sh"
V3="${BASE}/nginx-xray-manager-v3.sh"
INST="${BASE}/install.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
[ -f "$V3" ]   || V3="${SCRIPT_DIR%/tests}/nginx-xray-manager-v3.sh"
[ -f "$INST" ] || INST="${SCRIPT_DIR%/tests}/install.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия и синтаксис ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
rg -q 'XRAY MESH MANAGER  v3\.2' "$V3"; ck "v3: версия 3.2" $?
rg -q 'ИЗМЕНЕНИЯ v3\.2' "$V3"; ck "v3: changelog 3.2" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?
bash -n "$V3" 2>/dev/null; ck "bash -n v3" $?
bash -n "$INST" 2>/dev/null; ck "bash -n install.sh" $?

echo "=== 2. bash -c инъекции (аудит №1) ==="
[ "$(grep -c 'bash -c "exec 3<>/dev/tcp' "$XKIT")" = "0" ]; ck "xkit: нет интерполяции в dev/tcp" $?
[ "$(grep -c "bash -c 'exec 3<>/dev/tcp/" "$XKIT")" = "5" ]; ck "xkit: 5 безопасных проб" $?
[ "$(grep -c 'bash -c "exec 3<>/dev/tcp' "$V3")" = "0" ]; ck "v3: нет интерполяции в dev/tcp" $?
[ "$(grep -c "bash -c 'exec 3<>/dev/tcp/" "$V3")" = "2" ]; ck "v3: 2 безопасные пробы" $?

# поведенчески: connect на живой порт проходит, инъекция не выполняется
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' &
import socket, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 45679)); s.listen(8)
def acc():
    for _ in range(8):
        try:
            c, _ = s.accept(); c.close()
        except OSError:
            break
threading.Thread(target=acc, daemon=True).start()
time.sleep(8)
PY
  LPID=$!
  sleep 0.5
  if timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ 127.0.0.1 45679 2>/dev/null; then
    ck "безопасный паттерн: connect проходит" 0
  else
    ck "безопасный паттерн: connect проходит" 1
  fi
  rm -f "$T/pwn"
  if timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "127.0.0.1; touch $T/pwn" 45679 2>/dev/null; then
    ck "безопасный паттерн: инъекция не выполняется" 1
  else
    [ -f "$T/pwn" ] && ck "безопасный паттерн: инъекция не выполняется" 1 || ck "безопасный паттерн: инъекция не выполняется" 0
  fi
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
else
  ck "безопасный паттерн: connect проходит (python3 нет — пропуск)" 0
  ck "безопасный паттерн: инъекция не выполняется (пропуск)" 0
fi

echo "=== 3. Поведение изменённых функций ==="
(
  source "$XKIT"
  XKIT_DIR="$T"; XKIT_NOTIFY_STATE="$T/notify.state"; XKIT_NODES="$T/nodes.json"

  rp=0; rfail=0
  for n in 1 8 24 64 127; do
    s="$(rand_str "$n")"
    [ "${#s}" = "$n" ] && rp=$((rp+1)) || { rfail=$((rfail+1)); echo "FAIL_RAND len $n -> ${#s}"; }
  done
  s="$(rand_str 40)"
  [[ "$s" =~ ^[a-zA-Z0-9]+$ ]] && rp=$((rp+1)) || { rfail=$((rfail+1)); echo "FAIL_RAND charset"; }
  echo "RAND_PASS=$rp"; echo "RAND_FAIL=$rfail"

  ip6p=0; ip6f=0
  i6() { local exp="$1" x="$2"; if [ "$(is_ipv6 "$x" && echo t || echo f)" = "$exp" ]; then ip6p=$((ip6p+1)); else ip6f=$((ip6f+1)); echo "FAIL_IP6 $x != $exp"; fi; }
  i6 t "::";        i6 t "::1";       i6 t "2001:db8::1"
  i6 f "a::b::c";   i6 f "1234:";     i6 f "abc";       i6 f "1.2.3.4"; i6 f ":"
  echo "IP6_PASS=$ip6p"; echo "IP6_FAIL=$ip6f"

  nlp=0; nlf=0
  echo '{"broken' > "$XKIT_NODES"
  [ "$(nodes_load 2>/dev/null)" = "[]" ] && nlp=$((nlp+1)) || { nlf=$((nlf+1)); echo "FAIL_NL broken"; }
  echo 'null' > "$XKIT_NODES"
  [ "$(nodes_load 2>/dev/null)" = "[]" ] && nlp=$((nlp+1)) || { nlf=$((nlf+1)); echo "FAIL_NL null"; }
  echo '[{"name":"de1"}]' > "$XKIT_NODES"
  [ "$(nodes_load 2>/dev/null)" = '[{"name":"de1"}]' ] && nlp=$((nlp+1)) || { nlf=$((nlf+1)); echo "FAIL_NL valid"; }
  echo "NL_PASS=$nlp"; echo "NL_FAIL=$nlf"

  dp=0; dfail=0
  dv() { local exp="$1" p="$2" got; got="$(notify_disk_verdict "$p"; echo x)"; [ "$got" = "${exp}x" ] && dp=$((dp+1)) || { dfail=$((dfail+1)); echo "FAIL_DISK $p -> $got"; }; }
  dv 95 99; dv 95 95; dv 85 90; dv 85 85; dv "" 84; dv "" ""; dv "" abc; dv "" -5
  echo "DISK_PASS=$dp"; echo "DISK_FAIL=$dfail"

  sp=0; sfail=0
  sv() { local exp="$1" o="$2" n="$3"; local out; out="$(notify_svc_trans "$o" "$n")"; [ "${out%%$'\t'*}|${out#*$'\t'}" = "$exp" ] && sp=$((sp+1)) || { sfail=$((sfail+1)); echo "FAIL_SVC $o->$n"; }; }
  sv "down|НЕ работает — проверьте systemctl status" "" down
  sv "down|НЕ работает — проверьте systemctl status" up down
  sv "down|" down down
  sv "up|снова работает" down up
  sv "up|" "" up
  sv "up|" up up
  echo "SVC_PASS=$sp"; echo "SVC_FAIL=$sfail"

  stp=0; stf=0
  notify_state_set "a.b" "1"; notify_state_set "axb" "2"
  [ "$(notify_state_get "axb")" = "2" ] && stp=$((stp+1)) || { stf=$((stf+1)); echo "FAIL_ST dot-set"; }
  notify_state_set "a.b" ""
  [ -z "$(notify_state_get "a.b")" ] && stp=$((stp+1)) || { stf=$((stf+1)); echo "FAIL_ST dot-del"; }
  [ "$(notify_state_get "axb")" = "2" ] && stp=$((stp+1)) || { stf=$((stf+1)); echo "FAIL_ST dot-collateral"; }
  echo "ST_PASS=$stp"; echo "ST_FAIL=$stf"

  xp=0; xf=0
  printf 'XUI_PANEL_PORT="54321"\nXUI_WEB_BASE_PATH=/abc/\nXUI_USERNAME=adm\nXUI_PASSWORD=p s"q\nEVIL=1; touch %s/evil\n' "$T" > "$T/ires.env"
  [ "$(xui_env_val XUI_PANEL_PORT "$T/ires.env")" = "54321" ] && xp=$((xp+1)) || { xf=$((xf+1)); echo "FAIL_XUI port"; }
  [ "$(xui_env_val XUI_WEB_BASE_PATH "$T/ires.env")" = "/abc/" ] && xp=$((xp+1)) || { xf=$((xf+1)); echo "FAIL_XUI wbp"; }
  [ "$(xui_env_val XUI_PASSWORD "$T/ires.env")" = 'p s"q' ] && xp=$((xp+1)) || { xf=$((xf+1)); echo "FAIL_XUI pass"; }
  [ -f "$T/evil" ] && { xf=$((xf+1)); echo "FAIL_XUI source-effect!"; } || xp=$((xp+1))
  echo "XUI_PASS=$xp"; echo "XUI_FAIL=$xf"

  vp=0; vf=0
  XKIT_V6_LISTEN=1; v6_listen_enabled && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 force1"; }
  XKIT_V6_LISTEN=0; v6_listen_enabled && { vf=$((vf+1)); echo "FAIL_V6 force0"; } || vp=$((vp+1))
  XKIT_V6_LISTEN=auto
  # ревью v4.6: двоеточие в [::]:443 обязательно — без него nginx -t падает
  # (invalid parameter). nginx_ver в песочке пуст -> безопасный старый синтаксис
  build_h2_block v6 | grep -q 'listen \[::\]:443 ssl http2;' && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 h2block old v6"; }
  # новый синтаксис (мок версии >= 1.25.1): «http2 on;» ТОЛЬКО в v4-строке,
  # v6-вызов добавляет лишь второй listen — дубль = duplicate directive
  nginx_ver() { printf '1.26.3'; }
  [ "$(build_h2_block)" = "    listen 443 ssl;
    http2 on;" ] && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 h2block new v4"; }
  [ "$(build_h2_block v6)" = "    listen [::]:443 ssl;" ] && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 h2block new v6"; }
  unset -f nginx_ver
  # полная генерация с принудительным v6: [::]:443 + [::]:80, ни одного
  # «[::] без порта», http2 on; не дублится, конфиг вообще собрался
  export XKIT_HOST="v6t.example.com" XKIT_CRT="$T/c.pem" XKIT_KEY="$T/k.pem" XKIT_V6_LISTEN=1
  export SUBS_DIR="$T/subs" XKIT_ROUTES="$T/routes.tsv"; : > "$XKIT_ROUTES"
  conf="$(gen_xkit_conf 2>/dev/null)"
  echo "$conf" | grep -q 'listen \[::\]:443' && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 gen 443"; }
  echo "$conf" | grep -q 'listen \[::\]:80;' && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 gen 80"; }
  echo "$conf" | grep -qE 'listen \[::\] [0-9]+' && { vf=$((vf+1)); echo "FAIL_V6 gen colon bug"; } || vp=$((vp+1))
  [ "$(echo "$conf" | grep -c 'http2 on;')" -le 1 ] && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 gen http2 dup"; }
  [ "$(echo "$conf" | grep -c 'server_name v6t.example.com')" -ge 1 ] && vp=$((vp+1)) || { vf=$((vf+1)); echo "FAIL_V6 gen built"; }
  echo "V6_PASS=$vp"; echo "V6_FAIL=$vf"
) 2>/dev/null > "$T/behav.txt"
grep -E '^FAIL_' "$T/behav.txt" | sed 's/^/  [FAIL] /'
for pair in RAND:6 IP6:8 NL:3 DISK:8 SVC:6 ST:3 XUI:4 V6:10; do
  name="${pair%%:*}"; want="${pair##*:}"
  p="$(sed -n "s/^${name}_PASS=//p" "$T/behav.txt")"; f="$(sed -n "s/^${name}_FAIL=//p" "$T/behav.txt")"
  [ "${f:-1}" = "0" ] && [ "${p:-0}" = "$want" ]; ck "${name}: ${want} проверок" $?
done

echo "=== 4. Статика: фиксы аудита ==="
rg -q 'ssh_fails=0' "$XKIT" && rg -q 'ssh_fails=\$\(\(ssh_fails\+1\)\)' "$XKIT"; ck "nodes_health: счётчик ssh_fails" $?
rg -qF 'SSH недоступен на ${ssh_fails} нод(ах)' "$XKIT"; ck "nodes_health: честный финал при SSH-провале" $?
rg -qF 'api_del_inbound "${XKIT_POOL_INBOUND}"' "$XKIT"; ck "ensure_pool: старый pool удаляется из панели" $?
rg -qF 'api_post "del/$1" ""' "$XKIT" && rg -q '^api_del_inbound()' "$XKIT"; ck "api_del_inbound: POST del/:id" $?
rg -qF 'остаётся в панели: при повторе будет заменён автоматически' "$XKIT"; ck "ensure_pool: сообщение при сбое apply" $?
rg -qF 'flock -n 9' "$XKIT" && rg -qF '.sub_regen.lock' "$XKIT"; ck "sub_regen: flock-обёртка" $?
rg -q '^sub_regen_impl()' "$XKIT"; ck "sub_regen_impl существует" $?
rg -qF 'cp -f "$htbk" "$XKIT_DASH_HTPASSWD"' "$XKIT"; ck "dash_rotate: откат htpasswd копированием" $?
rg -qF 'save_xkit_env || err' "$XKIT"; ck "dash_rotate: сбой save_xkit_env кричит" $?
awk '/^node_own_key\(\)/{f=1} f && /chmod 700 "\$XKIT_DIR"/{ok=1} f && /^\}/{exit} END{exit !ok}' "$XKIT"
ck "node_own_key: chmod 700 до ssh-keygen" $?
[ "$(grep -cF '^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$' "$XKIT")" -ge 1 ]; ck "node_add: sshuser-regex" $?
[ "$(grep -cF '. "$XUI_RESULT"' "$XKIT")" = "0" ]; ck "read_panel_settings: без source" $?
rg -qF 'xui_env_val XUI_PANEL_PORT' "$XKIT"; ck "read_panel_settings: парсинг sed'ом" $?
rg -qF 'ufw cron python3' "$XKIT"; ck "python3 в списке пакетов" $?
[ "$(grep -c 'command -v python3 >/dev/null 2>&1 || { err "python3 не найден' "$XKIT")" = "2" ]; ck "guards python3 в merge/expand" $?
rg -qF 'Пароль панели не извлечён из install-result.env' "$XKIT"; ck "warn о кредах панели (№17)" $?
rg -qF 'listen [::]:80;' "$XKIT" && rg -q 'build_h2_block v6' "$XKIT" && rg -q 'XKIT_V6_LISTEN' "$XKIT"; ck "IPv6: listen + override" $?
rg -qF 'listen [::]:443 ssl;' "$XKIT"; ck "IPv6: двоеточие в [::]:443 (блокер ревью)" $?
rg -qF 'notify_disk_verdict "$dpct"' "$XKIT" && rg -qF 'Сервис ${sv}: ${snmsg}' "$XKIT"; ck "notify_check: диск+сервисы подключены" $?

echo "=== 5. install.sh ==="
[ "$(grep -cF 'rm -rf "$WORK"' "$INST")" = "2" ]; ck "уборка WORK в trap EXIT + INT/TERM" $?
rg -qF 'basename -- "$SELF"' "$INST"; ck "basename с --" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "V46 ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $([ "$FAIL" = "0" ]; echo $?)
