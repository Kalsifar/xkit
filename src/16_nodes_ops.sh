
node_add() {
  require_root
  command -v ssh >/dev/null 2>&1 || apt-get install -y -qq openssh-client >/dev/null 2>&1
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1

  echo ""
  echo -e "${YELLOW}=== Добавление ноды (зарубежный сервер) ===${NC}"
  local nname nhost nport nuser
  # EOF (Ctrl-D) на любом вводе — отмена, а не молчаливое продолжение
  # (симметрия с v3.2.1, ревью v4.7.0: на порту/юзере EOF давал дефолты
  # 22/root и попытку коннекта к ноде)
  read -r -p "Имя ноды (латиница, например de1): " nname || { echo; return 1; }
  [[ "$nname" =~ ^[a-zA-Z0-9_-]{1,20}$ ]] || { err "Имя: латиница/цифры/-/_ до 20 символов"; return 1; }
  jq -e --arg n "$nname" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
    && { err "Нода '$nname' уже есть"; return 1; }
  nhost="$(read_host "IP/домен ноды -> ")"
  read -r -p "SSH порт [22]: " nport || { echo; return 1; }
  nport="${nport:-22}"; is_port "$nport" || { err "Порт"; return 1; }
  read -r -p "SSH пользователь [root]: " nuser || { echo; return 1; }
  nuser="${nuser:-root}"
  # аудит №4: без валидации «a"b» уезжало в ssh/jq-реестр; допускаем то, что
  # легитимно для useradd: латиница/цифры/._-, не с цифры, до 32 символов
  [[ "$nuser" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || { err "SSH-пользователь: только латиница/цифры/._- (до 32 симв., не с цифры)"; return 1; }

  echo "Доступ: 1) пароль (один раз — поставим наш SSH-ключ, пароль не сохраняется)  2) путь к ключу"
  read -r -p "Выбор [1]: " am || { echo; return 1; }
  am="${am:-1}"
  local NODE_SSH_PASS="" nkey=""
  local rec_auth="key"
  if [ "$am" = "1" ]; then
    read -r -s -p "SSH пароль ${nuser}@${nhost}: " NODE_SSH_PASS || { echo; return 1; }
    echo ""
    [ -n "$NODE_SSH_PASS" ] || { err "Пустой пароль"; return 1; }
    rec_auth="password"
    nkey="$(node_own_key)"
  else
    nkey="$(node_own_key)"
    read -r -p "Путь к приватному ключу [${nkey}]: " nkey_in || { echo; return 1; }
    [ -n "$nkey_in" ] && nkey="$nkey_in"
    [ -f "$nkey" ] || { err "Ключ не найден: $nkey"; return 1; }
  fi

  local rec
  rec="$(jq -nc --arg n "$nname" --arg h "$nhost" --argjson p "$nport" --arg u "$nuser" \
         --arg a "$rec_auth" --arg k "$nkey" \
    '{name:$n, host:$h, ssh_port:$p, ssh_user:$u, auth:$a, key_path:$k}')"

  log "Проверяю SSH-доступ..."
  if [ "$rec_auth" = "password" ]; then
    node_ssh "$rec" "echo ok" 2>/dev/null | grep -q ok || { err "SSH по паролю не прошёл"; return 1; }
    local pub; pub="$(cat "${nkey}.pub")"
    node_ssh "$rec" "mkdir -p ~/.ssh && chmod 700 ~/.ssh; grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
      || { err "Не удалось установить ключ на ноде"; return 1; }
    rec="$(jq -c --arg k "$nkey" '.auth="key" | .key_path=$k' <<<"$rec")"
    ok "Наш ключ установлен на ноде — пароль больше не нужен (и не сохранён)"
  fi
  node_ssh "$rec" "echo ok" 2>/dev/null | grep -q ok || { err "SSH по ключу не прошёл"; return 1; }
  local kh; kh="${XKIT_DIR}/known_hosts"
  local fp; fp="$(awk -v h="[$nhost]:$nport" -v h2="$nhost" '$3==h || $3==h2 {print}' "$kh" 2>/dev/null \
    | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  [ -n "$fp" ] && ok "Ключ хоста ноды зафиксирован (TOFU; можно сверить с консолью провайдера): ${fp}"

  # (з.6, аудит v5.2.1): официальный установщик на ноде тоже бежит от root —
  # спрашиваем явно, если 3X-UI там ещё нет (XKIT_YES — для автоматизации)
  if ! node_ssh "$rec" "command -v x-ui >/dev/null 2>&1" >/dev/null 2>&1; then
    confirm "Скачать и запустить официальный установщик 3X-UI на ноде (от root)? [Y/n] " y \
      || { warn "Установка 3X-UI на ноде отменена"; return 1; }
  fi
  log "Устанавливаю 3X-UI на ноду (если его нет)..."
  # K-02: тот же тег-релиз, что и на мастере; URL валидирован в xui_install_url
  local xuiu; xuiu="$(xui_install_url)"
  node_ssh "$rec" "XUI_URL='${xuiu}' bash -s" <<'EOS' || { err "Установка 3X-UI на ноде не удалась"; return 1; }
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq curl sqlite3 >/dev/null 2>&1; }
if ! command -v x-ui >/dev/null 2>&1; then
  DL="$(mktemp)"
  curl -fsSL "${XUI_URL:?}" -o "$DL" \
    || { echo "ERR: не удалось скачать установщик 3X-UI"; rm -f "$DL"; exit 1; }
  bash -n "$DL" || { echo "ERR: установщик 3X-UI не проходит bash -n (K-02)"; rm -f "$DL"; exit 1; }
  XUI_NONINTERACTIVE=1 bash "$DL" </dev/null
  rm -f "$DL"
fi
systemctl enable --now x-ui >/dev/null 2>&1 || true
EOS

  local np_user np_pass np_port
  np_user="kit$(rand_hex 2)"
  np_pass="$(rand_str 16)"
  np_port="$(shuf -i 20000-50000 -n 1)"
  log "Настраиваю панель ноды (случайный логин/пароль/порт)..."
  node_ssh "$rec" "/usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' -port '${np_port}' >/dev/null 2>&1 || /usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' >/dev/null 2>&1 || true"
  node_ssh "$rec" "systemctl restart x-ui" || true
  log "Включаю HTTPS (самоподписанный сертификат) для панели ноды — креды не пойдут по HTTP..."
  node_ssh "$rec" 'bash -s' <<'EOS' || warn "HTTPS панели ноды не включился — останется HTTP"
C=/etc/x-ui/panel-cert.pem; K=/etc/x-ui/panel-key.pem
if [ ! -s "$C" ] || [ ! -s "$K" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$K" 2>/dev/null \
    && openssl req -new -x509 -key "$K" -out "$C" -days 3650 \
       -subj "/CN=node-panel" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
  chmod 600 "$K" 2>/dev/null; chmod 644 "$C" 2>/dev/null
fi
if [ -s "$C" ] && [ -s "$K" ] && command -v sqlite3 >/dev/null 2>&1; then
  for kv in "webCertFile|$C" "webCertKey|$K"; do
    key="${kv%%|*}"; val="${kv#*|}"
    sqlite3 /etc/x-ui/x-ui.db \
      "INSERT INTO settings (key,value) VALUES('$key','$val') ON CONFLICT(key) DO UPDATE SET value=excluded.value;" 2>/dev/null \
      || sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key,value) VALUES('$key','$val');" 2>/dev/null || true
  done
  systemctl restart x-ui
fi
EOS
  sleep 3
  local nbase
  nbase="$(node_ssh "$rec" "/usr/local/x-ui/x-ui setting -show true 2>/dev/null" \
           | awk -F': ' '/webBasePath/{print $2; exit}' | tr -d '[:space:]')"
  nbase="$(normalize_panel_path "${nbase:-/}")"
  rec="$(jq -c --argjson pp "$np_port" --arg u "$np_user" --arg p "$np_pass" --arg b "$nbase" \
        '.panel = {port:$pp, user:$u, pass:$p, base:$b, tls:true}' <<<"$rec")"
  local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
  if ! node_login "$rec" "$ck"; then
    warn "Логин по HTTPS не прошёл — пробую HTTP (сертификат панели не применился?)"
    rec="$(jq -c '.panel.tls = false' <<<"$rec")"
    node_login "$rec" "$ck" || { err "Логин в панель ноды (порт ${np_port}${nbase}) не прошёл"; rm -f "$ck"; return 1; }
  fi
  local psch="http"; jq -e '.panel.tls == true' <<<"$rec" >/dev/null 2>&1 && psch="https"
  ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (снаружи доступ ограничен IP мастера)"
  if [ "$psch" = "https" ]; then
    local npin
    npin="$(cert_pin "$nhost" "$np_port")"
    if [ -n "$npin" ]; then
      rec="$(jq -c --arg p "$npin" '.panel.pincert = $p' <<<"$rec")"
      ok "Сертификат панели ноды запинен (sha256//$(printf '%s' "$npin" | head -c 16)...) — MITM на API не пройдёт"
    else
      warn "Не удалось снять пин сертификата панели — node_api будет без пина (перепинить: xkit nodes repin ${nname})"
    fi
  fi

  local tport tp
  if node_ssh "$rec" "ss -ltn 2>/dev/null | grep -q ':443 '" 2>/dev/null; then
    warn "На ноде порт 443 занят — предлагаю 8443"
    tport=8443
  else
    tport=443
  fi
  # (з.9, аудит v5.2.1): EOF/Ctrl-D отменяет ввод, как у соседних полей, а не молча ставит дефолт
  read -r -p "Порт туннеля на ноде [${tport}]: " tp || { echo; return 1; }; tp="${tp:-$tport}"; is_port "$tp" || { err "Порт"; return 1; }

  echo "Dest (прикрытие) для Reality на ноде:"
  echo "  1) 1.1.1.1 (быстро и надёжно)   2) известный список   3) СКАН С САМОЙ НОДЫ"
  local mdest msni
  mdest="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.dest // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  msni="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.serverNames[0] // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  if [ -n "$mdest" ] && [ -n "$msni" ]; then
    echo "  4) как на мастере (${mdest}, SNI ${msni})"
  else
    echo "  4) как на мастере (на мастере Reality-инбаунд не найден — недоступно)"
  fi
  echo "  5) вручную"
  read -r -p "Выбор [1]: " dc; dc="${dc:-1}"
  local ndest="" nsni="" RDEST="" RSNI=""
  case "$dc" in
    2) reality_known_pick || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
    3) node_reality_scan_pick "$rec" || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
    4) [ -n "$mdest" ] && [ -n "$msni" ] || { err "На мастере нет Reality — выберите другой вариант"; return 1; }
       ndest="$mdest"; nsni="$msni" ;;
    5)
      local dh dp
      dh="$(read_host "dest -> ")"
      read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
      nsni="$(read_host "SNI -> ")"
      ndest="${dh}:${dp}" ;;
    *) ndest="1.1.1.1:443"; nsni="cloudflare-dns.com" ;;
  esac

  log "Генерирую ключи Reality для ноды..."
  local priv pub tuuid tsid
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; rm -f "$ck"; return 1; }
  tuuid="$(new_uuid)"; tsid="$(rand_hex 4)"

  local nsettings nstream nib
  nsettings="$(jq -nc --arg id "$tuuid" --arg sn "$nname" --arg sub "$(rand_str 16)" '
    {clients:[{id:$id, flow:"xtls-rprx-vision", email:("tunnel-"+$sn), limitIp:0, totalGB:0,
               expiryTime:0, enable:true, tgId:"", subId:$sub, reset:0}],
     decryption:"none", fallbacks:[]}')"
  nstream="$(jq -nc --arg dest "$ndest" --arg sni "$nsni" --arg priv "$priv" --arg sid "$tsid" --arg pub "$pub" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni], privateKey:$priv,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}')"
  nib="$(jq -nc --arg port "$tp" --arg tag "inbound-${tp}" --arg remark "xkit-tunnel-${nname}" \
        --arg s "$nsettings" --arg st "$nstream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0, listen:"",
     port:($port|tonumber), protocol:"vless", settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"
  log "Создаю туннельный inbound на ноде (VLESS+Reality, порт ${tp})..."
  local out
  out="$(node_api "$rec" "panel/api/inbounds/add" POST "$nib" "$ck")"
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "Нода: создание inbound не прошло: $(jq -r '.msg // "?"' <<<"$out" | head -c 200)"
    rm -f "$ck"; return 1
  fi
  ok "Туннельный inbound на ноде создан"

  local myip
  myip="$(pubip)"   # только валидный IP; иначе ufw настрою без правила для панели
  is_ip "$myip" || myip=""   # страховка: в env уходит либо валидный IP, либо пусто
  log "Настраиваю ufw на ноде (SSH ${nport} + туннель ${tp}/tcp; панель — только с IP мастера)..."
  # ВАЖНО: все переменные — через env (heredoc quoted, локальные ${...} туда не попадают).
  # set -u + :? гарантируют: при потере переменной скрипт упадёт ДО ufw --force enable,
  # иначе нода уходит в lockout (SSH/туннель отрезаны). Вывод ufw allow НЕ глушится.
  node_ssh "$rec" "env MYIP='${myip}' NPORT='${nport}' TP='${tp}' NPP='${np_port}' bash -s" <<'EOS' \
  || warn "UFW на ноде НЕ настроен — проверьте firewall вручную (правила могли не примениться)"
