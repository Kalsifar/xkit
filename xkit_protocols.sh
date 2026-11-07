#!/bin/bash
# XKIT v5.3.1 — профили доступа: REALITY/XHTTP через 3X-UI, AWG/Hy2 отдельно.
# Подключается только из xkit.sh. Секреты не выводятся в status/list --json.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Это модуль XKIT — запускайте: xkit protocols" >&2
  exit 1
fi

XKIT_PROTOCOLS_ENV="${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}"
XKIT_HY2_BIN="${XKIT_HY2_BIN:-/usr/local/bin/xkit-hysteria2}"
XKIT_HY2_CONF="${XKIT_HY2_CONF:-/etc/xkit/hysteria2/config.yaml}"
XKIT_HY2_UNIT="${XKIT_HY2_UNIT:-/etc/systemd/system/xkit-hysteria2.service}"
XKIT_AWG_CONF="${XKIT_AWG_CONF:-/etc/amnezia/amneziawg/awg0.conf}"
XKIT_AWG_CLIENTS_DIR="${XKIT_AWG_CLIENTS_DIR:-/root/xkit-awg}"
XKIT_AWG_STATE="${XKIT_AWG_STATE:-/etc/xkit/awg-clients.tsv}"
XKIT_AWG_SYSCTL="${XKIT_AWG_SYSCTL:-/etc/sysctl.d/99-xkit-awg.conf}"

proto_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
proto_json_status() { # id title kind installed status details
  jq -nc --arg id "$1" --arg title "$2" --arg kind "$3" --arg installed "$4" \
    --arg status "$5" --arg details "$6" \
    '{id:$id,title:$title,kind:$kind,installed:($installed=="1" or $installed=="true"),status:$status,details:$details}'
}

protocols_snapshot_json() {
  local reality=0 xhttp=0 inbounds="" awg_i=false hy2_i=false awg_s="not-installed" hy2_s="not-installed"
  local awg_d="PPA AmneziaWG" hy2_d="UDP + Salamander" r_d="3X-UI / TCP" x_d="3X-UI / XHTTP"
  if kit_session >/dev/null 2>&1; then
    inbounds="$(api_list 2>/dev/null || true)"
    if jq -e '[.[]?|select(.protocol=="vless")|(.streamSettings|fromjson?)|select(.security=="reality" and (.network=="tcp" or .network=="raw"))]|length>0' <<<"$inbounds" >/dev/null 2>&1; then reality=1; r_d="3X-UI / TCP / Vision"; fi
    if jq -e '[.[]?|select(.protocol=="vless")|(.streamSettings|fromjson?)|select(.security=="reality" and (.network=="xhttp" or .network=="splithttp"))]|length>0' <<<"$inbounds" >/dev/null 2>&1; then xhttp=1; x_d="3X-UI / XHTTP / REALITY"; fi
  fi
  [ -f "$XKIT_AWG_CONF" ] && { awg_i=true; awg_d="AWG / UDP"; }
  [ -f "$XKIT_HY2_CONF" ] && { hy2_i=true; hy2_d="Hy2 / UDP / Salamander"; }
  if [ "$awg_i" = true ]; then proto_service_active awg-quick@awg0 && awg_s="active" || awg_s="inactive"; fi
  if [ "$hy2_i" = true ]; then proto_service_active xkit-hysteria2 && hy2_s="active" || hy2_s="inactive"; fi
  jq -n \
    --argjson reality "$(proto_json_status reality 'VLESS REALITY Vision' xray "$reality" "$([ "$reality" = 1 ] && echo configured || echo available)" "$r_d")" \
    --argjson xhttp "$(proto_json_status xhttp 'VLESS XHTTP REALITY' xray "$xhttp" "$([ "$xhttp" = 1 ] && echo configured || echo available)" "$x_d")" \
    --argjson awg "$(proto_json_status awg AmneziaWG service "$awg_i" "$awg_s" "$awg_d")" \
    --argjson hy2 "$(proto_json_status hy2 'Hysteria 2' service "$hy2_i" "$hy2_s" "$hy2_d")" \
    '[$reality,$xhttp,$awg,$hy2]'
}

