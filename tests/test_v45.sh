#!/bin/bash
# Тесты XKIT v4.5: режимы/pool-симметрия/развилка установки/Telegram-алерты:
#  1) nodes_del: удаление последней ноды убирает pool (панель+маршрут+env+подписки)
#  2) auto_route помечает pool как POOL и не трогает его
#  3) конец установки: развилка одиночный/мастер/позже
#  4) «Режим» в info/status/меню + mode в data.json + баннер на дашборде
#  5) Telegram: доставка напрямую/через ноды, токен не в argv, гистерезис,
#     дедуп состояния, cron, токен в env (600)
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"
XMENU="${XKIT%/*}/xkit_menu.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия и синтаксис ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?

echo "=== 2. Pool-симметрия: nodes_del + pool_remove ==="
rg -q 'pool_remove_force \|\| warn' "$XKIT"; ck "nodes_del зовёт pool_remove_force" $?
rg -qF 'Это была последняя нода — убираю pool-инбаунд' "$XKIT"; ck "триггер: последняя нода + pool настроен" $?
rg -q 'cnt0="\$\(nodes_load \| jq .length. 2>/dev/null \|\| echo 0\)"' "$XKIT"; ck "проверка пустоты реестра (nodes_load | jq length)" $?
rg -qF 'api_del_inbound "$id" 2>/dev/null' "$XKIT"; ck "pool-инбаунд удаляется через api_del_inbound (№2)" $?
awk '/^pool_remove_force\(\)/{f=1} f && /routes_del "\$id"/{r=1} f && /save_xkit_env/{s=1} f && /regen_conf_and_apply/{g=1} f && /sub_regen_quiet/{u=1} f && /^\}/{if(r&&s&&g&&u)ok=1; exit} END{exit !ok}' "$XKIT"
ck "порядок в pool_remove_force: routes_del -> save -> regen -> sub_regen" $?
rg -q 'Убрать pool — вернуть сервер в одиночный режим' "$XKIT"; ck "пункт меню НОДЫ -> 8 (убрать pool)" $?
rg -q '8\) pool_remove; pause_enter' "$XKIT"; ck "кейс 8 в nodes_menu" $?
rg -qF 'молча меняя выход на IP мастера' "$XKIT"; ck "комментарий-обоснование (exit-IP)" $?

echo "=== 3. auto_route: pool помечен и не трогается ==="
rg -qF '"POOL" "инбаунд балансировки нод (не трогаю)"' "$XKIT"; ck "pool отображается как POOL" $?
awk '/^auto_route\(\)/{f=1} f && /XKIT_POOL_INBOUND.*\$id" = "\$XKIT_POOL_INBOUND"/{p=1} f && p && /continue/{c=1; exit} END{exit !(p&&c)}' "$XKIT"
ck "pool-ветка идёт до classify и завершается continue" $?

echo "=== 4. Развилка в конце установки ==="
rg -qF 'Мастер с нодами — автопроброс, затем добавить зарубежные ноды' "$XKIT"; ck "вариант 2 (мастер) в развилке" $?
rg -qF 'Одиночный сервер — автопроброс инбаундов за nginx (по умолчанию)' "$XKIT"; ck "вариант 1 (одиночный, по умолчанию)" $?
rg -q 'case "\$\{a:-1\}" in' "$XKIT"; ck "Enter = вариант 1" $?
rg -q '2\) auto_route \|\| warn' "$XKIT"; ck "мастер: автопроброс не блокирует добавление нод" $?
rg -qF 'read -r -p "Запустить автопроброс сейчас' "$XKIT" && ck "старый один вопрос убран" 1 || ck "старый один вопрос убран" 0