set -u
export DEBIAN_FRONTEND=noninteractive
: "${NPORT:?нет NPORT}"; : "${TP:?нет TP}"; : "${NPP:?нет NPP}"
command -v ufw >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq ufw >/dev/null 2>&1; }
command -v ufw >/dev/null 2>&1 || { echo "ERR: ufw не установился"; exit 1; }
ufw allow "${NPORT}/tcp" || { echo "ERR: правило SSH (${NPORT}/tcp) не применилось"; exit 1; }
ufw allow "${TP}/tcp"    || { echo "ERR: правило туннеля (${TP}/tcp) не применилось"; exit 1; }
if [ -n "${MYIP:-}" ]; then
  ufw allow from "${MYIP}" to any port "${NPP}" proto tcp || { echo "ERR: правило панели (${NPP})"; exit 1; }
else
  # IP мастера не определён (pubip/DNS/РКН) — НЕ оставляем панель ноды в интернете:
  # иначе ufw enable с default DROP, но панель слушает 0.0.0.0 и остаётся доступной
  ufw deny "${NPP}/tcp" || { echo "ERR: не удалось закрыть панель (${NPP}) в ufw"; exit 1; }
  echo "WARN: IP мастера неизвестен — панель ноды закрыта в ufw (доступ только через SSH-туннель)"
