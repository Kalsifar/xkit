
backup_file() {
  local f="$1" b
  [ -f "$f" ] || return 0
  b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$b" && ok "Бэкап: $b"
  return 0
}

# срезать хвостовые пустые строки (nginx -t их не любит при конкатенации)
trim_blank_tail() {
  sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$1"
}

# nginx -t + reload; при ошибке — РЕАЛЬНЫЙ откат к последнему бэкапу
apply_config() {
  local f="$1" out b
  trim_blank_tail "$f"
  if out=$(nginx -t 2>&1); then
    if systemctl reload nginx >/dev/null 2>&1; then ok "Nginx перезагружен"; return 0; fi
    if systemctl start nginx >/dev/null 2>&1; then ok "Nginx запущен"; return 0; fi
    err "nginx -t прошёл, но перезапустить nginx не удалось"; return 1
  fi
  err "nginx -t не прошёл:"
  echo "$out" | sed 's/^/    /' >&2
  b=$(ls -1t "${f}".bak.* 2>/dev/null | head -n1)
  if [ -n "$b" ]; then
    warn "Откатываю конфиг к последнему бэкапу: $b"
    cp -a "$b" "$f"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
      ok "Откат выполнен — nginx работает на старом конфиге"
    else
      warn "Откат тоже битый — правьте вручную: $f"
    fi
  else
    warn "Бэкапа нет — конфиг оставлен как есть: $f"
  fi
  return 1
}

#=========================== СЕРТИФИКАТЫ ======================================
certbot_version() { certbot --version 2>&1 | awk '{print $2}'; }
certbot_supports_ip() { ver_ge "$(certbot_version)" "$CERTBOT_MIN_IP"; }

# перед продлением nginx останавливается (standalone занимает порт 80), после — стартует
install_renew_hooks() {
  mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
  cat > /etc/letsencrypt/renewal-hooks/pre/xkit-nginx.sh <<'EOF'
#!/bin/bash
systemctl stop nginx.service 2>/dev/null || true
EOF
  cat > /etc/letsencrypt/renewal-hooks/post/xkit-nginx.sh <<'EOF'
#!/bin/bash
systemctl start nginx.service 2>/dev/null || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/pre/xkit-nginx.sh \
           /etc/letsencrypt/renewal-hooks/post/xkit-nginx.sh
  ok "Hooks автопродления установлены (stop/start nginx вокруг certbot renew)"
}

# pip-venv: в репо Ubuntu 24.04 certbot 2.9 без --ip-address, нужен >= 5.3
certbot_upgrade() {
  log "Ставлю certbot в /opt/certbot-venv через pip..."
  apt-get install -y -qq python3-venv python3-pip >/dev/null 2>&1 || true
  python3 -m venv /opt/certbot-venv 2>/dev/null || return 1
  /opt/certbot-venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
  /opt/certbot-venv/bin/pip install -q certbot >/dev/null 2>&1 || return 1
  ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
  if [ -d /etc/systemd/system ]; then
    mkdir -p /etc/systemd/system/certbot.service.d
    cat > /etc/systemd/system/certbot.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/opt/certbot-venv/bin/certbot -q renew
EOF
    systemctl daemon-reload 2>/dev/null || true
  fi
  hash -r
  return 0
}

le_email_args() {
  local email="$1"
  if [ -n "$email" ]; then
    printf '%s\n' "--email" "$email" "--no-eff-email"
  else
    printf '%s\n' "--register-unsafely-without-email"
  fi
}

issue_cert_le_domain() {
  local d="$1" email="$2" rc=0 extra=()
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить сертификат (nginx снова запущен). Проверьте A-запись и порт 80."
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$d/"
  return 0
}

issue_cert_le_ip() {
  local ip="$1" email="$2" rc=0 extra=()
  if ! certbot_supports_ip; then
    # ревью v4.9.0: вопрос убран (застопорил живую установку) — авто-попытка;
    # провал возвращает 1, но choose_certificate теперь показывает меню снова,
    # а не выкидывает из установки
    warn "certbot $(certbot_version) не умеет IP-сертификаты (нужно >= ${CERTBOT_MIN_IP}) — обновляю..."
    if certbot_upgrade; then
      ok "certbot обновлён: $(certbot_version)"
    else
      err "Обновить certbot не удалось (PyPI недоступен?) — выберите самоподписанный серт (пункт 4)"
      return 1
    fi
  fi
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone --ip-address "$ip" --preferred-profile shortlived \
    --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить IP-сертификат (nginx снова запущен). Порт 80 доступен извне?"
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$ip/"
  warn "IP-серт shortlived живёт 6 ДНЕЙ — продление настроено (certbot.timer + hooks)"
  return 0
}