protocols_list() {
  local j; j="$(protocols_snapshot_json)"
  if [ "${1:-}" = "--json" ]; then printf '%s\n' "$j"; return; fi
  printf '%-14s %-18s %-16s %s\n' ID ТИП СТАТУС ПРОФИЛЬ
  jq -r '.[]|[.id,.kind,.status,.details]|@tsv' <<<"$j" | while IFS=$'\t' read -r id kind st details; do
    printf '%-14s %-18s %-16s %s\n' "$id" "$kind" "$st" "$details"
  done
}

# Общий выбор dest/SNI для REALITY; результаты PROTO_DEST и PROTO_SNI.
proto_reality_target_pick() {
  echo "1) Свой сайт и сертификат XKIT"
  echo "2) Скан подсети"
  echo "3) Проверенный список"
  echo "4) Вручную"
  read -r -p "Источник REALITY [1-4]: " c || return 1
  PROTO_DEST=""; PROTO_SNI=""
  case "$c" in
    1)
      [ "$(host_kind "${XKIT_HOST:-}")" = domain ] && [ -f "${XKIT_CRT:-}" ] || { err "Нужен домен и сертификат"; return 1; }
      camo_site_install || return 1
      XKIT_REALITY_INTERNAL=1; save_xkit_env; regen_conf_and_apply || return 1
      PROTO_DEST="127.0.0.1:8444"; PROTO_SNI="$XKIT_HOST" ;;
    2) reality_scan_pick || return 1; PROTO_DEST="$RDEST"; PROTO_SNI="$RSNI" ;;
    3) reality_known_pick || return 1; PROTO_DEST="$RDEST"; PROTO_SNI="$RSNI" ;;
    4)
      local dh dp
      dh="$(read_host 'dest (IP или домен) -> ')" || return 1
      read -r -p 'Порт dest [443]: ' dp; dp="${dp:-443}"; is_port "$dp" || return 1
      PROTO_SNI="$(read_host 'SNI -> ')" || return 1; PROTO_DEST="${dh}:${dp}" ;;
    *) return 1 ;;
  esac
}

# VLESS + XHTTP + REALITY. Vision специально не добавляем: он для TCP/RAW.
proto_xhttp_create() {
  require_root; load_xkit_env || die "Сначала установка XKIT"; kit_session || return 1
  proto_reality_target_pick || return 1
  local p path uuid subid email sid priv pub
  p="$(rand_free_port 10000 60000)" || return 1
  read -r -p "Публичный порт XHTTP [${p}]: " pin; p="${pin:-$p}"
  is_port "$p" || { err "Некорректный порт"; return 1; }
  ! port_busy "$p" || { err "Порт $p занят"; return 1; }
  path="/xh-$(rand_str 8)"
  read -r -p "XHTTP path [${path}]: " pin; path="${pin:-$path}"
  is_nginx_path "$path" || { err "Небезопасный XHTTP path"; return 1; }
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Нет ключей x25519"; return 1; }
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="xhttp-$(rand_hex 2)"; sid="$(rand_hex 4)"
  local settings stream ib
  settings="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" '{clients:[{id:$id,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,reset:0}],decryption:"none",fallbacks:[]}')"
  stream="$(jq -nc --arg dest "$PROTO_DEST" --arg sni "$PROTO_SNI" --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" --arg path "$path" '
    {network:"xhttp",security:"reality",
     xhttpSettings:{path:$path,host:"",mode:"auto"},
     realitySettings:{show:false,xver:0,dest:$dest,serverNames:[$sni],privateKey:$priv,
       minClient:"",maxClient:"",maxTimeDiff:0,shortIds:[$sid],
       settings:{publicKey:$pub,fingerprint:"chrome",serverName:""}}}')"
  ib="$(jq -nc --arg port "$p" --arg tag "inbound-${p}" --arg remark "xhttp-reality-${PROTO_SNI}" --arg s "$settings" --arg st "$stream" '
    {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:($port|tonumber),protocol:"vless",settings:$s,streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:$tag}')"
  api_add_inbound "$ib" || return 1
  local ibid fresh cl link
  ibid="$(jq -r --arg t "inbound-${p}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$(api_list 2>/dev/null)")"
  [ -n "$ibid" ] || { err "Inbound создан, но не найден для проверки"; return 1; }
  fresh="$(api_get_inbound "$ibid")" || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err "Проверка не удалась — inbound удалён"; return 1; }
  if [ "$API_V3" = 1 ]; then v3_host_upsert "$ibid" "$XKIT_HOST" "$p" same || warn "Host-группу настройте в панели"; else
    fresh="$(jq -c --arg d "$XKIT_HOST" --argjson p "$p" '.externalProxy=[{dest:$d,port:$p,remark:"xkit"}]' <<<"$fresh")"
    api_update_inbound "$ibid" "$fresh" >/dev/null || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err "externalProxy не применён — откат"; return 1; }
    fresh="$(api_get_inbound "$ibid")" || return 1
  fi
  xkit_fw_add xhttp "$p" tcp || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err 'Не удалось открыть TCP-порт XHTTP — inbound удалён'; return 1; }
  cl="$(jq -c '.settings|fromjson?|.clients[0]' <<<"$fresh")"
  link="$(link_for_client "$fresh" "$cl")"
  ok "XHTTP + REALITY создан: ${XKIT_HOST}:${p}${path}"
  [ -z "$link" ] || printf '\n%s\n' "$link"
  sub_regen_quiet || true
  printf '\nПодписка: https://%s%s%s\n' "$XKIT_HOST" "$(sub_path)" "$subid"
}

