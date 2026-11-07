
dash_path() { printf '/d-%s/' "${XKIT_DASH_TOKEN:-CHANGE_ME}"; }

dash_user_gen() { printf 'dash%s' "$(rand_hex 2)"; }

# htpasswd для Basic Auth дашборда (apr1-хэш — понимается nginx'ом)
dash_htpasswd_write() { # из XKIT_DASH_USER / XKIT_DASH_PASS
  local u="${XKIT_DASH_USER:-}" p="${XKIT_DASH_PASS:-}" h
  [ -n "$u" ] && [ -n "$p" ] || return 1
  h="$(printf '%s\n' "$p" | openssl passwd -apr1 -stdin 2>/dev/null)" || return 1   # V-03: не в argv
  [ -n "$h" ] || return 1
  printf '%s:%s\n' "$u" "$h" > "${XKIT_DASH_HTPASSWD}"
  chown root:www-data "${XKIT_DASH_HTPASSWD}" 2>/dev/null || true
  chmod 640 "${XKIT_DASH_HTPASSWD}"
  return 0
}

dash_cron_install() {
  cat > "$XKIT_CRON_DASH" <<EOF
# XKIT: обновление веб-дашборда каждые 5 минут
*/5 * * * * root ${XKIT_BIN} dash gen >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_DASH"
  ok "Cron: дашборд обновляется каждые 5 минут ($XKIT_CRON_DASH)"
}

# состояние мастер-сервера -> JSON-объект
dash_master_json() {
  local nginx_st="inactive" xui_st="inactive" load1="" up_days=""
  local mem_total="" mem_avail="" mem_pct=0 disk_pct=0 cert_end=""
  nginx_st="$(systemctl is-active nginx 2>/dev/null || echo inactive)"
  xui_st="$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
  up_days="$(awk '{printf "%.1f", $1/86400}' /proc/uptime 2>/dev/null)"
  mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [[ "${mem_total:-}" =~ ^[0-9]+$ ]] && [[ "${mem_avail:-}" =~ ^[0-9]+$ ]] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  fi
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  [ -n "${XKIT_CRT:-}" ] && [ -r "$XKIT_CRT" ] \
    && cert_end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
  jq -nc --arg nginx "$nginx_st" --arg xui "$xui_st" --arg load "${load1:-}" \
     --argjson mem "${mem_pct:-0}" --argjson disk "${disk_pct:-0}" \
     --arg cert "$cert_end" --arg up "${up_days:-}" '
    {nginx:$nginx, xui:$xui, load1:(if $load=="" then null else $load end),
     mem_pct:$mem, disk_pct:$disk,
     cert_end:(if $cert=="" then null else $cert end),
     uptime_days:(if $up=="" then null else ($up|tonumber) end)}'
}

# Системные CPU/RAM ноды через существующий защищённый SSH; агент не нужен.
# Значения неизвестны => null, а не фиктивный ноль. Команда на ноде фиксированная.
node_resource_stats() { # $1 rec-ноды
  local out cpu ram load
  out="$(node_ssh "$1" 'bash -s' 2>/dev/null <<'EOS'
cpu_sample() { awk '/^cpu /{t=0; for(i=2;i<=NF;i++)t+=$i; print t,$5+$6; exit}' /proc/stat; }
read -r t0 i0 < <(cpu_sample)
sleep 1
read -r t1 i1 < <(cpu_sample)
cpu="$(awk -v t0="$t0" -v i0="$i0" -v t1="$t1" -v i1="$i1" 'BEGIN{dt=t1-t0; di=i1-i0; if(dt>0)printf "%.1f",100*(dt-di)/dt; else print "0"}')"
mem="$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "%.1f",100*(t-a)/t;else print "0"}' /proc/meminfo)"
load="$(awk '{print $1}' /proc/loadavg)"
printf '%s\t%s\t%s\n' "$cpu" "$mem" "$load"
EOS
)"
  if [[ "$out" =~ ^[0-9]+([.][0-9]+)?[[:space:]]+[0-9]+([.][0-9]+)?[[:space:]]+[0-9]+([.][0-9]+)?$ ]]; then
    IFS=$'\t' read -r cpu ram load <<<"$out"
    jq -nc --argjson c "$cpu" --argjson r "$ram" --argjson l "$load" \
      '{resources:"ok",cpu_pct:$c,ram_pct:$r,load1:$l}'
  else
    jq -nc '{resources:"unavailable",cpu_pct:null,ram_pct:null,load1:null}'
  fi
}

