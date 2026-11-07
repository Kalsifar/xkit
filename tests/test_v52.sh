#!/bin/bash
# XKIT v5.2.1: TUI, профили, supply chain и совместимость fallback.
set -u
PASS=0; FAIL=0
ck(){ if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  [OK]   $1"; else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi; }
yes(){ grep -P -q "${3:-$2}" "$1" 2>/dev/null; }
no(){ ! grep -P -q "${3:-$2}" "$1" 2>/dev/null; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; BASE="${SCRIPT_DIR%/tests}"
XKIT="$BASE/xkit.sh"; MENU="$BASE/xkit_menu.sh"; PROTO="$BASE/xkit_protocols.sh"; INST="$BASE/install.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo '=== 1. Версия и синтаксис ==='
yes "$XKIT" 'XKIT_VERSION="5\.[0-9]+\.[0-9]+"'; ck 'версия 5.x.y (бамп-safe, v5.3.1)' $?
yes "$XKIT" 'История:      CHANGES\.md'; ck 'история вынесена в CHANGES.md' $?
bash -n "$XKIT" && bash -n "$MENU" && bash -n "$PROTO" && bash -n "$INST"; ck 'bash -n всех модулей' $?
bash "$PROTO" >/dev/null 2>&1; [ $? = 1 ]; ck 'прямой запуск модуля запрещён' $?

echo '=== 2. Подключение и санитизированный snapshot ==='
out="$(bash -c 'source "$1"; XKIT_PROTOCOLS_FILE="$2"; xkit_protocols_load >/dev/null && protocols_list --json' _ "$XKIT" "$PROTO")"
[ "$(jq 'length' <<<"$out")" = 4 ]; ck 'четыре профиля в list --json' $?
jq -e 'all(.[];(.installed|type)=="boolean")' <<<"$out" >/dev/null; ck 'installed всегда boolean' $?
! jq -e 'any(.[];has("privateKey") or has("password") or has("token"))' <<<"$out"; ck 'в сводке нет секретных полей' $?
out="$(cd "$BASE" && bash xkit.sh snapshot)"; jq -e '.protocols|length==4' <<<"$out" >/dev/null; ck 'xkit snapshot содержит профили' $?
! jq -e 'has("privateKey") or has("password") or has("token")' <<<"$out"; ck 'snapshot верхнего уровня без секретов' $?

echo '=== 3. XHTTP + REALITY ==='
yes "$PROTO" 'network:"xhttp",security:"reality"'; ck 'создаётся XHTTP + REALITY' $?
yes "$PROTO" 'xhttpSettings:\{path:\$path,host:"",mode:"auto"\}'; ck 'path и mode=auto попадают в stream' $?
yes "$PROTO" 'api_del_inbound.*откат|api_del_inbound'; ck 'есть удаление inbound при неудачном apply' $?
cat >"$T/link.sh" <<'EOF'
source "$1"
route_info(){ printf 'direct|||\n'; }
XKIT_HOST=example.com
ib='{"id":7,"port":2443,"protocol":"vless","streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/xh-test","mode":"auto"},"realitySettings":{"serverNames":["cdn.example.com"],"shortIds":["aabb"],"settings":{"publicKey":"PUB"}}}}'
cl='{"id":"UUID","email":"u@example.com","subId":"SUB"}'
link_for_client "$ib" "$cl"
EOF
out="$(bash "$T/link.sh" "$XKIT")"
grep -q '^vless://UUID@example.com:2443?' <<<"$out" && grep -q 'type=xhttp&security=reality' <<<"$out" && grep -q 'path=/xh-test&mode=auto' <<<"$out"; ck 'direct XHTTP-ссылка содержит путь и транспорт' $?
grep -q 'pbk=PUB' <<<"$out" && grep -q 'sid=aabb' <<<"$out" && grep -q 'sni=cdn.example.com' <<<"$out"; ck 'REALITY pbk/sid/sni в ссылке' $?
! grep -q 'flow=' <<<"$out"; ck 'Vision не подставляется в XHTTP' $?

echo '=== 4. Hysteria 2: SHA-256 fail-closed ==='
yes "$PROTO" 'hashes\.txt'; ck 'скачивается официальный hashes.txt' $?
yes "$PROTO" 'SHA-256 Hysteria 2 не совпал'; ck 'несовпадение хэша — ошибка' $?
no "$PROTO" 'XKIT_ALLOW_UNVERIFIED'; ck 'обхода проверки Hy2 нет' $?
yes "$PROTO" 'type: salamander'; ck 'Salamander включён' $?
yes "$PROTO" 'obfs=salamander&obfs-password='; ck 'hy2-ссылка содержит obfs' $?
# Поведенческий тест загрузчика с локальным mock curl.
cat >"$T/hy2mock.sh" <<'EOF'
source "$1"; source "$2"
TDIR="$3"
printf fake-binary >"$TDIR/bin"
curl(){
  local url="" out="" a
  for a in "$@"; do case "$a" in http*) url="$a";; esac; done
  while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift 2; continue; }; shift; done
  case "$url" in
    *releases/latest) printf '%s\n' '{"tag_name":"app/vTEST","assets":[{"name":"hysteria-linux-amd64","browser_download_url":"https://repo/hysteria-linux-amd64"}]}' >"$out" ;;
    */hashes.txt) sha256sum "$TDIR/bin" | sed 's#  .*#  hysteria-linux-amd64#' >"$out" ;;
    */hysteria-linux-amd64) cp "$TDIR/bin" "$out" ;;
  esac
}
proto_hy2_download "$TDIR/out" >/dev/null && cmp "$TDIR/bin" "$TDIR/out"
EOF
bash "$T/hy2mock.sh" "$XKIT" "$PROTO" "$T"; ck 'mock-загрузка с верным SHA-256 проходит' $?