proto_state_load() { [ -r "$XKIT_PROTOCOLS_ENV" ] && . "$XKIT_PROTOCOLS_ENV"; }
proto_state_save() {
  mkdir -p "$(dirname "$XKIT_PROTOCOLS_ENV")" || return 1
  local t; t="$(mktemp /tmp/.xkit-protocols.XXXXXX)" || return 1
  chmod 600 "$t"
  { printf 'HY2_PORT=%q\n' "${HY2_PORT:-}"; printf 'HY2_AUTH=%q\n' "${HY2_AUTH:-}"; printf 'HY2_OBFS=%q\n' "${HY2_OBFS:-}";
    printf 'AWG_PORT=%q\n' "${AWG_PORT:-}"; printf 'AWG_SERVER_PUB=%q\n' "${AWG_SERVER_PUB:-}"; printf 'AWG_DEV=%q\n' "${AWG_DEV:-}"; } >"$t" && mv -f "$t" "$XKIT_PROTOCOLS_ENV"
}

proto_hy2_download() { # $1 destination
  local meta tag asset base sums want got arch
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) err "Hysteria 2: неподдерживаемая архитектура $arch"; return 1 ;; esac
  meta="$(mktemp /tmp/.xkit-hy2-meta.XXXXXX)" || return 1
  curl -fsSL --max-time 30 'https://api.github.com/repos/apernet/hysteria/releases/latest' -o "$meta" || { rm -f "$meta"; return 1; }
  tag="$(jq -r '.tag_name // empty' "$meta")"; asset="hysteria-linux-${arch}"
  base="$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' "$meta" | head -n1)"
  [ -n "$tag" ] && [ -n "$base" ] || { rm -f "$meta"; err "Не найден официальный бинарник $asset"; return 1; }
  sums="$(mktemp /tmp/.xkit-hy2-sums.XXXXXX)" || { rm -f "$meta"; return 1; }
  curl -fsSL "${base%/*}/hashes.txt" -o "$sums" || { rm -f "$meta" "$sums"; return 1; }
  want="$(awk -v n="$asset" '$2==n || $2=="*"n {print $1;exit}' "$sums")"
  [ -n "$want" ] || { rm -f "$meta" "$sums"; err "В hashes.txt нет $asset — установка отменена"; return 1; }
  curl -fsSL "$base" -o "$1" || { rm -f "$meta" "$sums"; return 1; }
  got="$(sha256sum "$1" | awk '{print $1}')"
  rm -f "$meta" "$sums"
  [ "$want" = "$got" ] || { err "SHA-256 Hysteria 2 не совпал"; return 1; }
  ok "Hysteria 2 ${tag}: SHA-256 проверен"
}