fi
ufw --force enable || { echo "ERR: ufw enable не прошёл"; exit 1; }
echo "UFW на ноде: правила применены, firewall активен"
EOS
  if [ -z "$myip" ]; then
    warn "Публичный IP мастера не определён — панель ноды (${np_port}/tcp) ЗАКРЫТА в ufw."
    warn "Доступ к панели ноды — через SSH-туннель: ssh -p ${nport} -L ${np_port}:127.0.0.1:${np_port} ${nuser}@${nhost}"
  fi

  rec="$(jq -c --argjson tport "$tp" --arg uuid "$tuuid" --arg pbk "$pub" --arg sid "$tsid" \
         --arg sni "$nsni" --arg dest "$ndest" --arg tag "node-${nname}" --arg created "$(date -Is)" \
    '.tunnel = {port:$tport, proto:"vless", net:"tcp", sec:"reality", uuid:$uuid, pbk:$pbk,
                sid:$sid, sni:$sni, dest:$dest, flow:"xtls-rprx-vision"}
      | .outbound_tag = $tag | .created = $created' <<<"$rec")"
  nodes_load | jq -c --argjson r "$rec" 'map(select(.name != $r.name)) + [$r]' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  chmod 600 "$XKIT_NODES"
  rm -f "$ck"

  local apply_failed=0
  log "Готовлю pool-инбаунд на мастере (вход для клиентов с балансировкой)..."
  nodes_ensure_pool || apply_failed=1
  log "Применяю аутбаунды нод + balancer к xray на мастере..."
  nodes_apply_template || apply_failed=1
  if [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    local pool_ib pool_cl plink
    pool_ib="$(api_get_inbound "$XKIT_POOL_INBOUND")" || true
    pool_cl="$(jq -c '.settings|fromjson?|.clients[0] // empty' <<<"${pool_ib:-}")"
    if [ -n "$pool_cl" ]; then
      plink="$(link_for_client "${pool_ib:-}" "$pool_cl")"
      [ -n "$plink" ] && { echo ""; ok "Ссылка ПОЛА (трафик балансируется по нодам):"; printf '  %s\n' "$plink"; }
    fi
  fi
  read -r -p "Срок аренды ноды '${nname}' (YYYY-MM-DD, Enter — пропустить): " dex
  if [ -n "$dex" ]; then
    if expiry_set node "$nname" "$dex" ""; then
      ok "Срок аренды сохранён: ${dex} (виден в веб-дашборде и xkit expiry list)"
    else
      warn "Дата не распознана — задайте позже: xkit expiry set ${nname} YYYY-MM-DD"
    fi
  fi
  echo ""
  if [ "${apply_failed:-0}" = "0" ]; then
    echo -e "${GREEN}=== Нода '${nname}' подключена ===${NC}"
  else
    err "=== Нода '${nname}' в реестре, но конфиг НЕ применён — трафик на неё не пойдёт ==="
    warn "Выполните: xkit (меню) -> пункт 2 (автопроброс), затем НОДЫ -> health"
  fi
  ok "Туннель: мастер -> ${nhost}:${tp} (VLESS+Reality, SNI ${nsni})"
  ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (ufw: доступ только с IP мастера)"
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-roundRobin} (сменить: Ноды -> стратегия)"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