issue_cert_selfsigned() {
  local h="$1" kind="$2" dest="/etc/nginx/ssl/$h" san
  if [ "$kind" = "ip" ]; then san="IP:$h"; else san="DNS:$h"; fi
  mkdir -p "$dest"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dest/privkey.pem" -out "$dest/fullchain.pem" \
    -days 3650 -subj "/CN=$h" -addext "subjectAltName=$san" 2>/dev/null \
    || { err "openssl не смог создать сертификат"; return 1; }
  chmod 700 "$dest"; chmod 600 "$dest/privkey.pem"; chmod 644 "$dest/fullchain.pem"
  warn "Самоподписанный серт (10 лет): на клиентах allowInsecure=true"
  ok "Сертификат: $dest/fullchain.pem | Ключ: $dest/privkey.pem"
  return 0
}

install_cert_files() {
  local h="$1" src="/root/cert/$h" dest="/etc/nginx/ssl/$h"
  [ -f "$src/fullchain.pem" ] && [ -f "$src/privkey.pem" ] \
    || { err "Не найдены $src/fullchain.pem и/или $src/privkey.pem"; return 1; }
  # серт и ключ должны быть парными (одинаковый публичный ключ). (з.7/з.11,
  # аудит v5.2.1): пустой вывод openssl (битые файлы) парностью не считается —
  # иначе «пусто == пусто» проходило как пара
  local _pk1 _pk2
  _pk1="$(openssl x509 -noout -pubkey -in "$src/fullchain.pem" 2>/dev/null)" \
    || { err "fullchain.pem не читается как сертификат (openssl)"; return 1; }
  _pk2="$(openssl pkey -pubout -in "$src/privkey.pem" 2>/dev/null)" \
    || { err "privkey.pem не читается как приватный ключ (openssl)"; return 1; }
  [ -n "$_pk1" ] && [ -n "$_pk2" ] \
    && [ "$(sha256sum <<<"$_pk1" | awk '{print $1}')" = "$(sha256sum <<<"$_pk2" | awk '{print $1}')" ] \
    || { err "fullchain.pem и privkey.pem не парные (разные или битые ключи)"; return 1; }
  mkdir -p "$dest"
  cp "$src/fullchain.pem" "$dest/fullchain.pem"
  cp "$src/privkey.pem"  "$dest/privkey.pem"
  chmod 700 "$dest"; chmod 600 "$dest/privkey.pem"; chmod 644 "$dest/fullchain.pem"
  ok "Скопировано в $dest (ключ 600, каталог 700)"
  return 0
}

# выбор сертификата (используется установкой, сокрытием панели и пунктом «перевыпустить»)
# результаты: CERT_MODE, FINAL_CRT, FINAL_KEY, LE_EMAIL
# ревью v4.9.0: провал выпуска серта больше НЕ убивает установку — меню показывается
# снова (лимит 5 попыток, чтобы EOF в цикле не крутился вечно; EOF/Ctrl-D = пункт 4 —
# самоподписанный работает всегда). Раньше return 1 из issue_cert_le_ip обрывал
# one_step_install и выкидывал админа в консоль. Email спрашивается только для LE (1/3)
choose_certificate() {
  local host="$1" kind="$2" try=0
  FINAL_CRT=""; FINAL_KEY=""; LE_EMAIL=""
  while :; do
    try=$((try+1))
    if [ "$try" -gt 5 ]; then
      err "Сертификат не получен за 5 попыток — установка прервана на этом шаге"
      return 1
    fi
    echo ""
    echo -e "${YELLOW}Откуда берём SSL-сертификат?${NC}"
    echo "1) Let's Encrypt — для ДОМЕНА (90 дней, авто-продление)"
    echo "2) Свои файлы в /root/cert/$host/ (fullchain.pem + privkey.pem)"
    if certbot_supports_ip; then
      echo "3) Let's Encrypt — для IP (shortlived, 6 дней, авто-продление)"
    else
      echo "3) Let's Encrypt — для IP (сначала авто-обновление certbot; если не выйдет — пункт 4)"
    fi
    echo "4) Самоподписанный — домен или IP (10 лет, allowInsecure=true)"
    if ! read -r -p "Ваш выбор (1-4): " CERT_MODE; then
      echo
      warn "Ввод прерван (EOF) — беру самоподписанный (пункт 4)"
      CERT_MODE="4"
    fi
    case "$CERT_MODE" in
      1|2|3|4) ;;
      *) warn "Нет такого пункта — выберите 1-4"; continue ;;
    esac
    LE_EMAIL=""
    case "$CERT_MODE" in
      1|3)
        read -r -p "Email для Let's Encrypt (Enter — пропустить): " LE_EMAIL || { echo; LE_EMAIL=""; }
        if [ -n "$LE_EMAIL" ] && ! is_email "$LE_EMAIL"; then
          warn "Email выглядит некорректно — продолжаю без него"; LE_EMAIL=""
        fi ;;
    esac
    case "$CERT_MODE" in
      1) if [ "$kind" != "domain" ]; then
           err "LE-сертификаты на IP не выдаются — выберите пункт 3 или 4"; continue
         fi
         issue_cert_le_domain "$host" "$LE_EMAIL" || { err "Не вышло — исправьте проблему или выберите другой вариант"; continue; }
         FINAL_CRT="/etc/letsencrypt/live/$host/fullchain.pem"
         FINAL_KEY="/etc/letsencrypt/live/$host/privkey.pem" ;;
      2) install_cert_files "$host" || { err "Не вышло — положите fullchain.pem + privkey.pem в /root/cert/$host/ и попробуйте снова"; continue; }
         FINAL_CRT="/etc/nginx/ssl/$host/fullchain.pem"
         FINAL_KEY="/etc/nginx/ssl/$host/privkey.pem" ;;
      3) if [ "$kind" != "ip" ]; then
           err "Пункт 3 — для IP. Для домена выберите пункт 1"; continue
         fi
         issue_cert_le_ip "$host" "$LE_EMAIL" || { err "Не вышло — выберите другой вариант"; continue; }
         FINAL_CRT="/etc/letsencrypt/live/$host/fullchain.pem"
         FINAL_KEY="/etc/letsencrypt/live/$host/privkey.pem" ;;
      4) issue_cert_selfsigned "$host" "$kind" || { err "Не вышло — попробуйте снова"; continue; }
         FINAL_CRT="/etc/nginx/ssl/$host/fullchain.pem"
         FINAL_KEY="/etc/nginx/ssl/$host/privkey.pem" ;;
    esac
    return 0
  done
}

