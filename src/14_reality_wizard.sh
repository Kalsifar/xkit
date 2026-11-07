
reality_expand_targets() { # CIDR (/24 и меньше) или список -> по IP в строке
  command -v python3 >/dev/null 2>&1 || { err "python3 не найден — выполните: apt-get install -y python3"; echo "ERR:python3 не найден"; return 1; }
  python3 - "$1" <<'PY'
import sys, ipaddress, re
arg = sys.argv[1]
if "/" in arg:
    try:
        net = ipaddress.ip_network(arg, strict=False)
    except ValueError:
        print("ERR:bad-cidr"); sys.exit(0)
    if net.num_addresses > 256:
        print("ERR:too-big"); sys.exit(0)
    for ip in net.hosts():
        print(str(ip))
else:
    for h in arg.split():
        # V-01 (аудит №2): токен уходит в SSH-сессию — валидируем charset,
        # кавычка/;/$ не имеют права доехать до bash ноды
        if not re.fullmatch(r"[A-Za-z0-9._:/-]+", h):
            print("ERR:bad-target"); sys.exit(0)
        print(h)
PY
}

reality_scan_run() { # $1 targets (построчно), $2 out.tsv
  local out="$2"
  local tmp; tmp="$(mktemp /tmp/.xkit-scan.XXXXXX)"
  grep -v '^$' <<<"$1" > "$tmp" || true
  local total open_cnt
  total="$(wc -l < "$tmp")"
  log "Шаг 1/2: TCP-проба :443 на ${total} адресах (50 параллельно)..."
  cat > "${tmp}.probe" <<'EOF'
#!/bin/bash
timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$1" 2>/dev/null && echo "$1"
EOF
  chmod +x "${tmp}.probe"
  local openf="${tmp}.open"; : > "$openf"
  xargs -a "$tmp" -P 50 -n 1 "${tmp}.probe" >> "$openf" 2>/dev/null || true
  open_cnt="$(grep -c . "$openf" 2>/dev/null || echo 0)"
  log "Шаг 2/2: TLS-детали на ${open_cnt} открытых адресах..."
  : > "$out"
  local ip brief cert cn san issuer end tls13 h2 x25519 selfsig verdict
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    brief="$(echo | timeout 6 openssl s_client -brief -connect "${ip}:443" -servername "${ip}" 2>&1)"
    tls13=no;  grep -q "TLSv1.3" <<<"$brief" && tls13=yes
    h2=no;     grep -qi "ALPN protocol: *h2" <<<"$brief" && h2=yes
    x25519=no; grep -q "X25519" <<<"$brief" && x25519=yes
    cert="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>/dev/null \
            | openssl x509 -noout -subject -issuer -ext subjectAltName -enddate 2>/dev/null)"
    cn="$(sed -n 's/^subject=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    # первый SAN без wildcard (в качестве SNI wildcard не годится), фолбэк — CN
    san="$(awk '/^X509v3 Subject Alternative Name:/{getline; sub(/^ +/,""); print; exit}' <<<"$cert" \
           | sed 's/DNS://g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^\*' | head -n1)"
    [ -n "$san" ] || san="$cn"
    issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    end="$(sed -n 's/^notAfter=//p' <<<"$cert" | head -n1)"
    # self-signed = ЛЮБОЙ провал проверки цепочки (истёк, кривой CN/SAN, unknown CA,
    # incomplete chain). «Verify return code: 0 (ok)» — единственный признак «годен».
    # Раньше отсутствие строки verify трактовалось как успех — плохой dest получал «ДА».
    vrf_out="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>&1)"
    selfsig=yes
    if grep -q 'Verify return code: 0 (ok)' <<<"$vrf_out" \
       || grep -qE 'Verify return code: 0[[:space:]]*$' <<<"$vrf_out"; then
      selfsig=no
    fi
    verdict="НЕТ"
    if [ "$tls13" = "yes" ] && [ "$selfsig" = "no" ] && { [ -n "$san" ] || [ -n "$cn" ]; }; then
      verdict="ДА"
      [ "$h2" = "yes" ] && [ "$x25519" = "yes" ] && verdict="ДА+"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ip" "$tls13" "$h2" "$x25519" "$selfsig" "${cn:--}" "${san:--}" "${end:--}" "$verdict" >> "$out"
  done < "$openf"
  rm -f "$tmp" "${tmp}.probe" "$openf"
  return 0
}

# Единый порядок для отображения и выбора: только подходящие REALITY-кандидаты.
# Полный TSV при этом остаётся на диске для технической диагностики.
reality_scan_candidates() { # $1 tsv
  awk -F '\t' '$9 == "ДА" || $9 == "ДА+"' "$1" | sort -t$'\t' -k9,9r -k1,1V
}

reality_scan_candidate_row() { # $1 tsv, $2 номер из нумерованной таблицы
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 1
  reality_scan_candidates "$1" | sed -n "${2}p"
}