# повторное применение конфигурации после сбоя apply: нода могла остаться
# «в реестре, но без маршрута». Проверяет туннельные инбаунды на нодах,
# pool на мастере и аутбаунды/balancer в шаблоне xray
nodes_repair() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  local bad=0 cnt
  cnt="$(nodes_load 2>/dev/null | jq -r 'length' 2>/dev/null)"
  cnt="${cnt:-0}"
  if [ "$cnt" -eq 0 ]; then
    warn "Нод в реестре нет — repair просто пересоберёт конфиг мастера (pool + маршруты)"
  else
    log "Проверяю туннельные инбаунды на нодах..."
    local rec nm tport ttag inb_id ck
    while IFS= read -r rec; do
      [ -z "$rec" ] && continue
      nm="$(jq -r '.name' <<<"$rec")"
      tport="$(jq -r '.tunnel.port // empty' <<<"$rec")"
      if [ -z "$tport" ]; then
        warn "${nm}: в записи нет tunnel.port — пропускаю"
        continue
      fi
      ttag="inbound-${tport}"
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck" >/dev/null 2>&1; then
        inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
          | jq -r --arg t "$ttag" '[.obj[]?|select(.tag==$t)][0].id // empty' 2>/dev/null)"
        if [ -n "$inb_id" ]; then
          ok "${nm}: туннельный inbound на месте (#${inb_id})"
        else
          err "${nm}: туннельного inbound (${ttag}) НЕТ на ноде — переподключите ноду (удалить + добавить)"
          bad=1
        fi
      else
        warn "${nm}: панель ноды недоступна — inbound проверить не смог"
        bad=1
      fi
      rm -f "$ck"
    done < <(jq -c '.[]' <(nodes_load))
  fi
  log "Pool-инбаунд на мастере (пересоздам, если маршрута нет)..."
  nodes_ensure_pool || bad=1
  log "Аутбаунды нод + balancer в шаблоне xray..."
  nodes_apply_template || bad=1
  if [ "$bad" -eq 0 ]; then
    ok "Repair завершён: конфигурация применена"
    xkit_summary_save >/dev/null 2>&1 || true
  else
    err "Repair: остались проблемы (см. выше) — проверьте nginx -t и панели нод"
    return 1
  fi
  return 0
}