#=========================== ГЕНЕРАЦИЯ LOCATION ===============================
# Возвращает блок с НАСТОЯЩИМИ переводами строк (фикс v1 с буквальными \n)
generate_location_block() {
  local trans_type="$1" path_name="$2" target="$3" is_local="$4"
  local block="" domain_only=""
  # K-01 (аудит №2): в конфиг попадают ТОЛЬКО провалидированные значения.
  # Мусорный путь/таргет из панели/routes.tsv = отказ маршрута (пустой вывод
  # + сообщение в stderr), а не «нормализация»
  if ! is_nginx_path "$path_name"; then
    err "K-01: подозрительный путь «${path_name:0:60}» — маршрут НЕ добавлен в конфиг nginx"
    return 1
  fi
  if ! parse_hostport "$target"; then
    err "K-01: подозрительный таргет «${target:0:60}» — маршрут НЕ добавлен в конфиг nginx"
    return 1
  fi

  if [ "$trans_type" == "1" ]; then
    # === gRPC ===
    block=$(cat <<BLK

    # --- gRPC (${path_name}) ---
    location ${path_name} {
        if (\$content_type !~ "application/grpc") { return 404; }
        client_max_body_size 0;
        access_log off;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        grpc_pass grpc://${target};
"
    else
      domain_only="$R_HOST"
      block+="        grpc_pass grpcs://${target};
        grpc_ssl_server_name on;
        grpc_ssl_name ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "2" ]; then
    # === WebSocket ===
    block=$(cat <<BLK

    # --- WebSocket (${path_name}) ---
    location ${path_name} {
        if (\$http_upgrade != "websocket") { return 404; }
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "3" ]; then
    # === XHTTP / SplitHTTP ===
    block=$(cat <<BLK

    # --- XHTTP / SplitHTTP (${path_name}) ---
    location ${path_name} {
        client_max_body_size 0;
        access_log off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        keepalive_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "4" ]; then
    # === TCP (HTTP-обфускация) — обычный HTTP, БЕЗ websocket-проверки ===
    block=$(cat <<BLK

    # --- TCP/HTTP-obfs (${path_name}) ---
    location ${path_name} {
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        client_max_body_size 0;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"
  fi

  printf '%s' "$block"
}

# Проксирование веб-приложения (панель) по конфигу из wiki 3X-UI
generate_web_proxy_block() {
  local label="$1" path_name="$2" target="$3" scheme="$4"
  local proto="http"
  [ "$scheme" = "https" ] && proto="https"
  # K-01 (аудит №2): те же гарантии для панели/подписок
  if ! is_nginx_path "$path_name" || ! parse_hostport "$target"; then
    err "K-01: подозрительные путь/таргет (${label}) — блок НЕ добавлен в конфиг nginx"
    return 1
  fi
  cat <<BLK

    # --- ${label} (${path_name} -> ${target}) ---
    location ${path_name} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        access_log off;
        proxy_pass ${proto}://${target};
    }
BLK
}

# Раздача файлов подписок: /s-<token>/<subId> -> /var/lib/xkit/subs/<subId>
generate_subs_block() {
  cat <<BLK

    # --- подписки xkit (${SUBS_DIR}) ---
    location ^~ ${XKIT_SUB_PATH} {
        alias ${SUBS_DIR}/;
        default_type text/plain;
        add_header Referrer-Policy "no-referrer";
        add_header Cache-Control "no-store";
        add_header X-Robots-Tag "noindex, nofollow";
        access_log off;
    }
BLK
}