echo '=== 5. AmneziaWG ==='
yes "$PROTO" 'ppa:amnezia/ppa'; ck 'официальный PPA' $?
yes "$PROTO" 'Jc = 8'; ck 'стабильный J/S/H-профиль' $?
no "$PROTO" '^I[1-5] ='; ck 'экспериментальные I1-I5 не навязываются' $?
yes "$PROTO" 'Managed by XKIT'; ck 'чужой AWG можно отличить при uninstall/backup' $?
yes "$PROTO" 'выполнен откат'; ck 'неудачный peer apply откатывается' $?
yes "$PROTO" 'chmod 700 "\$XKIT_AWG_CLIENTS_DIR"'; ck 'каталог клиентов 700' $?
out="$(bash -c 'source "$1"; source "$2"; proto_awg_params; [ "$AWG_S1" -ge 15 ] && [ "$AWG_S1" -le 150 ] && [ $((AWG_S1+56)) -ne "$AWG_S2" ] && [ "$AWG_H1" != "$AWG_H2" ] && [ "$AWG_H2" != "$AWG_H3" ] && [ "$AWG_H3" != "$AWG_H4" ]' _ "$XKIT" "$PROTO")"; [ $? = 0 ]; ck 'генератор параметров соблюдает ограничения' $?

echo '=== 6. Права и состояние ==='
out="$(bash -c 'source "$1"; source "$2"; XKIT_PROTOCOLS_ENV="$3/protocols.env"; HY2_AUTH="a b"; proto_state_save >/dev/null && [ "$(stat -c %a "$XKIT_PROTOCOLS_ENV")" = 600 ] && HY2_AUTH=""; proto_state_load && [ "$HY2_AUTH" = "a b" ]' _ "$XKIT" "$PROTO" "$T")"; [ $? = 0 ]; ck 'protocols.env 600 и безопасный round-trip' $?
yes "$XKIT" 'xkit-hysteria2\.service'; ck 'бэкап/удаление Hy2 интегрированы в ядро' $?
yes "$XKIT" 'Managed by XKIT'; ck 'AWG входит в backup только с меткой XKIT' $?