# перепинить отпечаток сертификата панели ноды (после перевыпуска серта на ноде)
node_repin() { # $1 имя ноды или all
  load_xkit_env || die "Сначала установка (пункт 1)"
  local want="${1:-all}" arr n pin any=0 old_pin yn
  arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n="$(jq -r '.name' <<<"$rec")"
    [ "$want" = "all" ] || [ "$want" = "$n" ] || continue
    any=1
    if [ "$(jq -r '.panel.tls // "false"' <<<"$rec")" != "true" ]; then
      warn "${n}: панель ноды по HTTP — пиновать нечего"
      continue
    fi
    pin="$(cert_pin "$(jq -r '.host' <<<"$rec")" "$(jq -r '.panel.port' <<<"$rec")")"
    if [ -n "$pin" ]; then
      # TOFU (аудит №4): молча принять ИЗМЕНИВШИЙСЯ пин = легитимизировать
      # возможный MITM. Первый пин (пустой старый) принимается без вопросов
      old_pin="$(jq -r --arg n "$n" 'map(select(.name==$n))[0].panel.pincert // ""' <<<"$arr" 2>/dev/null)"
      if [ -n "$old_pin" ] && [ "$old_pin" != "$pin" ]; then
        warn "${n}: пин ИЗМЕНИЛСЯ (старый: $(printf '%s' "$old_pin" | head -c 16)..., новый: $(printf '%s' "$pin" | head -c 16)...)"
        yn="n"
        if [ -t 0 ]; then
          read -r -p "Принять новый пин? [y/N]: " yn
        else
          warn "${n}: stdin не tty — пин НЕ обновляется (запустите интерактивно)"
        fi
        if ! [[ "$yn" =~ ^[Yy] ]]; then
          warn "${n}: пин не обновлён (если серт не перевыпускали — возможно, MITM'ится)"
          continue
        fi
      fi
      nodes_load | jq -c --arg n "$n" --arg p "$pin" \
        'map(if .name==$n then .panel.pincert=$p else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      ok "${n}: пин обновлён (sha256//$(printf '%s' "$pin" | head -c 16)... )"
    else
      err "${n}: не удалось снять отпечаток сертификата (нода доступна?)"
    fi
  done < <(jq -c '.[]' <<<"$arr")
  [ "$any" = "1" ] || { err "Нода '${want}' не найдена (xkit nodes repin <имя|all>)"; return 1; }
  return 0
}