echo "=== 5. «Режим» в info/status/меню/дашборде ==="
rg -q 'Режим:             мастер' "$XKIT"; ck "режим в xkit_summary_text" $?
rg -q 'Режим:   мастер' "$XKIT"; ck "режим в show_status" $?
rg -q 'Режим: \$\(\[ "\$_nc" -gt 0 \]' "$XMENU"; ck "режим в шапке меню" $?
rg -q 'mode:\$mode' "$XKIT"; ck "поле mode в data.json" $?
rg -q 'D\.mode==="solo"' "$XKIT"; ck "JS: баннер одиночного режима" $?
rg -q 'id="solo"' "$XKIT"; ck "HTML: элемент баннера" $?
rg -q 'Этот сервер":"Этот сервер \(мастер\)"' "$XKIT"; ck "JS: заголовок карточки зависит от режима" $?

echo "=== 6. Telegram: структура и безопасность (статика) ==="
rg -q "printf 'XKIT_TG_TOKEN=%q" "$XKIT"; ck "XKIT_TG_TOKEN сохраняется в env" $?
rg -q 'XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""' "$XKIT"; ck "дефолты в load_xkit_env" $?
rg -qF 'curl -sf --max-time 8' "$XKIT"; ck "прямая доставка: curl -sf (HTTP-ошибки = фейл)" $?
rg -qF "node_ssh \"\$rec\" 'curl -sf --max-time 10 -K - -o /dev/null'" "$XKIT"; ck "доставка через ноду по SSH" $?
rg -qF 'url = "https://api.telegram.org/bot%s/sendMessage"' "$XKIT"; ck "URL с токеном — через printf в stdin-конфиг" $?
rg -qF 'https://api.telegram.org/bot$token/sendMessage' "$XKIT" && ck "токен НЕ интерполируется в argv" 1 || ck "токен НЕ интерполируется в argv" 0
rg -q '\*/10 \* \* \* \* root \$\{XKIT_BIN\} telegram check' "$XKIT"; ck "cron xkit-notify: каждые 10 мин, telegram check" $?
rg -q 'xkit telegram \[setup\|check\|test\|off\]' "$XKIT"; ck "CLI в usage" $?
rg -q 'telegram\) shift; require_root' "$XKIT"; ck "диспетчер main: telegram" $?
rg -q '[0-9]+\) telegram_menu' "$XMENU"; ck "пункт меню 26 (telegram в подменю мониторинга)" $?
rg -q 'chmod 600 "\$XKIT_NOTIFY_STATE"' "$XKIT"; ck "state-файл 600" $?
rg -q '\[0-9\]\{6,12\}:\[A-Za-z0-9_-\]\{30,46\}' "$XKIT"; ck "валидация формата токена" $?
rg -q '\^@\[A-Za-z0-9_\]\{4,64\}\$' "$XKIT"; ck "валидация chat_id (@канал)" $?
rg -q 'XKIT_NOTIFY_STATE="\$\{XKIT_DIR\}/notify\.state"' "$XKIT"; ck "путь state-файла в блоке путей" $?