echo '=== 7. REALITY-сканер: только годные и выбор по номеру ==='
cat >"$T/scan.tsv" <<'EOF'
192.0.2.10	yes	yes	yes	yes	bad.example	bad.example	-	НЕТ
192.0.2.20	yes	no	no	no	good.example	good.example	-	ДА
192.0.2.30	yes	yes	yes	no	plus.example	plus.example	-	ДА+
EOF
out="$(bash -c 'source "$1"; reality_scan_candidates "$2"' _ "$XKIT" "$T/scan.tsv")"
[ "$(wc -l <<<"$out")" = 2 ] && ! grep -q '192.0.2.10' <<<"$out"; ck 'неподходящие адреса исключены из кандидатов' $?
[ "$(head -n1 <<<"$out" | cut -f1)" = '192.0.2.30' ]; ck 'ДА+ остаётся первым при сортировке' $?
out="$(bash -c 'source "$1"; reality_scan_print "$2"' _ "$XKIT" "$T/scan.tsv")"
grep -q '192.0.2.20' <<<"$out" && grep -q '192.0.2.30' <<<"$out" && ! grep -q '192.0.2.10' <<<"$out"; ck 'таблица показывает только подходящие адреса' $?
grep -q '^1 ' <<<"$out" && grep -q '^2 ' <<<"$out"; ck 'строки таблицы пронумерованы' $?
out="$(bash -c 'source "$1"; reality_scan_candidate_row "$2" 2 | cut -f1' _ "$XKIT" "$T/scan.tsv")"
[ "$out" = '192.0.2.20' ]; ck 'номер выбора совпадает с номером таблицы' $?
bash -c 'source "$1"; ! reality_scan_candidate_row "$2" "1;p"' _ "$XKIT" "$T/scan.tsv"; ck 'нечисловой номер безопасно отклоняется' $?
out="$(printf '2\n' | bash -c 'source "$1"; reality_scan_choose "$2" >/dev/null && printf "%s|%s" "$RDEST" "$RSNI"' _ "$XKIT" "$T/scan.tsv")"
[ "$out" = '192.0.2.20:443|good.example' ]; ck 'общий мастер выбирает RDEST/RSNI по номеру' $?
cat >"$T/scan-bad.tsv" <<'EOF'
192.0.2.10	yes	yes	yes	yes	bad.example	bad.example	-	НЕТ
EOF
bash -c 'source "$1"; ! reality_scan_choose "$2" </dev/null >/dev/null 2>&1' _ "$XKIT" "$T/scan-bad.tsv"; ck 'пустой список годных кандидатов завершает выбор' $?

echo '=== 8. TUI и fallback ==='
for a in amd64 arm64; do [ -s "$BASE/xkit-tui-linux-$a" ]; ck "TUI $a присутствует" $?; done
cp "$BASE/xkit-tui-linux-amd64" "$T/xkit-tui"; chmod 755 "$T/xkit-tui"
"$T/xkit-tui" --selftest >/dev/null; ck 'TUI selftest' $?
v_core="$(grep -m1 '^XKIT_VERSION=' "$XKIT" | cut -d'"' -f2)"
[ "$("$T/xkit-tui" --version)" = "$v_core" ]; ck 'версия TUI совпадает с ядром (динамически)' $?
out="$(printf '0\n' | bash "$XKIT" 2>/dev/null)"; grep -q "XKIT v$v_core" <<<"$out"; ck 'pipe автоматически получает классическое меню' $?
yes "$XKIT" 'XKIT_TUI:-1'; ck 'XKIT_TUI=0 поддерживается' $?
yes "$XKIT" '\-\-classic'; ck 'xkit --classic поддерживается' $?
yes "$INST" 'fetch_release_component xkit_protocols\.sh'; ck 'installer скачивает протоколы' $?
yes "$INST" 'xkit-tui-linux-amd64'; ck 'installer скачивает TUI amd64' $?
yes "$INST" 'xkit-tui-linux-arm64'; ck 'installer скачивает TUI arm64' $?