nodes_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет — добавьте (Ноды -> добавить)"; return 0; }
  echo ""
  printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "ИМЯ" "ХОСТ" "SSH" "ТУННЕЛЬ" "SNI" "ПАНЕЛЬ"
  echo "-------------------------------------------------------------------------------"
  local n h sp tp sni pp
  while IFS=$'\t' read -r n h sp tp sni pp; do
    printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "$n" "$h" "$sp" "$tp" "$sni" "$pp"
  done < <(jq -r '.[] | [.name, .host, (.ssh_port|tostring), (.tunnel.port|tostring), .tunnel.sni, (.panel.port|tostring)] | @tsv' <<<"$arr")
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-roundRobin}"
  return 0
}

nodes_health() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  # fails = туннель/панель, ssh_fails = SSH недоступен (аудит №2: раньше SSH-провал
  # не считался, и при живом туннеле печатались [ВНИМ], а финал был «Все ноды живы»)
  local arr cnt fails=0 ssh_fails=0
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  echo ""
  local rec name host tport ck
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if ! timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
      echo "  [СБОЙ] ${name}: туннель ${host}:${tport} недоступен"
      fails=$((fails+1))
      continue
    fi
    # (баг №3, аудит v5.2.1): systemctl is-active возвращает 3 для inactive — это
    # НЕ провал SSH. Разделяем: «active» / SSH-провал (255, timeout 124) / x-ui не активен
    local svc_out rc
    svc_out="$(node_ssh "$rec" "systemctl is-active x-ui" 2>/dev/null)"; rc=$?
    if [ "$svc_out" = "active" ]; then
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck"; then
        echo "  [OK]   ${name}: туннель :${tport}, x-ui работает, панель отвечает"
      else
        echo "  [ВНИМ] ${name}: туннель жив, но панель ноды не логинится"
        fails=$((fails+1))
      fi
      rm -f "$ck"
    elif [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ]; then
      echo "  [ВНИМ] ${name}: туннель жив, SSH до ноды не прошёл (x-ui проверьте руками)"
      ssh_fails=$((ssh_fails+1))
    else
      echo "  [ВНИМ] ${name}: туннель жив, x-ui не активен (systemctl: ${svc_out:-код $rc})"
      fails=$((fails+1))
    fi
  done < <(jq -c '.[]' <<<"$arr")
  if [ "$fails" -gt 0 ]; then
    err "Проблемы на ${fails} нодах"
  elif [ "$ssh_fails" -gt 0 ]; then
    warn "Туннели живы, но SSH недоступен на ${ssh_fails} нод(ах) — x-ui/конфиг там проверьте руками"
  else
    ok "Все ноды живы"
  fi
  return 0
}

