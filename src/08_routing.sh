
#=========================== КЛАССИФИКАЦИЯ ИНБАУНДОВ ==========================
# Что можно спрятать за nginx (один порт 443, маршрутизация по путям), а что
# живёт напрямую своим портом (Reality/UDP/raw-TCP — это их дизайн).
# Вывод: "net|sec|mode|reason"   mode: routed | direct
classify_inbound() { # $1 = JSON одного инбаунда
  local net sec hdr proto
  net="$(jq -r '.streamSettings|fromjson?|.network // "tcp"' <<<"$1")"
  sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$1")"
  proto="$(jq -r '.protocol // ""' <<<"$1")"

  if [ "$sec" = "reality" ]; then
    printf '%s|%s|direct|Reality сам терминирует TLS и маскируется под сайт — за nginx не прячется, порт прямой' "$net" "$sec"
    return 0
  fi
  case "$proto" in
    vless|vmess|trojan) ;;
    shadowsocks) printf 'tcp|%s|direct|Shadowsocks не умеет ws/grpc-транспорт — порт прямой (либо UFW deny)' "$sec"; return 0 ;;
    *)           printf '%s|%s|direct|протокол %s не мультиплексируется по путям' "$net" "$sec" "$proto"; return 0 ;;
  esac
  case "$net" in
    ws|grpc|xhttp|splithttp|httpupgrade) printf '%s|%s|routed|' "$net" "$sec" ;;
    tcp)
      hdr="$(jq -r '.streamSettings|fromjson?|.tcpSettings.header.type // "none"' <<<"$1")"
      if [ "$hdr" = "http" ]; then printf 'tcp|%s|routed|' "$sec"
      else printf '%s|%s|direct|raw TCP не маршрутизируется по путям на 443' "$net" "$sec"; fi ;;
    *) printf '%s|%s|direct|транспорт %s (UDP/сокет) nginx не проксирует' "$net" "$sec" "$net" ;;
  esac
}

# короткий тег транспорта для канонического пути
net_tag() { case "$1" in ws) echo ws ;; grpc) echo gr ;; xhttp|splithttp) echo xh ;; httpupgrade) echo hu ;; *) echo tc ;; esac }

# текущий путь/имя сервиса инбаунда (то, что задано в streamSettings)
inbound_path() { # $1 inbound JSON, $2 net (ws|grpc|xhttp|httpupgrade|tcp)
  local s='.streamSettings | if type=="string" then (fromjson? // {}) else (. // {}) end'
  case "$2" in
    ws)          jq -r "${s}|.wsSettings.path // \"\"" <<<"$1" ;;
    grpc)        jq -r "${s}|.grpcSettings.serviceName // \"\"" <<<"$1" ;;
    xhttp)       jq -r "${s}|(.xhttpSettings.path // .splithttpSettings.path // \"\")" <<<"$1" ;;
    httpupgrade) jq -r "${s}|.httpupgradeSettings.path // \"\"" <<<"$1" ;;
    tcp)         jq -r "${s}|((.tcpSettings.header.request.path // \"\") | if type==\"array\" then (.[0] // \"\") else . end)" <<<"$1" ;;
  esac
}

# инфо о маршруте инбаунда из routes.tsv: mode|net|path
route_info() { # $1 inbound id
  local row
  row="$(awk -F'\t' -v id="$1" '$1==id{print $2"|"$3"|"$4; exit}' "$XKIT_ROUTES" 2>/dev/null)"
  printf '%s' "${row:-||}"
}