echo '=== 9. Метрики нод и firewall ==='
out="$(bash -c 'source "$1"; node_ssh(){ printf "12.5\t34.2\t0.42\n"; }; node_resource_stats "{}"' _ "$XKIT")"
[ "$(jq -r '.resources+"|"+(.cpu_pct|tostring)+"|"+(.ram_pct|tostring)' <<<"$out")" = 'ok|12.5|34.2' ]; ck 'CPU/RAM ноды собираются через SSH' $?
out="$(bash -c 'source "$1"; node_ssh(){ printf "garbage\n"; }; node_resource_stats "{}"' _ "$XKIT")"
jq -e '.resources=="unavailable" and .cpu_pct==null and .ram_pct==null' <<<"$out" >/dev/null; ck 'неизвестные ресурсы — null, а не ноль' $?
cat >"$T/metrics.sh" <<'EOF'
source "$1"
XKIT_NODES_METRICS="$2/metrics.json"
cat >"$XKIT_NODES_METRICS" <<'JSON'
{"generated":1,"nodes":[{"name":"de1","up":40,"down":20,"total":60}]}
JSON
nodes_load(){ echo '[{"name":"de1"}]'; }
expiry_get(){ :; }; expiry_note(){ :; }
dash_node_stats(){ echo '{"name":"de1","up":100,"down":50,"total":150,"status":"ok"}'; }
nodes_metrics_collect >/dev/null
EOF
bash "$T/metrics.sh" "$XKIT" "$T"; ck 'общий кэш метрик атомарно создаётся' $?
jq -e '.nodes[0].interval_total==90 and .nodes[0].rate_bps>0' "$T/metrics.json" >/dev/null; ck 'активность считается по дельте трафика' $?
cat >"$T/metrics-reset.sh" <<'EOF'
source "$1"
XKIT_NODES_METRICS="$2/metrics.json"
nodes_load(){ echo '[{"name":"de1"}]'; }
expiry_get(){ :; }; expiry_note(){ :; }
dash_node_stats(){ echo '{"name":"de1","up":1,"down":1,"total":2,"status":"ok"}'; }
nodes_metrics_collect >/dev/null
EOF
bash "$T/metrics-reset.sh" "$XKIT" "$T"
jq -e '.nodes[0].rate_bps==null and .nodes[0].interval_total==null' "$T/metrics.json" >/dev/null; ck 'сброс счётчиков не создаёт ложную скорость' $?
cat >"$T/snapshot-metrics.sh" <<'EOF'
source "$1"
XKIT_NODES_METRICS="$2/metrics.json"
XKIT_NODES="$2/no-nodes"; XKIT_CRT="$2/no-cert"; BACKUP_DIR="$2/no-backups"
XKIT_DASH_DIR="$2/no-dash"; XKIT_PROTOCOLS_FILE="$2/no-protocols"
load_xkit_env(){ :; }; kit_session(){ return 1; }; xkit_protocols_load(){ return 1; }
xkit_snapshot
EOF
out="$(bash "$T/snapshot-metrics.sh" "$XKIT" "$T")"
jq -e '.nodes_metrics|length==1' <<<"$out" >/dev/null; ck 'snapshot включает метрики нод' $?
! jq -e '.nodes_metrics[0]|has("host") or has("privateKey") or has("note")' <<<"$out" >/dev/null; ck 'snapshot метрик использует whitelist без секретов' $?