proto_hy2_install() {
  require_root; load_xkit_env || die "Сначала установка XKIT"
  [ -n "${XKIT_HOST:-}" ] && [ -r "${XKIT_CRT:-}" ] && [ -r "${XKIT_KEY:-}" ] || { err "Нужны XKIT_HOST и сертификат"; return 1; }
  if [ -f "$XKIT_HY2_CONF" ]; then warn "Hysteria 2 уже настроен"; return 0; fi
  local p; p="$(rand_free_port 20000 60000)" || return 1
  read -r -p "UDP-порт Hysteria 2 [${p}]: " pin; p="${pin:-$p}"; is_port "$p" || return 1
  HY2_PORT="$p"; HY2_AUTH="$(rand_str 24)"; HY2_OBFS="$(rand_str 24)"
  local tmp; tmp="$(mktemp /tmp/.xkit-hy2-bin.XXXXXX)" || return 1
  proto_hy2_download "$tmp" || { rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$XKIT_HY2_CONF")" || { rm -f "$tmp"; return 1; }
  install -m 755 "$tmp" "$XKIT_HY2_BIN" || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  local ctmp; ctmp="$(mktemp /tmp/.xkit-hy2-conf.XXXXXX)" || return 1
  cat >"$ctmp" <<EOF
listen: :${HY2_PORT}
tls:
  cert: ${XKIT_CRT}
  key: ${XKIT_KEY}
auth:
  type: password
  password: ${HY2_AUTH}
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS}
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF
  install -m 600 "$ctmp" "$XKIT_HY2_CONF" || { rm -f "$ctmp"; return 1; }; rm -f "$ctmp"
  cat >"$XKIT_HY2_UNIT" <<EOF
[Unit]
Description=XKIT Hysteria 2
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${XKIT_HY2_BIN} server -c ${XKIT_HY2_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$XKIT_HY2_UNIT"
  systemctl daemon-reload && systemctl enable --now xkit-hysteria2 || { systemctl disable xkit-hysteria2 >/dev/null 2>&1 || true; rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; return 1; }
  sleep 1; proto_service_active xkit-hysteria2 || { journalctl -u xkit-hysteria2 -n 20 --no-pager; err "Служба не запустилась — конфиг удалён, бинарник оставлен"; systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true; rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; return 1; }
  if ! xkit_fw_add hysteria2 "$HY2_PORT" udp; then
    systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
    rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; systemctl daemon-reload
    err 'Не удалось открыть UDP-порт Hysteria 2 — установка откачена'; return 1
  fi
  if ! proto_state_save; then
    systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
    xkit_fw_remove hysteria2 "$HY2_PORT" udp >/dev/null 2>&1 || true
    rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; systemctl daemon-reload
    err 'Не удалось сохранить состояние Hysteria 2 — установка откачена'; return 1
  fi
  ok "Hysteria 2 запущен: UDP ${HY2_PORT}, Salamander включён"
  proto_hy2_link
}

proto_hy2_link() {
  proto_state_load; [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_AUTH:-}" ] || { err "Hysteria 2 не настроен"; return 1; }
  load_xkit_env || return 1
  local q="obfs=salamander&obfs-password=$(enc_uri "$HY2_OBFS")"
  [ "${XKIT_CERT_MODE:-}" = 4 ] && q+="&insecure=1" || q+="&sni=$(enc_uri "$XKIT_HOST")"
  printf 'hy2://%s@%s:%s?%s#%s\n' "$(enc_uri "$HY2_AUTH")" "$XKIT_HOST" "$HY2_PORT" "$q" "$(enc_uri 'XKIT-Hysteria2')"
}

proto_hy2_uninstall() {
  require_root; proto_state_load
  confirm "Остановить и удалить XKIT Hysteria 2?" || return 0
  systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
  rm -f "$XKIT_HY2_UNIT" "$XKIT_HY2_CONF"; systemctl daemon-reload
  [ -z "${HY2_PORT:-}" ] || xkit_fw_remove hysteria2 "$HY2_PORT" udp || warn 'Не удалось удалить правило XKIT Hysteria 2'
  HY2_PORT=""; HY2_AUTH=""; HY2_OBFS=""; proto_state_save
  ok "Служба и конфиг удалены; бинарник $XKIT_HY2_BIN оставлен"
}

proto_hy2_menu() {
  while :; do
    echo "1) Установить  2) Ссылка  3) Статус  4) Журнал  5) Удалить  0) Назад"
    read -r -p 'Hysteria 2: ' c || return
    case "$c" in
      1) proto_hy2_install ;; 2) proto_hy2_link ;;
      3) systemctl status xkit-hysteria2 --no-pager ;;
      4) journalctl -u xkit-hysteria2 -n 50 --no-pager ;;
      5) proto_hy2_uninstall ;; 0) return ;; *) warn 'Нет такого пункта' ;;
    esac
  done
}