nodes_strategy() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo "Стратегия балансировки (xray balancer):"
  echo "1) roundRobin — по кругу (по умолчанию)"
  echo "2) random     — случайно"
  echo "3) leastPing  — УМНАЯ: observatory пингует ноды, трафик идёт на самую быструю"
  echo "4) leastLoad  — УМНАЯ: burst-замеры, выбор наименее загруженной/быстрой"
  read -r -p "Выбор [1-4]: " s
  case "$s" in
    1) XKIT_BAL_STRATEGY="roundRobin" ;;
    2) XKIT_BAL_STRATEGY="random" ;;
    3) XKIT_BAL_STRATEGY="leastPing" ;;
    4) XKIT_BAL_STRATEGY="leastLoad" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  save_xkit_env
  log "Применяю стратегию ${XKIT_BAL_STRATEGY} к конфигу xray..."
  nodes_apply_template || return 1
  ok "Готово. При leastPing/leastLoad xray сам переключает трафик на живые ноды (observatory)."
  return 0
}

nodes_del() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  nodes_list
  local n rec
  read -r -p "Имя ноды для удаления (Enter — отмена): " n
  [ -z "$n" ] && return 0
  rec="$(nodes_load | jq -c --arg n "$n" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || { err "Нода '$n' не найдена"; return 1; }
  read -r -p "Удалить ноду '$n' из конфигурации? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  read -r -p "Удалить туннельный inbound на самой ноде (через её API)? [Y/n]: " b
  if ! [[ "$b" =~ ^[Nn] ]]; then
    local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" 2>/dev/null; then
      local inb_id
      inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
        | jq -r --arg t "inbound-$(jq -r '.tunnel.port' <<<"$rec")" '[.obj[]?|select(.tag==$t)][0].id // empty')"
      if [ -n "$inb_id" ] && node_api "$rec" "panel/api/inbounds/del/${inb_id}" POST "" "$ck" >/dev/null 2>&1; then
        ok "Инбаунд на ноде удалён"
      else
        warn "Инбаунд ноды не удалён (не критично)"
      fi
    else
      warn "Панель ноды недоступна — inbound не удалял"
    fi
    rm -f "$ck"
  fi
  read -r -p "Остановить x-ui на ноде? [y/N]: " c2
  if [[ "$c2" =~ ^[Yy] ]]; then
    node_ssh "$rec" "systemctl stop x-ui; systemctl disable x-ui" >/dev/null 2>&1 \
      && ok "x-ui на ноде остановлен" || warn "Не удалось остановить (проверьте доступ)"
  fi
  nodes_load | jq -c --arg n "$n" 'map(select(.name != $n))' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  kit_session >/dev/null 2>&1 || true
  nodes_apply_template || warn "Шаблон xray не обновился"
  # v4.5: последняя нода удалена — убираем pool-инбаунд целиком. Иначе pool
  # остаётся в панели/маршрутах, а правило balancer уже исчезло (nodes.json
  # пуст): ссылки пула продолжали бы работать, молча меняя выход на IP мастера
  local cnt0; cnt0="$(nodes_load | jq 'length' 2>/dev/null || echo 0)"
  if [ "$cnt0" -eq 0 ] && [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    warn "Это была последняя нода — убираю pool-инбаунд (переход в одиночный режим)"
    pool_remove_force || warn "Pool не убрался полностью: НОДЫ -> пункт 8 (убрать pool)"
  fi
  ok "Нода '$n' удалена; аутбаунд убран, балансировка пересчитана"
  return 0
}