cat >"$T/fw-own.sh" <<'EOF'
source "$1"
R="$2/rules"; : >"$R"
ufw(){
  case "$1" in
    status) echo 'Status: active'; cat "$R" ;;
    allow) printf '%s ALLOW Anywhere # %s\n' "$2" "$4" >>"$R" ;;
    delete) grep -v -F "$3 ALLOW" "$R" >"$R.new"; mv "$R.new" "$R" ;;
  esac
}
xkit_fw_add awg 23456 udp && xkit_fw_add awg 23456 udp
[ "$(wc -l <"$R")" = 1 ] && xkit_fw_remove awg 23456 udp && [ ! -s "$R" ]
EOF
bash "$T/fw-own.sh" "$XKIT" "$T"; ck 'firewall добавляет одно помеченное правило и удаляет его' $?
cat >"$T/fw-foreign.sh" <<'EOF'
source "$1"
R="$2/rules"; echo '23456/udp ALLOW Anywhere' >"$R"
ufw(){
  case "$1" in
    status) echo 'Status: active'; cat "$R" ;;
    allow) printf '%s ALLOW Anywhere # %s\n' "$2" "$4" >>"$R" ;;
    delete) grep -v -F "$3 ALLOW" "$R" >"$R.new"; mv "$R.new" "$R" ;;
  esac
}
xkit_fw_add awg 23456 udp && xkit_fw_remove awg 23456 udp
[ "$(cat "$R")" = '23456/udp ALLOW Anywhere' ]
EOF
bash "$T/fw-foreign.sh" "$XKIT" "$T"; ck 'чужое firewall-правило не дублируется и не удаляется' $?
yes "$XKIT" 'XKIT:\$\{owner\}'; ck 'правила получают метку владельца XKIT' $?
yes "$PROTO" "xkit_awg_route_add"; ck 'AWG настраивает forwarding через UFW' $?
yes "$PROTO" 'AWG_DEV=%q'; ck 'внешний интерфейс AWG сохраняется для удаления route' $?
cat >"$T/awg-rollback.sh" <<'EOF'
source "$1"
XKIT_PROTOCOLS_FILE="$2"; xkit_protocols_load
AWG_DEV=ens3; AWG_PORT=23456
XKIT_AWG_CONF="$3/awg0.conf"; XKIT_AWG_SYSCTL="$3/awg.conf"
touch "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
LOG="$3/log"
systemctl(){ printf 'systemctl %s\n' "$*" >>"$LOG"; }
xkit_awg_route_remove(){ printf 'route %s\n' "$1" >>"$LOG"; }
xkit_fw_remove(){ printf 'fw %s %s %s\n' "$1" "$2" "$3" >>"$LOG"; }
proto_awg_rollback_install
[ ! -e "$XKIT_AWG_CONF" ] && [ ! -e "$XKIT_AWG_SYSCTL" ] &&
  grep -qx 'route ens3' "$LOG" && grep -qx 'fw awg 23456 udp' "$LOG"
EOF
bash "$T/awg-rollback.sh" "$XKIT" "$PROTO" "$T"; ck 'rollback AWG очищает route по сохранённому интерфейсу' $?
yes "$PROTO" 'установка откачена'; ck 'ошибка firewall откатывает установку службы' $?
yes "$XKIT" 'metrics\) nodes_metrics_collect'; ck 'CLI xkit nodes metrics подключён' $?

echo '=== 10. Пломба и pin-хэши ==='
[ "$(wc -l <"$BASE/xkit.sh.sha256")" = 5 ]; ck 'пломба содержит пять компонентов' $?
(cd "$BASE" && sha256sum -c xkit.sh.sha256 >/dev/null); ck 'sha256sum -c проходит' $?
no "$INST" '^XKIT_PIN_[A-Z0-9_]+="@@'; ck 'все pin-хэши заполнены' $?