proto_rand_range() { local min=$1 max=$2; awk -v s="$RANDOM$RANDOM" -v a="$min" -v b="$max" 'BEGIN{srand(s);print int(a+rand()*(b-a+1))}'; }
proto_awg_params() {
  AWG_S1="$(proto_rand_range 15 150)"; AWG_S2="$(proto_rand_range 15 150)"
  [ $((AWG_S1+56)) -ne "$AWG_S2" ] || AWG_S2=$((AWG_S2+1))
  AWG_H1="$(proto_rand_range 5 2147483647)"; AWG_H2="$(proto_rand_range 5 2147483647)"
  AWG_H3="$(proto_rand_range 5 2147483647)"; AWG_H4="$(proto_rand_range 5 2147483647)"
  while [ "$AWG_H2" = "$AWG_H1" ]; do AWG_H2="$(proto_rand_range 5 2147483647)"; done
  while [ "$AWG_H3" = "$AWG_H1" ] || [ "$AWG_H3" = "$AWG_H2" ]; do AWG_H3="$(proto_rand_range 5 2147483647)"; done
  while [ "$AWG_H4" = "$AWG_H1" ] || [ "$AWG_H4" = "$AWG_H2" ] || [ "$AWG_H4" = "$AWG_H3" ]; do AWG_H4="$(proto_rand_range 5 2147483647)"; done
}

proto_awg_rollback_install() {
  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  xkit_awg_route_remove "${AWG_DEV:-}" >/dev/null 2>&1 || true
  [ -z "${AWG_PORT:-}" ] || xkit_fw_remove awg "$AWG_PORT" udp >/dev/null 2>&1 || true
  rm -f "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
}

proto_awg_install() {
  require_root; load_xkit_env || die "Сначала установка XKIT"
  [ -f "$XKIT_AWG_CONF" ] && { warn 'AmneziaWG уже настроен'; return 0; }
  command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 || {
    log 'Установка официального пакета AmneziaWG из PPA...'
    apt-get update && apt-get install -y software-properties-common python3-launchpadlib gnupg2 || return 1
    # (мелочь №9, аудит v5.2.1): у -cloud/-HWE ядер заголовков точной версии может
    # не быть в репо — пробуем точную, иначе generic
    apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || {
      warn "linux-headers-$(uname -r) недоступны в репозитории — ставлю linux-headers-generic"
      apt-get install -y linux-headers-generic || return 1
    }
    add-apt-repository -y ppa:amnezia/ppa && apt-get update && apt-get install -y amneziawg || return 1
  }
  local p; p="$(rand_free_port 20000 60000)" || return 1
  read -r -p "UDP-порт AmneziaWG [${p}]: " pin; p="${pin:-$p}"; is_port "$p" || return 1
  local dev priv pub psk old_dev
  dev="$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}')"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || { err 'Не удалось определить внешний интерфейс'; return 1; }
  # (баг №4, аудит v5.2.1): запоминаем прежний внешний интерфейс до перезаписи
  old_dev=""
  [ -n "${XKIT_PROTOCOLS_ENV:-}" ] && [ -f "$XKIT_PROTOCOLS_ENV" ] && \
    old_dev="$(. "$XKIT_PROTOCOLS_ENV" 2>/dev/null; printf '%s' "${AWG_DEV:-}")"
  priv="$(awg genkey)" || return 1; pub="$(printf '%s' "$priv" | awg pubkey)" || return 1; psk="$(awg genpsk)" || return 1
  AWG_PORT="$p"; AWG_SERVER_PUB="$pub"; AWG_DEV="$dev"; proto_awg_params
  mkdir -p "$(dirname "$XKIT_AWG_CONF")" "$XKIT_AWG_CLIENTS_DIR" "$(dirname "$XKIT_AWG_STATE")" || return 1
  chmod 700 "$XKIT_AWG_CLIENTS_DIR"; : >"$XKIT_AWG_STATE"; chmod 600 "$XKIT_AWG_STATE"
  local tmp; tmp="$(mktemp /tmp/.xkit-awg.XXXXXX)" || return 1
  cat >"$tmp" <<EOF
# Managed by XKIT v5.2 — резервная копия включается в xkit backup
[Interface]
Address = 10.77.0.1/24
ListenPort = ${AWG_PORT}
PrivateKey = ${priv}
Jc = 8
Jmin = 8
Jmax = 80
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${dev} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${dev} -j MASQUERADE
EOF
  install -m 600 "$tmp" "$XKIT_AWG_CONF" || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  printf 'net.ipv4.ip_forward=1\n' >"$XKIT_AWG_SYSCTL"; chmod 644 "$XKIT_AWG_SYSCTL"; sysctl --system >/dev/null
  systemctl enable --now awg-quick@awg0 || { rm -f "$XKIT_AWG_CONF"; return 1; }
  sleep 1; proto_service_active awg-quick@awg0 || { systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true; rm -f "$XKIT_AWG_CONF"; err 'AWG не запустился; конфиг удалён'; return 1; }
  # (баг №4, аудит v5.2.1): при смене внешнего интерфейса снимаем route-правила
  # старой пары — иначе XKIT:awg-forward остаётся на прошлом dev
  if [ -n "$old_dev" ] && [ "$old_dev" != "$dev" ]; then
    xkit_awg_route_remove "$old_dev" >/dev/null 2>&1 || true
  fi
  if ! xkit_fw_add awg "$AWG_PORT" udp || ! xkit_awg_route_add "$AWG_DEV"; then
    proto_awg_rollback_install
    err 'Не удалось настроить firewall/forwarding AWG — установка откачена'; return 1
  fi
  if ! proto_state_save; then
    proto_awg_rollback_install
    err 'Не удалось сохранить состояние AWG — установка откачена'; return 1
  fi
  ok "AmneziaWG запущен: UDP ${AWG_PORT}"
  proto_awg_add
}