# v4.5: полностью убрать pool-инбаунд — переход мастер -> одиночный.
# ВАЖНО: nodes_merge_template при пустом nodes.json уже убрал правило
# balancer, поэтому трафик pool-инбаунда пошёл бы напрямую с мастера —
# ссылки пула в подписках молча меняли бы exit-IP. Убираем всё: инбаунд
# в панели + маршрут nginx + env, затем ОБЯЗАТЕЛЬНО перегенерация подписок.
pool_remove_force() { # без вопросов — для nodes_del и меню
  local id="${XKIT_POOL_INBOUND:-}"
  [ -n "$id" ] || { warn "Pool не настроен — сервер уже в одиночном режиме"; return 0; }
  # 1) инбаунд в панели (если панель жива)
  if kit_session >/dev/null 2>&1; then
    if api_del_inbound "$id" 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Pool-инбаунд #${id} удалён из панели"
    else
      warn "Панель не удалила pool-инбаунд #${id} — проверьте вручную"
    fi
  else
    warn "Панель недоступна: pool-инбаунд #${id} остался в панели (удалите вручную), маршрут уберу"
  fi
  # 2) маршрут nginx + переменные
  routes_del "$id"
  XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  save_xkit_env
  # 3) пересобрать nginx и подписки: ссылки пула исчезают — клиенты должны
  # обновить подписку (она обновится сама при следующем запросе клиента)
  regen_conf_and_apply || { err "Конфиг nginx не применился — выполните: xkit nodes repair"; return 1; }
  sub_regen_quiet || true
  warn "Ссылки пула исчезли из подписок — клиентам нужно обновить подписку (происходит автоматически)"
  ok "Сервер переведён в одиночный режим"
  return 0
}

pool_remove() { # интерактивно (пункт меню НОДЫ -> 8)
  load_xkit_env || die "Сначала установка (пункт 1)"
  local id="${XKIT_POOL_INBOUND:-}"
  if [ -z "$id" ]; then
    warn "Pool не настроен — сервер в одиночном режиме"
    return 0
  fi
  echo ""
  warn "Будет удалён pool-инбаунд #${id}: клиенты перестанут ходить через ноды"
  read -r -p "Перевести сервер в одиночный режим? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  pool_remove_force
}

nodes_menu() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== НОДЫ: главный сервер -> туннель до нод, балансировка ===${NC}"
    echo " 1) Добавить ноду по SSH (3X-UI + Reality-туннель + балансировка)"
    echo " 2) Список нод"
    echo " 3) Health-check нод"
    echo " 4) Стратегия балансировки (roundRobin/random/leastPing/leastLoad)"
    echo " 5) Удалить ноду"
    echo " 6) Repair: переприменить конфигурацию нод (после сбоя apply)"
    echo " 7) Перепинить сертификат панели ноды (MITM-защита API)"
    echo " 8) Убрать pool — вернуть сервер в одиночный режим (v4.5)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) node_add; pause_enter ;;
      2) nodes_list; pause_enter ;;
      3) nodes_health; pause_enter ;;
      4) nodes_strategy; pause_enter ;;
      5) nodes_del; pause_enter ;;
      6) nodes_repair; pause_enter ;;
      7) local _rw; read -r -p "Имя ноды (Enter — все): " _rw; node_repin "${_rw:-all}"; pause_enter ;;
      8) pool_remove; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}