# статистика одной ноды (туннель + панель + трафик + системные ресурсы)
dash_node_stats() { # $1 rec-ноды, $2 expiry-дата (или пусто), $3 заметка
  local rec="$1" exp="${2:-}" note="${3:-}"
  local name host tport status="down" lat="" panel="n/a" up=0 down=0 total=0 clients=0
  local resources='{"resources":"unavailable","cpu_pct":null,"ram_pct":null,"load1":null}'
  local t0 t1
  name="$(jq -r '.name' <<<"$rec")"
  host="$(jq -r '.host' <<<"$rec")"
  tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
  t0="$(date +%s%N)"
  if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
    t1="$(date +%s%N)"
    lat=$(( (t1 - t0) / 1000000 ))
    status="ok"
  fi
  if [ "$status" = "ok" ]; then
    local ck out stats
    # ВАЖНО: timeout нельзя вешать на bash-функции (только на бинарники) —
    # ограничение времени даёт сам curl (--max-time 20 внутри node_api)
    ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" >/dev/null 2>&1; then
      panel="ok"
      out="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" 2>/dev/null)"
      if jq -e '.success == true' <<<"${out:-}" >/dev/null 2>&1; then
        # total = up+down (ПОТРАЧЕННЫЙ трафик). .total инбаунда — это КВОТА
        # (у большинства 0 = безлимит) — та же формула, что в sanitize_inbounds
        stats="$(jq -r '( .obj // [] ) as $a |
          [ ([ $a[] | (.up // 0) ] | add // 0),
            ([ $a[] | (.down // 0) ] | add // 0),
            ([ $a[] | ((.up // 0) + (.down // 0)) ] | add // 0),
            ($a | length) ] | @tsv' <<<"$out" 2>/dev/null)"
        [[ "${stats:-}" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] \
          && read -r up down total clients <<<"$stats"
      else
        panel="fail"
      fi
    else
      panel="fail"
    fi
    rm -f "$ck"
  fi
  [ "$status" = "ok" ] && resources="$(node_resource_stats "$rec")"
  local dl base
  dl="$(days_left "$exp")"
  base="$(jq -nc --arg n "$name" --arg h "$host" --arg st "$status" \
     --argjson tp "$tport" --argjson lat "${lat:-null}" --arg p "$panel" \
     --argjson up "${up:-0}" --argjson down "${down:-0}" \
     --argjson tot "${total:-0}" --argjson cl "${clients:-0}" \
     --arg exp "$exp" --argjson dl "${dl:-null}" --arg note "$note" '
    {name:$n, host:$h, tunnel_port:$tp, status:$st, latency_ms:$lat, panel:$p,
     up:$up, down:$down, total:$tot, clients:$cl,
     expiry:(if $exp=="" then null else $exp end),
     days_left:$dl,
     note:(if $note=="" then null else $note end)}')"
  # (аудит v5.2.1, дух W-6): ресурсы от ноды обязаны быть JSON-объектом —
  # мусор/TSV от SSH не должен ломать весь jq-конвейер статистики ноды
  jq -e 'type=="object"' <<<"$resources" >/dev/null 2>&1 \
    || resources='{"resources":"unavailable","cpu_pct":null,"ram_pct":null,"load1":null}'
  jq -c --argjson r "$resources" '. + $r' <<<"$base"
}

# Общий кэш нод для веб-дашборда и TUI. Активность = дельта счётчиков за
# прошедший интервал, а не накопленный total. При сбросе счётчика rate=null.
nodes_metrics_collect() {
  local arr rec nname cur prev previous='{}' now dt
  local -a recs=()
  now="$(date +%s)"
  if [ -r "$XKIT_NODES_METRICS" ] && jq -e 'type=="object"' "$XKIT_NODES_METRICS" >/dev/null 2>&1; then
    previous="$(cat "$XKIT_NODES_METRICS")"
  fi
  dt=$((now-$(jq -r '.generated // 0' <<<"$previous" 2>/dev/null || echo 0)))
  arr="$(nodes_load)"
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    nname="$(jq -r '.name' <<<"$rec")"
    cur="$(dash_node_stats "$rec" "$(expiry_get node "$nname")" "$(expiry_note node "$nname")")"
    prev="$(jq -c --arg n "$nname" '[.nodes[]?|select(.name==$n)][0] // {}' <<<"$previous")"
    cur="$(jq -c --argjson p "$prev" --argjson dt "$dt" '
      . as $c | ($p.total // null) as $old |
      if ($old|type)=="number" and $dt>0 and $c.total>=$old then
        .interval_total=($c.total-$old) |
        .interval_up=($c.up-($p.up//0)) |
        .interval_down=($c.down-($p.down//0)) |
        .rate_bps=(($c.total-$old)/$dt)
      else
        .interval_total=null | .interval_up=null | .interval_down=null | .rate_bps=null
      end' <<<"$cur")"
    recs+=("$cur")
  done < <(jq -c '.[]' <<<"$arr")
  local nodes_json='[]' data tmp
  [ "${#recs[@]}" -eq 0 ] || nodes_json="$(printf '%s\n' "${recs[@]}" | jq -s '.' 2>/dev/null || echo '[]')"
  data="$(jq -nc --argjson gen "$now" --argjson nodes "$nodes_json" \
    '{generated:$gen,generated_str:($gen|todate),nodes:$nodes}')" || return 1
  mkdir -p "$(dirname "$XKIT_NODES_METRICS")" || return 1
  tmp="$(mktemp "${XKIT_NODES_METRICS}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$data" >"$tmp" || ! chmod 640 "$tmp" || ! mv -f "$tmp" "$XKIT_NODES_METRICS"; then
    rm -f "$tmp"; return 1
  fi
  printf '%s\n' "$data"
}

# санитизированные данные для data.json: БЕЗ privateKey Reality, UUID/subId
# клиентов и прочих внутренностей — только агрегаты, которые ждёт JS
# (поля совпадают с тем, что рендерит index.html: tag/port/proto/enable/...)
dash_sanitize_inbounds() { # $1 = массив инбаундов (JSON) -> stdout
  # ИДЕМПОТЕНТНО: raw из API (.protocol, .settings-строка) -> sanitized;
  # уже sanitized (.proto, .clients-число) проходит без изменений —
  # на этом построены stale-ветка и финальный барьер перед записью.
  # Порядок веток clients КРИТИЧЕН: у raw из API поля .clients НЕТ вообще
  # (клиенты лежат внутри settings-строки), поэтому raw-детект через .settings
  # должен идти ДО прочих веток; .clients-массив (полу-sanitized) считаем длиной,
  # null/битое/пусто -> 0. Всегда возвращаем валидный JSON-массив (даже на
  # пустом входе jq молчит с кодом 0 — потому явная проверка на непустой вывод).
  local out
  out="$(jq -c '[ .[] | {
      tag: (.tag // "inbound"),
      port: .port,
      proto: (.protocol // .proto // ""),
      enable: (if (.enable == null) then true else .enable end),   # // true съел бы явный false
      up: (.up // 0),
      down: (.down // 0),
      total: ((.up // 0) + (.down // 0)),
      clients: (if (.clients|type) == "number" then .clients
                elif (.settings? // null) != null and (.settings? // "") != "" then
                  ([ ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | (.clients // []))[]) ] | length)
                elif (.clients|type) == "array" then ([ .clients[] ] | length)
                else 0 end)
    } ]' <<<"$1" 2>/dev/null)" || out=""
  [ -n "$out" ] && echo "$out" || echo '[]'
}

# топ-10 пользователей по ПОТРАЧЕННОМУ трафику (up+down из clientStats,
# а не квота .total клиента, как было раньше; clientStats бывает строкой)
dash_sanitize_users() { # $1 = массив инбаундов (JSON) -> stdout
  jq -c '[ .[] | . as $ib |
      ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | .clients // [])[]) | . as $c |
      (($ib.clientStats // [] | if type=="string" then (fromjson? // []) else . end)
        | map(select(.email == $c.email)) | .[0] // {}) as $s |
      {email:($c.email // "?"), ib:($ib.tag // "?"),
       up:($s.up // 0), down:($s.down // 0),
       total:(($s.up // 0) + ($s.down // 0)),
       enable:(if ($c.enable == null) then true else $c.enable end), expiryTime:($c.expiryTime // 0)} ]
    | sort_by(-(.total // 0)) | .[0:10]' <<<"$1" 2>/dev/null || echo '[]'
}

# whitelist полей пользователя (для users из прошлого data.json): пропускаем
# только safe-поля — дрейф формата или мусор в старом файле не попадёт в запись
dash_users_whitelist() { # $1 = массив users (JSON) -> stdout
  jq -c '[ .[] | {
      email:(.email // "?"), ib:(.ib // "?"),
      up:(.up // 0), down:(.down // 0), total:(.total // 0),
      enable:(if (.enable == null) then true else .enable end), expiryTime:(.expiryTime // 0)} ]' <<<"$1" 2>/dev/null || echo '[]'
}

# права на файлы дашборда: читать должен только nginx, не все локальные юзеры
dash_fix_perms() {
  local ngu="www-data" nguser=""
  if ! getent group www-data >/dev/null 2>&1; then
    # не-Ubuntu (CentOS и т.п.): находим юзера процесса nginx и берём ЕГО
    # ПЕРВИЧНУЮ ГРУППУ (id -gn) — юзер ≠ группа, раньше подставляли юзера в chgrp
    nguser="$(ps -eo user=,comm= 2>/dev/null | awk '$2=="nginx" && $1!="root"{print $1; exit}')"
    [ -n "$nguser" ] && ngu="$(id -gn "$nguser" 2>/dev/null || true)"
  fi
  if [ -z "$ngu" ] || ! getent group "$ngu" >/dev/null 2>&1; then
    warn "dash_fix_perms: группа nginx не найдена — файлы дашборда могут быть world-readable"
    return 0
  fi
  chgrp "$ngu" /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  local f
  for f in "${XKIT_DASH_DIR}/index.html" "${XKIT_DASH_DIR}/data.json"; do
    [ -f "$f" ] || continue
    chown root:"$ngu" "$f" 2>/dev/null || true
    chmod 640 "$f" 2>/dev/null || true
  done
  return 0
}

# построить data.json (+ восстановить index.html, если удалён)
dash_gen() {
  load_xkit_env 2>/dev/null || { err "Сначала установка (пункт 1)"; return 1; }
  [ -n "${XKIT_HOST:-}" ] || { err "Сначала установка (пункт 1)"; return 1; }
  [ "${XKIT_DASH:-0}" = "1" ] || { err "Дашборд не установлен — меню: «Веб-дашборд» (или xkit dash install)"; return 1; }
  mkdir -p -m 750 "$XKIT_DASH_DIR" 2>/dev/null || { err "Не удалось создать $XKIT_DASH_DIR"; return 1; }

  # Блокировка В SUBSHELL: fd 9 живёт только внутри ( ... ) 9>lock и закрывается
  # при его выходе. Раньше `exec 9>` держал lock в интерактивной сессии —
  # cron (xkit dash gen) не мог обновить дашборд, пока админ сидел в меню.
  (
    flock -n 9 || { warn "Предыдущее построение ещё не закончилось — пропускаю"; exit 0; }
    dash_gen_locked
  ) 9>"${XKIT_DASH_DIR}/.lock"
  return $?
}

# вся работа dash_gen под lock (вызывается в subshell из dash_gen)
dash_gen_locked() {
  # 750 СРАЗУ (без окна 755): раньше каждый запуск ставил 755, и между ним
  # и dash_fix_perms каталог был проходим для всех локальных юзеров
  # ВАЖНО: umask действует только в ЭТОМ subshell (dash_gen зовёт нас в ( ... ) 9>lock).
  # НЕ выносить umask в dash_gen вне subshell — иначе он утечёт в интерактивную
  # сессию админа и все последующие файлы кита будут создаваться с маской 640.
  umask 027   # новые файлы (data.json/index.html/.tmp) создаются сразу 640
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true

  # HTML-каркас: самовосстановление, если кто-то удалил
  if [ ! -s "${XKIT_DASH_DIR}/index.html" ]; then
    dash_write_html > "${XKIT_DASH_DIR}/index.html" 2>/dev/null || true
  fi

  local panel_st="down" inbounds="[]" users="[]" totals='{"up":0,"down":0,"total":0}'
  local stale=0
  if kit_session >/dev/null 2>&1; then
    panel_st="ok"
    # ВАЖНО: в data.json уходит САНИТИЗИРОВАННЫЙ список (см. dash_sanitize_*)
    inbounds="$(dash_sanitize_inbounds "$INBOUNDS")"
    local sums tu td
    # total = up+down (потрачено): .total инбаунда — квота, а не трафик
    sums="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$INBOUNDS" 2>/dev/null)"
    if [[ "${sums:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
      read -r tu td <<<"$sums"
      totals="$(jq -nc --argjson u "$tu" --argjson d "$td" '{up:$u,down:$d,total:($u+$d)}')"
    fi
    users="$(dash_sanitize_users "$INBOUNDS")"
    rm -f "${COOKIE_JAR:-}" 2>/dev/null || true
  else
    # Панель недоступна: НЕ затираем прошлый трафик пустотой —
    # берём инбаунды/пользователей из прошлого data.json (stale лучше пустого).
    # ВАЖНО (аудит №4): прошлый data.json мог быть записан v4.3 с СЫРЫМИ
    # инбаундами (privateKey Reality, UUID/subId). Апгрейд + падение панели
    # до первого успешного gen = stale-ветка вернула бы утечку. Поэтому
    # sanitize при ЧТЕНИИ — идемпотентно (sanitized проходит без изменений),
    # сырые данные не доходят до записи ни при каком сценарии.
    if [ -r "${XKIT_DASH_DIR}/data.json" ]; then
      local old old_inb old_users
      old="$(cat "${XKIT_DASH_DIR}/data.json" 2>/dev/null || true)"
      if jq -e '(.inbounds|type) == "array"' <<<"$old" >/dev/null 2>&1; then
        old_inb="$(jq -c '.inbounds // []' <<<"$old")"
        inbounds="$(dash_sanitize_inbounds "$old_inb")"
        if [ "$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)" -eq 0 ]; then
          # формат не распознан — пусто безопаснее, чем raw
          inbounds="[]"; users="[]"
        elif jq -e '[ .[] | has("settings") or has("streamSettings") ] | any' <<<"$old_inb" >/dev/null 2>&1; then
          # raw v4.3 ИЛИ смешанный формат (№1, аудит №1): users считаем из СЫРЫХ
          # элементов и ОБЪЕДИНЯЕМ с users sanitized-элементов прошлого data.json
          # (раньше смешанный дамп молча терял клиентов sanitized-инбаундов)
          local raw_inb
          raw_inb="$(jq -c '[ .[] | select(has("settings") or has("streamSettings")) ]' <<<"$old_inb" 2>/dev/null || echo '[]')"
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1 || old_users="[]"
          users="$( { dash_sanitize_users "$raw_inb"; printf '%s\n' "$old_users"; } \
            | jq -c -s 'add | unique_by((.email // "?")+"\u0000"+(.ib // "?")) | sort_by(-(.total // 0)) | .[0:10]' 2>/dev/null || echo '[]')"
          users="$(dash_users_whitelist "$users")"
        else
          # уже sanitized (v4.4+): оставляем users, пропустив через whitelist
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          if jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1; then
            users="$(dash_users_whitelist "$old_users")"
          else
            users="[]"
          fi
        fi
        # totals пересчитываем из уже sanitized-инбаундов (up+down)
        local s2 tu2 td2
        s2="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$inbounds" 2>/dev/null)"
        if [[ "${s2:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
          read -r tu2 td2 <<<"$s2"
          totals="$(jq -nc --argjson u "$tu2" --argjson d "$td2" '{up:$u,down:$d,total:($u+$d)}')"
        else
          totals='{"up":0,"down":0,"total":0}'
        fi
        stale=1
      fi
    fi
  fi

  local master_json
  master_json="$(dash_master_json)"

  # --- общий сборщик: туннель/API/трафик/CPU/RAM; тот же кэш читает TUI ---
  local nodes_json="[]"
  nodes_json="$(nodes_metrics_collect | jq -c '.nodes')" || return 1

  # --- аренда мастер-сервера ---
  local mexp expiry_json="null" mdl
  mexp="$(expiry_get master -)"
  if [ -n "$mexp" ]; then
    mdl="$(days_left "$mexp")"
    expiry_json="$(jq -nc --arg d "$mexp" --argjson dl "${mdl:-null}" \
      --arg n "$(expiry_note master -)" \
      '{date:$d, days_left:$dl, note:(if $n=="" then null else $n end)}')"
  fi

  # Последний барьер (аудит №4): идемпотентная санитизация ПЕРЕД записью —
  # закрывает любые будущие пути попадания сырых данных. users здесь НЕ
  # пересчитываем: у sanitized-инбаундов нет settings/clientStats (стал бы пуст)
  inbounds="$(dash_sanitize_inbounds "$inbounds")"

  # v4.5: явный режим на дашборде — снимает вопрос «почему таблица нод пустая»
  local mode="solo"
  [ "$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)" -gt 0 ] && mode="master"

  local data
  data="$(jq -n \
      --arg v "$XKIT_VERSION" --arg host "$XKIT_HOST" \
      --arg panel "$panel_st" --arg strat "${XKIT_BAL_STRATEGY:-roundRobin}" \
      --arg mode "$mode" \
      --arg gen_str "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
      --argjson gen "$(date +%s)" \
      --argjson master "$master_json" --argjson inb "$inbounds" \
      --argjson users "$users" --argjson nodes "$nodes_json" \
      --argjson totals "$totals" --argjson exp "$expiry_json" \
      --argjson stale "$( [ "$stale" = "1" ] && echo true || echo false )" \
      '{version:$v, host:$host, generated:$gen, generated_str:$gen_str, mode:$mode,
        panel:$panel, strategy:$strat, master:$master, totals:$totals,
        inbounds:$inb, users:$users, nodes:$nodes, expiry_master:$exp, stale:$stale}')" \
    || { err "Не удалось собрать data.json"; return 1; }

  printf '%s\n' "$data" > "${XKIT_DASH_DIR}/.data.json.tmp" \
    && mv -f "${XKIT_DASH_DIR}/.data.json.tmp" "${XKIT_DASH_DIR}/data.json" \
    || { err "Не удалось записать ${XKIT_DASH_DIR}/data.json"; return 1; }
  dash_fix_perms

  local ncnt ecnt stale_note=""
  ncnt="$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)"
  ecnt="$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)"
  [ "$stale" = "1" ] && stale_note=" (панель была недоступна — показаны данные прошлого построения)"
  ok "Дашборд построен: панель=${panel_st}, нод=${ncnt}, инбаундов=${ecnt}${stale_note}"
  log "Файлы: ${XKIT_DASH_DIR}/data.json; URL: https://${XKIT_HOST}$(dash_path)"
  return 0
}