proto_awg_add() {
  require_root; [ -f "$XKIT_AWG_CONF" ] || { err 'Сначала установите AmneziaWG'; return 1; }
  proto_state_load; load_xkit_env || return 1
  local name ipn priv pub psk dns
  read -r -p 'Имя клиента [client1]: ' name; name="${name:-client1}"
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { err 'Имя: только латиница, цифры, _ и -'; return 1; }
  [ -f "$XKIT_AWG_CLIENTS_DIR/$name.conf" ] && { err 'Клиент уже существует'; return 1; }
  ipn=2; while awk -F'\t' -v n="$ipn" '$2==n{found=1}END{exit !found}' "$XKIT_AWG_STATE" 2>/dev/null; do ipn=$((ipn+1)); done
  [ "$ipn" -le 254 ] || { err 'Пул 10.77.0.0/24 заполнен'; return 1; }
  priv="$(awg genkey)"; pub="$(printf '%s' "$priv" | awg pubkey)"; psk="$(awg genpsk)"
  read -r -p 'DNS клиента [1.1.1.1]: ' dns; dns="${dns:-1.1.1.1}"; is_ip "$dns" || return 1
  local ctmp; ctmp="$(mktemp /tmp/.xkit-awg-client.XXXXXX)" || return 1
  cat >"$ctmp" <<EOF
[Interface]
PrivateKey = ${priv}
Address = 10.77.0.${ipn}/32
DNS = ${dns}
Jc = 4
Jmin = 8
Jmax = 80
S1 = $(awk '/^S1 =/{print $3}' "$XKIT_AWG_CONF")
S2 = $(awk '/^S2 =/{print $3}' "$XKIT_AWG_CONF")
H1 = $(awk '/^H1 =/{print $3}' "$XKIT_AWG_CONF")
H2 = $(awk '/^H2 =/{print $3}' "$XKIT_AWG_CONF")
H3 = $(awk '/^H3 =/{print $3}' "$XKIT_AWG_CONF")
H4 = $(awk '/^H4 =/{print $3}' "$XKIT_AWG_CONF")

[Peer]
PublicKey = ${AWG_SERVER_PUB}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${XKIT_HOST}:${AWG_PORT}
PersistentKeepalive = 25
EOF
  install -m 600 "$ctmp" "$XKIT_AWG_CLIENTS_DIR/$name.conf" || { rm -f "$ctmp"; return 1; }; rm -f "$ctmp"
  cp -f "$XKIT_AWG_CONF" "${XKIT_AWG_CONF}.bak" || return 1
  cat >>"$XKIT_AWG_CONF" <<EOF

[Peer] # xkit:${name}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = 10.77.0.${ipn}/32
EOF
  systemctl restart awg-quick@awg0 && proto_service_active awg-quick@awg0 || {
    mv -f "${XKIT_AWG_CONF}.bak" "$XKIT_AWG_CONF"; systemctl restart awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f "$XKIT_AWG_CLIENTS_DIR/$name.conf"; err 'Не удалось применить peer — выполнен откат'; return 1;
  }
  printf '%s\t%s\t%s\n' "$name" "$ipn" "$pub" >>"$XKIT_AWG_STATE"; chmod 600 "$XKIT_AWG_STATE"
  ok "Клиент $name: $XKIT_AWG_CLIENTS_DIR/$name.conf"
}