#=========================== АВТОПРОБРОС (ПУНКТ 2) ============================
# Сам находит все инбаунды через API панели, переводит их на 127.0.0.1,
# канонизирует пути и строит единый конфиг nginx. Reality/UDP пропускает.
auto_route() {
  load_xkit_env || die "Сначала выполните установку (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST в $XKIT_ENV"
  command -v jq >/dev/null 2>&1 || die "jq не найден (apt install jq)"
  command -v sqlite3 >/dev/null 2>&1 || true

  log "Подключаюсь к API панели..."
  kit_session || return 1
  routes_load

  local yes="${XKIT_YES:-0}"
  local total=0 routed=0 direct=0 changed=0
  local id port tag proto enable mode net sec reason tag2 path cur_listen cur_path need

  echo ""
  printf '%-4s %-16s %-9s %-6s %-8s %s\n' "ID" "TAG" "PROTO" "PORT" "РЕЖИМ" "ПУТЬ/ПРИЧИНА"
  echo "--------------------------------------------------------------------------------"

  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"
    port="$(jq -r '.port' <<<"$ib")"
    tag="$(jq -r '.tag // "inbound"' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"
    enable="$(jq -r '.enable // true' <<<"$ib")"
    total=$((total+1))

    if [ "$enable" != "true" ]; then
      routes_del "$id"
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "off" "инбаунд выключен"
      continue
    fi

    # pool-инбаунд xkit (балансировка нод): listen 127.0.0.1 и канонический
    # путь уже на месте — не классифицируем и не переспрашиваем, только
    # подтверждаем маршрут (v4.5: раньше отображался как обычный «ЗА nginx»)
    if [ -n "${XKIT_POOL_INBOUND:-}" ] && [ "$id" = "$XKIT_POOL_INBOUND" ]; then
      local ppath_
      ppath_="$(inbound_path "$ib" ws)"
      [ -n "$ppath_" ] && routes_upsert "$id" local ws "$ppath_" "127.0.0.1:${port}" "$tag"
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "POOL" "инбаунд балансировки нод (не трогаю)"
      continue
    fi

    IFS='|' read -r net sec mode reason <<<"$(classify_inbound "$ib")"

    if [ "$mode" != "routed" ]; then
      routes_del "$id"
      direct=$((direct+1))
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "${reason:0:60}"
      continue
    fi

    tag2="$(net_tag "$net")"
    if [ "$tag2" = "tc" ]; then
      # tcp+http: путь задаёт пользователь, канонизировать нельзя
      path="$(inbound_path "$ib" tcp)"
      if [ -z "$path" ]; then
        routes_del "$id"; direct=$((direct+1))
        printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "tcp+http без пути"
        continue
      fi
      case "$path" in /*) ;; *) path="/$path" ;; esac
      if ! is_nginx_path "$path"; then
        routes_del "$id"; direct=$((direct+1))
        printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "путь tcp+http нестандартный — в nginx не добавляю (K-01)"
        continue
      fi
    else
      path="$(auto_path_for "$tag2" "$port")"
    fi

    cur_listen="$(jq -r '.listen // ""' <<<"$ib")"
    cur_path="$(inbound_path "$ib" "$tag2")"
    need=""
    case "$cur_listen" in ""|"0.0.0.0"|"::"|"*") need="listen" ;; esac
    if [ "$tag2" != "tc" ] && [ "$cur_path" != "$path" ]; then need="${need}+path"; fi

    if [ -n "$need" ]; then
      if [ "$yes" != "1" ]; then
        echo ""
        warn "Инбаунд #$id ($tag, порт $port): требуется ${need#+} → путь $path, listen 127.0.0.1"
        read -r -p "Применить изменения? [Y/n]: " a
        [[ "$a" =~ ^[Nn] ]] && { warn "Пропущен #$id"; direct=$((direct+1)); continue; }
      fi
      local svc
      svc="${path//\//}"   # xk-gr-2083 (без слэшей) — serviceName для gRPC
      if [ "$tag2" != "tc" ]; then
        local new_ib
        new_ib="$(jq --arg listen "127.0.0.1" --arg p "$path" --arg sn "$svc" '
          .listen=$listen
          | .streamSettings = ((.streamSettings | fromjson?)
              | (if .network=="ws" then .wsSettings.path=$p
                 elif .network=="grpc" then .grpcSettings.serviceName=$sn
                 elif (.network=="xhttp" or .network=="splithttp") then
                   (if (has("xhttpSettings")) then .xhttpSettings.path=$p else .splithttpSettings.path=$p end)
                 elif .network=="httpupgrade" then .httpupgradeSettings.path=$p
                 else . end)
              | tojson)' <<<"$ib")"
      else
        local new_ib
        new_ib="$(jq --arg listen "127.0.0.1" '.listen=$listen' <<<"$ib")"
      fi
      if api_update_inbound "$id" "$new_ib"; then
        changed=$((changed+1))
        ok "#$id: listen=127.0.0.1, путь=$path (панель обновлена)"
      else
        err "#$id: обновление через API не прошло — маршрутизирую как есть (listen $(echo "${cur_listen:-0.0.0.0}" | head -c 12))"
      fi
    fi

    routes_upsert "$id" local "$tag2" "$path" "127.0.0.1:${port}" "$tag"
    routed=$((routed+1))
    printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "ЗА nginx" "$path"
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  echo "--------------------------------------------------------------------------------"
  ok "Итого: $total инбаундов; за nginx: $routed; прямые порты: $direct; изменений: $changed"

  log "Пересобираю конфиг nginx..."
  regen_conf_and_apply || return 1

  log "Перегенерирую подписки..."
  sub_regen_quiet || true

  echo ""
  log "Снаружи открыт только 443 (и 80 для редиректа). Порты локальных инбаундов не видны:"
  log "  проверить: ss -tlnp | grep -v 127.0.0.1   — там не должно быть портов панели/инбаундов"
  return 0
}

#=========================== ГЕНЕРАЦИЯ КОНФИГА NGINX ==========================
# Полный конфиг строится заново из состояния: панель + подписки + маршруты.
gen_xkit_conf() { # stdout
  local host="${XKIT_HOST:?XKIT_HOST не задан}"
  [ -n "${XKIT_CRT:-}" ] && [ -n "${XKIT_KEY:-}" ] || { err "Не заданы пути к сертификату"; return 1; }
  XKIT_SUB_PATH="$(sub_path)"
  local tls_h2 tls_h2_v6="" l80_v6=""
  tls_h2="$(build_h2_block)"
  # А3 IPv6: при наличии глобального v6-адреса слушаем и [::] (пустая строка =
  # обычный v4-only конфиг, поведение прежнее)
  if v6_listen_enabled; then
    tls_h2_v6="$(build_h2_block v6)"
    l80_v6="    listen [::]:80;"
  fi

  cat <<EOF
# =========================================================================
# xkit.conf — УПРАВЛЯЕТСЯ XKIT v${XKIT_VERSION}, НЕ редактируйте вручную.
# Пересборка: xkit (меню) -> пункт 2   |   state: $XKIT_ENV, $XKIT_ROUTES
# =========================================================================
server {
    listen 80;
${l80_v6}
    server_name ${host};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
${tls_h2}
${tls_h2_v6}
    server_name ${host};
    ssl_certificate ${XKIT_CRT};
    ssl_certificate_key ${XKIT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:XKIT:10m;
    ssl_session_timeout 1h;
    ssl_session_tickets off;
    server_tokens off;
    keepalive_timeout 1h;
    client_max_body_size 0;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
EOF

  # --- панель (привязана к 127.0.0.1, наружу не видна) ---
  if [ -n "${PANEL_PORT:-}" ] && [ -n "${PANEL_WBP:-}" ]; then
    if [ "$PANEL_WBP" = "/" ]; then
      warn "Панель на корне (/) — пропускаю её location, иначе конфликт с сайтом-заглушкой"
    else
      generate_web_proxy_block "Панель 3X-UI" "$PANEL_WBP" "127.0.0.1:${PANEL_PORT}" "${PANEL_SCHEME:-http}"
    fi
  fi

  # --- подписки (файлы, формирует xkit) ---
  generate_subs_block

  # --- веб-дашборд (секретный путь, как у панели) ---
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
    generate_dash_block
  fi

  # --- нативные подписки самой панели (проксируются через nginx на 443) ---
  if [ -n "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "${XKIT_PANEL_SUB_PATH:-}" ]; then
    generate_web_proxy_block "Подписки 3X-UI" "$XKIT_PANEL_SUB_PATH" "127.0.0.1:${XKIT_PANEL_SUB_PORT}" "http"
  fi

  # --- маршруты инбаундов / relay ---
  local row r_id r_mode r_net r_path r_target r_tag r_num
  routes_load
  for row in "${ROUTES[@]}"; do
    [ -z "$row" ] && continue
    IFS=$'\t' read -r r_id r_mode r_net r_path r_target r_tag <<<"$row"
    [ -n "$r_path" ] && [ -n "$r_target" ] || continue
    case "$r_net" in
      grpc) r_num=1 ;;
      ws)   r_num=2 ;;
      xhttp)r_num=3 ;;
      tcp)  r_num=4 ;;
      *)    continue ;;
    esac
    if [ "$r_mode" = "relay" ]; then
      generate_location_block "$r_num" "$r_path" "$r_target" "false"
    else
      generate_location_block "$r_num" "$r_path" "$r_target" "true"
    fi
  done

  printf '\n}\n'

  # --- сайт-прикрытие для Reality dest (dest=127.0.0.1:8444, только с localhost) ---
  if [ "${XKIT_REALITY_INTERNAL:-0}" = "1" ]; then
    cat <<EOF

# Внутренний TLS-сайт для Reality: xray проксирует сюда посторонних,
# клиент Reality видит легитимный сайт с сертификатом ${host}.
server {
    listen 127.0.0.1:8444 ssl;
    server_name ${host};
    ssl_certificate ${XKIT_CRT};
    ssl_certificate_key ${XKIT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/camo;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  fi
  return 0
}

# собрать и применить конфиг: бэкап -> запись -> nginx -t -> reload (откат при ошибке)
regen_conf_and_apply() {
  read_panel_settings || return 1
  PANEL_SCHEME=$(detect_panel_scheme "$PANEL_PORT")
  if [ -f "$XKIT_CONF" ]; then backup_file "$XKIT_CONF" >/dev/null; fi
  mkdir -p /var/www/html
  [ -f /var/www/html/index.html ] || printf '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome!</h1><p>This server is up and running.</p></body></html>\n' > /var/www/html/index.html
  if ! gen_xkit_conf > "${XKIT_CONF}.tmp"; then
    rm -f "${XKIT_CONF}.tmp"; err "Генерация конфига не удалась"; return 1
  fi
  mv "${XKIT_CONF}.tmp" "$XKIT_CONF"; chmod 644 "$XKIT_CONF"
  ln -sf "$XKIT_CONF" "$XKIT_CONF_LINK"
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null
  if ! apply_config "$XKIT_CONF"; then
    err "Конфиг НЕ применён (откат выполнен). Проверьте nginx -t вручную."
    return 1
  fi
  return 0
}

#=========================== ССЫЛКИ-ШАРИНГ (подписки) =========================
# ВАЖНО: подписки формирует сам xkit — в ссылках всегда https://ДОМЕН:443/путь
# для инбаундов за nginx и реальные адреса/порты для direct-инбаундов
# (Reality и т.п.). Ссылки панели с 127.0.0.1 наружу не уходят.