reality_scan_print() { # $1 tsv
  local total; total="$(reality_scan_candidates "$1" | wc -l)"
  if [ "$total" -eq 0 ]; then
    echo ""
    warn "Подходящих REALITY-кандидатов не найдено."
    return 1
  fi
  echo ""
  printf '%-5s %-16s %-3s %-7s %-34s %s\n' "№" "IP" "H2" "X25519" "SNI(SAN)" "ГОДЕН"
  echo "--------------------------------------------------------------------------------"
  local n=0 ip t13 h2 x2 ss cn san end v
  while IFS=$'\t' read -r ip t13 h2 x2 ss cn san end v; do
    n=$((n+1))
    printf '%-5s %-16s %-3s %-7s %-34s %s\n' "$n" "$ip" "$h2" "$x2" "${san:0:34}" "$v"
  done < <(reality_scan_candidates "$1")
  echo ""
  ok "Показаны только подходящие: TLS1.3 + публичный сертификат. «ДА+» = ещё и H2/X25519."
}

# Общий выбор по номеру для мастера на сервере и сканирования с ноды.
reality_scan_choose() { # $1 tsv; результат в RDEST / RSNI
  local out="$1" n row
  reality_scan_print "$out" || return 1
  ok "Полный технический отчёт сохранён: $out"
  read -r -p "Номер кандидата из таблицы (Enter — отмена): " n || return 1
  [ -n "$n" ] || return 1
  row="$(reality_scan_candidate_row "$out" "$n")"
  [ -n "$row" ] || { err "Нет кандидата с таким номером"; return 1; }
  RDEST="$(awk -F'\t' '{print $1":443"}' <<<"$row")"
  RSNI="$(awk -F'\t' '{print ($7!="-" && $7!="") ? $7 : $6}' <<<"$row")"
  [ -n "$RSNI" ] && [ "$RSNI" != "-" ] || { err "У кандидата нет домена в сертификате — SNI не определить"; return 1; }
  return 0
}

# выбор из готового списка; результат в RDEST / RSNI
reality_known_pick() {
  echo "1) 1.1.1.1:443                SNI: cloudflare-dns.com  (быстрый, надёжный)"
  echo "2) www.tesla.com:443          SNI: www.tesla.com"
  echo "3) www.samsung.com:443        SNI: www.samsung.com"
  echo "4) www.lovelive-anime.jp:443  SNI: www.lovelive-anime.jp"
  echo "5) www.icloud.com:443         SNI: www.icloud.com"
  read -r -p "Выбор [1-5]: " k
  case "$k" in
    1) RDEST="1.1.1.1:443";              RSNI="cloudflare-dns.com" ;;
    2) RDEST="www.tesla.com:443";        RSNI="www.tesla.com" ;;
    3) RDEST="www.samsung.com:443";      RSNI="www.samsung.com" ;;
    4) RDEST="www.lovelive-anime.jp:443"; RSNI="www.lovelive-anime.jp" ;;
    5) RDEST="www.icloud.com:443";       RSNI="www.icloud.com" ;;
    *) return 1 ;;
  esac
  return 0
}

# скан подсети + выбор кандидата; результат в RDEST / RSNI
reality_scan_pick() {
  local myip def t targets
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24 — подсеть этого сервера)"
  read -r -p "Что сканируем? CIDR или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  local out="${XKIT_DIR}/reality-scan.tsv"
  mkdir -p "$XKIT_DIR"
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Ни один адрес не ответил на :443"; return 1; }
  reality_scan_choose "$out"
}