proto_awg_list() {
  [ -s "$XKIT_AWG_STATE" ] || { warn 'Клиентов нет'; return; }
  awk -F'\t' '{printf "%-24s 10.77.0.%s/32  %s\n",$1,$2,$3}' "$XKIT_AWG_STATE"
}
proto_awg_show() {
  proto_awg_list; read -r -p 'Имя клиента: ' name || return 1
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] && [ -f "$XKIT_AWG_CLIENTS_DIR/$name.conf" ] || return 1
  cat "$XKIT_AWG_CLIENTS_DIR/$name.conf"
}
proto_awg_uninstall() {
  require_root; proto_state_load; confirm 'Удалить только конфигурацию XKIT AmneziaWG?' || return 0
  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  xkit_awg_route_remove "${AWG_DEV:-}" || warn 'Не удалось удалить route-правила XKIT AWG'
  rm -f "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
  [ -z "${AWG_PORT:-}" ] || xkit_fw_remove awg "$AWG_PORT" udp || warn 'Не удалось удалить входящее правило XKIT AWG'
  AWG_PORT=""; AWG_SERVER_PUB=""; AWG_DEV=""; proto_state_save
  ok 'Служба XKIT AWG удалена; пакеты и клиентские конфиги сохранены'
}
proto_awg_menu() {
  while :; do
    echo '1) Установить  2) Добавить клиента  3) Список  4) Показать конфиг  5) Статус  6) Удалить  0) Назад'
    read -r -p 'AmneziaWG: ' c || return
    case "$c" in 1) proto_awg_install ;; 2) proto_awg_add ;; 3) proto_awg_list ;; 4) proto_awg_show ;;
      5) systemctl status awg-quick@awg0 --no-pager ;; 6) proto_awg_uninstall ;; 0) return ;; *) warn 'Нет такого пункта' ;; esac
  done
}

protocols_menu() {
  while :; do
    echo; protocols_list
    echo '1) VLESS + REALITY + Vision'
    echo '2) VLESS + XHTTP + REALITY'
    echo '3) AmneziaWG'
    echo '4) Hysteria 2'
    echo '0) Назад'
    read -r -p 'Протоколы: ' c || return
    case "$c" in 1) reality_wizard ;; 2) proto_xhttp_create ;; 3) proto_awg_menu ;; 4) proto_hy2_menu ;; 0) return ;; *) warn 'Нет такого пункта' ;; esac
  done
}

protocols_main() {
  case "${1:-menu}" in
    menu) protocols_menu ;; list) protocols_list "${2:-}" ;; status) protocols_list ;;
    reality) reality_wizard ;; xhttp) proto_xhttp_create ;;
    awg) case "${2:-menu}" in menu) proto_awg_menu ;; install) proto_awg_install ;; add) proto_awg_add ;; list) proto_awg_list ;; show) proto_awg_show ;; status) systemctl status awg-quick@awg0 --no-pager ;; uninstall) proto_awg_uninstall ;; *) return 1 ;; esac ;;
    hysteria2|hy2) case "${2:-menu}" in menu) proto_hy2_menu ;; install) proto_hy2_install ;; link) proto_hy2_link ;; status) systemctl status xkit-hysteria2 --no-pager ;; uninstall) proto_hy2_uninstall ;; *) return 1 ;; esac ;;
    *) err 'xkit protocols [list|status|reality|xhttp|awg|hysteria2]'; return 1 ;;
  esac
}