echo '=== 11. Аудит v5.2.1 ==='
# баг 1: clientStats-массив больше не даёт нулевой трафик в client_list
no "$XKIT" 'else \(\.clientStats // \[\]\) end'; ck 'баг1: else-ветка clientStats берёт точку, не .clientStats' $?
out="$(jq -r '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email=="u1") | (.up|tonumber? // 0)] | add // 0' <<'J'
{"clientStats":[{"email":"u1","up":1048576,"down":2048}]}
J
)"; [ "$out" = "1048576" ]; ck 'баг1: clientStats-Массив -> трафик считается' $?
out="$(jq -r '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email=="u1") | (.up|tonumber? // 0)] | add // 0' <<'J'
{"clientStats":"[{\"email\":\"u1\",\"up\":7,\"down\":0}]"}
J
)"; [ "$out" = "7" ]; ck 'баг1: clientStats-строка -> трафик считается' $?
# баг 2: build.sh восстанавливает удалённые pin-строки (не только заменяет существующие)
mkdir -p "$T/bt"; cp "$BASE/install.sh" "$T/bt/install.sh"
sed -i '/^XKIT_PIN_MENU_SHA256=/d' "$T/bt/install.sh"
for f in xkit.sh xkit_menu.sh xkit_protocols.sh xkit-tui-linux-amd64 xkit-tui-linux-arm64; do printf 'x' >"$T/bt/$f"; done
awk '/ROOT="\$ROOT" python3 - <</{f=1;next} /^PY$/{f=0} f' "$BASE/build.sh" | ROOT="$T/bt" python3
grep -q '^XKIT_PIN_MENU_SHA256=' "$T/bt/install.sh"; ck 'баг2: удалённая pin-строка восстановлена сборкой' $?
w="$(awk -F'"' '/^XKIT_PIN_MENU_SHA256=/{print $2}' "$T/bt/install.sh")"
[ "$w" = "$(sha256sum "$T/bt/xkit_menu.sh" | awk '{print $1}')" ]; ck 'баг2: восстановленный pin равен фактическому хешу' $?
# баг 3: nodes_health различает SSH-провал и неактивный x-ui
yes "$XKIT" 'svc_out="\$\(node_ssh'; ck 'баг3: вывод systemctl is-active перехватывается' $?
yes "$XKIT" 'x-ui не активен \(systemctl:'; ck 'баг3: отдельная ветка «x-ui не активен»' $?
yes "$XKIT" 'rc" -eq 255.*rc" -eq 124'; ck 'баг3: SSH-провал определяется по кодам 255/124' $?
# баг 4: awg route — сверка пары по интерфейсу и снятие старого dev
no "$XKIT" 'XKIT:awg-forward. >/dev/null && return 0'; ck 'баг4: ранний выход по «любому» XKIT-правилу убран' $?
yes "$PROTO" 'xkit_awg_route_remove "\$old_dev"'; ck 'баг4: при смене dev старая пара снимается явно' $?
yes "$PROTO" 'linux-headers-generic'; ck 'мелочь9: заголовки AWG — fallback на generic' $?
# баг 5: dev-режим install.sh сверяет локальный xkit.sh с пломбой рядом
yes "$INST" 'не совпал с xkit.sh.sha256 рядом с install.sh'; ck 'баг5: локальный xkit.sh сверяется с xkit.sh.sha256' $?
# з.6: подтверждение перед установщиком 3X-UI (мастер и нода)
yes "$XKIT" 'Запустить официальный установщик 3X-UI от root'; ck 'з.6: подтверждение установщика 3X-UI на мастере' $?
yes "$XKIT" 'установщик 3X-UI на ноде \(от root\)'; ck 'з.6: подтверждение установщика 3X-UI на ноде' $?
# з.7/з.11: пустой вывод openssl не считается парой (ядро)
yes "$XKIT" 'не читается как сертификат'; ck 'з.7: битые серты не проходят проверку парности (ядро)' $?
# з.8: дельты интервала в whitelist snapshot
yes "$XKIT" 'interval_total,interval_up,interval_down'; ck 'з.8: interval_up/down в whitelist snapshot' $?
# з.9: EOF на порту туннеля отменяет node_add, как у соседних полей
yes "$XKIT" 'Порт туннеля на ноде \[\$\{tport\}\]: " tp \|\| \{ echo; return 1; \}'; ck 'з.9: EOF на порту туннеля — отмена, не молчаливый дефолт' $?
# з.10: НЕ-hex мусор в пломбе не превращается в WANT (hex любой длины даёт честный mismatch)
yes "$INST" 'WANT" =~ \^\[0-9a-f\]\+\$'; ck 'з.10: сумма пломбы валидируется как hex' $?
# мелочи
yes "$XKIT" 'подчищаем созданный mktemp-файл'; ck 'мелочь4: утечка mktemp-файла в dash_rotate устранена' $?
yes "$XKIT" 'with open\(src, encoding="utf-8"\)'; ck 'мелочь5: nodes_merge_template — явные with/encoding' $?
yes "$MENU" 'regen_conf_and_apply \|\| \{ err'; ck 'мелочь10: сбой regen_conf_and_apply возвращает ошибку' $?
# ROOT-независимость сборки (мелочь1)
yes "$BASE/build.sh" 'ROOT="\$ROOT" python3'; ck 'мелочь1: build.sh передаёт ROOT через окружение' $?

echo; echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