# $1 dest (host:port | ip:port | 127.0.0.1:8444), $2 sni
reality_create_inbound() {
  local dest="$1" sni="$2" p
  p="$(rand_free_port 10000 60000)" || { err "Нет свободного порта"; return 1; }
  read -r -p "Публичный порт Reality inbound [${p}]: " pin
  p="${pin:-$p}"
  is_port "$p" || { err "Некорректный порт"; return 1; }
  port_busy "$p" && { err "Порт $p уже занят"; return 1; }

  log "Генерирую ключи x25519 через API панели..."
  local priv pub
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; return 1; }
  local uuid subid email sid
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="reality-$(rand_hex 2)"; sid="$(rand_hex 4)"

  local settings stream ib
  settings="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" '
    {clients:[{id:$id, flow:"xtls-rprx-vision", email:$email, limitIp:0, totalGB:0,
               expiryTime:0, enable:true, tgId:"", subId:$sub, reset:0}],
     decryption:"none", fallbacks:[]}')"
  stream="$(jq -nc --arg dest "$dest" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni],
                      privateKey:$priv, minClient:"", maxClient:"", maxTimeDiff:0,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}')"
  ib="$(jq -nc --arg port "$p" --arg tag "inbound-${p}" --arg remark "reality-${sni}" \
        --arg s "$settings" --arg st "$stream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
     listen:"", port:($port|tonumber), protocol:"vless",
     settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"

  log "Создаю Reality inbound: порт ${p}, dest ${dest}, SNI ${sni}..."
  api_add_inbound "$ib" || return 1

  # id созданного + externalProxy (чтобы панель показывала ДОМЕН:порт)
  local newlist ibid fresh cl link
  newlist="$(api_list)" || true
  ibid="$(jq -r --arg t "inbound-${p}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$newlist")"
  if [ -n "$ibid" ]; then
    fresh="$(api_get_inbound "$ibid")" || true
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; Reality наследует security (same)
      v3_host_upsert "$ibid" "$XKIT_HOST" "$p" "same" \
        && ok "Внешний адрес в панели (hosts): ${XKIT_HOST}:${p}" \
        || warn "Не удалось создать host-группу для Reality-инбаунда (ссылки в панели — вручную)"
    elif [ -n "$fresh" ]; then
      fresh="$(jq -c --arg d "$XKIT_HOST" --argjson p "$p" \
        '.externalProxy = [{"dest":$d,"port":$p,"remark":"xkit"}]' <<<"$fresh")"
      api_update_inbound "$ibid" "$fresh" >/dev/null 2>&1 || true
      fresh="$(api_get_inbound "$ibid")" || true
    fi
  else
    fresh="$ib"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 && ok "UFW: открыт ${p}/tcp"
  fi

  cl="$(jq -c '.settings|fromjson?|.clients[0]' <<<"${fresh:-$ib}")"
  echo ""
  ok "Reality inbound создан: порт ${p}, dest ${dest}, SNI ${sni}"
  [ -n "$ibid" ] && ok "Внешний адрес в панели: ${XKIT_HOST}:${p}"
  link="$(link_for_client "${fresh:-$ib}" "$cl")"
  [ -n "$link" ] && { echo ""; ok "Ссылка клиента:"; printf '  %s\n' "$link"; }
  sub_regen_quiet || true
  ok "Подписка: https://${XKIT_HOST}$(sub_path)${subid}"
  return 0
}

reality_wizard() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  echo "Какой dest (сайт-прикрытие) используем для Reality?"
  echo "1) Свой сайт на этом сервере (${XKIT_HOST:-домен} + наш сертификат) — лучший камуфляж"
  echo "2) Скан подсети — найти подходящие сайты рядом"
  echo "3) Готовый список проверенных dest"
  echo "4) Вручную: dest + SNI"
  read -r -p "Выбор [1-4]: " c
  local dest="" sni=""
  case "$c" in
    1)
      if [ "$(host_kind "${XKIT_HOST:-}")" != "domain" ] || [ ! -f "${XKIT_CRT:-}" ]; then
        err "Нужен ДОМЕН с валидным сертификатом (у вас IP-режим или серта нет)."
        warn "Варианты: пункт 10 (перевыпустить серт) либо режимы 2/3/4 ниже."
        return 1
      fi
      camo_site_install
      XKIT_REALITY_INTERNAL=1
      save_xkit_env
      regen_conf_and_apply || return 1
      dest="127.0.0.1:8444"; sni="$XKIT_HOST" ;;
    2) reality_scan_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    3) reality_known_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    4)
      local dh dp
      dh="$(read_host "dest (IP или домен) -> ")"
      read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
      sni="$(read_host "SNI (домен из сертификата dest) -> ")"
      dest="${dh}:${dp}" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  [ -n "$dest" ] && [ -n "$sni" ] || { err "dest/SNI не определены"; return 1; }
  reality_create_inbound "$dest" "$sni"
}

reality_scan_menu() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  mkdir -p "$XKIT_DIR"
  local myip def t targets out="${XKIT_DIR}/reality-scan.tsv"
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24)"
  echo ""
  read -r -p "CIDR (например 5.6.7.0/24) или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Никто не ответил на :443"; return 0; }
  reality_scan_print "$out" || warn "Полный отчёт сохранён для диагностики: $out"
  return 0
}

reality_show_keys() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  local found=0 ib sec st tag port dest
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    [ "$sec" = "reality" ] || continue
    found=$((found+1))
    st="$(jq -r '.streamSettings' <<<"$ib")"
    tag="$(jq -r '.tag' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    dest="$(jq -r '.realitySettings.dest // ""' <<<"$st")"
    echo -e "${GREEN}── ${tag} (порт ${port})${NC}"
    echo "   dest: ${dest}   SNI: $(reality_sni "$st")"
    echo "   publicKey: $(reality_pbk "$st")"
    echo "   shortId:   $(reality_sid "$st")"
    local cl link
    while IFS= read -r cl; do
      [ -z "$cl" ] && continue
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] && printf '   %s\n' "$link"
    done < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$found" -eq 0 ] && warn "Reality-инбаундов нет — создайте (пункт 14)"
  return 0
}

#=========================== v4.1: НОДЫ =======================================
# Схема: клиенты -> мастер (nginx:443, pool-inbound) -> xray balancer -> ноды
# (VLESS+Reality на каждой ноде). Переключение при сбоях — observatory.