echo "=== 7. Поведение: гистерезис / state / отправка / notify_check ==="
(
  # ВАЖНО: source сначала — xkit.sh при source безусловно ставит XKIT_DIR=/etc/xkit;
  # переопределяем пути ПОСЛЕ (как в остальных тестах)
  source "$XKIT"
  XKIT_DIR="$T"; XKIT_NOTIFY_STATE="$T/notify.state"; XKIT_NODES="$T/nodes.json"
  XKIT_ENV="$T/xkit.env"; XKIT_EXPIRY="$T/expiry.tsv"; XKIT_INFO_FILE="$T/info.txt"; XKIT_DASH_DIR="$T/dash"
  echo '[]' > "$XKIT_NODES"; : > "$XKIT_EXPIRY"
  printf 'XKIT_HOST="t.example.com"\nXKIT_TG_TOKEN=""\nXKIT_TG_CHAT=""\n' > "$XKIT_ENV"
  p=0; f=0
  tt() { local exp="$1"; shift; local out; out="$(notify_node_trans "$@")"
         local st="${out%%$'\t'*}" msg="${out#*$'\t'}"
         if [ "$st|${msg:-}" = "$exp" ]; then p=$((p+1)); else f=$((f+1)); echo "FAIL_TRANS $* -> ${st}|${msg:-} (ожидалось $exp)"; fi; }
  tt "fail1|" "" fail
  tt "down|недоступна (2 проверки подряд)" fail1 fail
  tt "down|" down fail
  tt "up|недоступна была — восстановлена" down ok
  tt "up|" fail1 ok
  tt "up|" up ok
  echo "TRANS_PASS=$p"
  echo "TRANS_FAIL=$f"

  sp=0; sf=0
  notify_state_set "node:de1" "up";    [ "$(notify_state_get "node:de1")" = "up" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE get"; }
  notify_state_set "node:de1" "down";  [ "$(notify_state_get "node:de1")" = "down" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE rewrite"; }
  [ "$(wc -l < "$XKIT_NOTIFY_STATE")" = "1" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE dup"; }
  notify_state_set "node:de1" "";      [ -z "$(notify_state_get "node:de1")" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE del"; }
  notify_state_set "exp:master/-" "-3"; [ "$(notify_state_get "exp:master/-")" = "-3" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE slash"; }
  [ "$(stat -c %a "$XKIT_NOTIFY_STATE")" = "600" ] && sp=$((sp+1)) || { sf=$((sf+1)); echo "FAIL_STATE perm"; }
  echo "STATE_PASS=$sp"
  echo "STATE_FAIL=$sf"

  gp=0; gf=0
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""
  xkit_tg_send "тест" && gp=$((gp+1)) || { gf=$((gf+1)); echo "FAIL_SEND quiet"; }
  XKIT_TG_TOKEN="123456789:AAAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDD"; XKIT_TG_CHAT="@testchan"
  XKIT_TG_PROXY="http://127.0.0.1:9"
  xkit_tg_send "тест" && { gf=$((gf+1)); echo "FAIL_SEND deadproxy"; } || gp=$((gp+1))
  XKIT_TG_PROXY=""
  d="$(jq -rn --arg c "@chan" --arg t "Аренда: 5 дн." '"chat_id=\($c|@uri)&text=\($t|@uri)"')"
  case "$d" in
    'chat_id=%40chan&text='%*) gp=$((gp+1)) ;;
    *) gf=$((gf+1)); echo "FAIL_SEND urlencode: $d" ;;
  esac
  case "$d" in
    *\'*|*\"*) gf=$((gf+1)); echo "FAIL_SEND quotes: $d" ;;
    *) gp=$((gp+1)) ;;
  esac
  echo "SEND_PASS=$gp"
  echo "SEND_FAIL=$gf"

  notify_check && echo "NOTIFY_QUIET=1" || echo "NOTIFY_QUIET=0"
) 2>/dev/null > "$T/behav.txt"
grep -E '^FAIL_' "$T/behav.txt" | sed 's/^/  [FAIL] /'
trans_p="$(sed -n 's/^TRANS_PASS=//p' "$T/behav.txt")";  trans_f="$(sed -n 's/^TRANS_FAIL=//p' "$T/behav.txt")"
state_p="$(sed -n 's/^STATE_PASS=//p' "$T/behav.txt")";  state_f="$(sed -n 's/^STATE_FAIL=//p' "$T/behav.txt")"
send_p="$(sed -n 's/^SEND_PASS=//p' "$T/behav.txt")";    send_f="$(sed -n 's/^SEND_FAIL=//p' "$T/behav.txt")"
[ "${trans_f:-1}" = "0" ] && [ "${trans_p:-0}" = "6" ]; ck "гистерезис: все 6 переходов корректны" $?
[ "${state_f:-1}" = "0" ] && [ "${state_p:-0}" = "6" ]; ck "state: set/get/перезапись/удаление/слэш/600" $?
[ "${send_f:-1}" = "0" ] && [ "${send_p:-0}" = "4" ]; ck "отправка: тихий 0 / быстрый фейл / urlencode / без кавычек" $?
grep -q 'NOTIFY_QUIET=1' "$T/behav.txt"; ck "notify_check без TG молчит (exit 0)" $?

echo ""
echo "======================================="
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "V45 ВСЕ ТЕСТЫ ПРОШЛИ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $([ "$FAIL" = "0" ]; echo $?)
