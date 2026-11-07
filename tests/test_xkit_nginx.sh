#!/bin/bash
# E2E XKIT v4.0: полный gen_xkit_conf (панель + подписки + 5 маршрутов) через настоящий nginx -t
set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/xkit.sh"
NGX=/tmp/ngxtest/rootfs/usr/sbin/nginx
WORK=/tmp/ngxtest
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

if [ ! -x "$NGX" ]; then
  echo "nginx-харнесс не найден — восстанавливаю из deb..."
  mkdir -p $WORK/rootfs
  cd $WORK && apt-get download nginx >/dev/null 2>&1 && dpkg -x nginx_*.deb $WORK/rootfs && rm -f nginx_*.deb
fi
export PATH=/tmp/ngxtest/rootfs/usr/sbin:$PATH

source "$SCRIPT" || exit 1

# --- состояние как после one_step_install ---
TD=$WORK/xkit-e2e
rm -rf "$TD"; mkdir -p "$TD/ssl" "$TD/subs" "$TD/tmp" "$TD/body" "$TD/proxy"
XKIT_HOST="203.0.113.10"
XKIT_ROUTES="$TD/routes.tsv"; : > "$XKIT_ROUTES"
XKIT_ENV="$TD/xkit.env"
SUBS_DIR="$TD/subs"
XKIT_SUB_TOKEN="e2etoken12345678"
PANEL_PORT=2090; PANEL_WBP="/abcd1234/"; PANEL_SCHEME=http

openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$TD/ssl/privkey.pem" -out "$TD/ssl/fullchain.pem" \
  -days 30 -subj "/CN=203.0.113.10" -addext "subjectAltName=IP:203.0.113.10" 2>/dev/null
XKIT_CRT="$TD/ssl/fullchain.pem"; XKIT_KEY="$TD/ssl/privkey.pem"
[ -s "$XKIT_CRT" ]; chk "self-signed cert создан" 0 $?

# файл подписки как их создаёт sub_regen
printf 'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=ws&security=tls#e2e' | base64 -w0 > "$SUBS_DIR/sube2e1234567890"
chmod 644 "$SUBS_DIR/sube2e1234567890"

# маршруты: ws, grpc, xhttp, tcp+http (local) + relay на localhost (резолвится без DNS)
routes_upsert 11 local ws    /xk-ws-2083/  127.0.0.1:2083 "wstag"
routes_upsert 22 local grpc  /xk-gr-2084/  127.0.0.1:2084 "grtag"
routes_upsert 33 local xhttp /xk-xh-2085/  127.0.0.1:2085 "xhtag"
routes_upsert 44 local tcp   /my-tc-path/  127.0.0.1:2086 "tctag"
routes_upsert m1 relay ws    /relay1/      localhost:8443 "relay"

# nginx 1.26.3 >= 1.25.1 → ожидаем новый синтаксис http2
V="$(nginx_ver)"
chk "nginx харнесс 1.26.3" "$(ver_ge "$V" "1.25.1" && echo y)" y

gen_xkit_conf > "$TD/site.conf"; chk "gen_xkit_conf rc" 0 $?
grep -q "http2 on;" "$TD/site.conf"; chk "новый синтаксис http2 on" 0 $?

# порты 80/443 -> 8080/8443 (песочница без root), panel 2090 не занят
sed -i 's/listen 80;/listen 8080;/; s/listen 443 ssl;/listen 8443 ssl;/' "$TD/site.conf"

cat <<EOF > "$TD/nginx.conf"
worker_processes 1;
error_log $TD/error.log warn;
pid $TD/nginx.pid;
events { worker_connections 64; }
http {
    access_log $TD/access.log;
    client_body_temp_path $TD/body;
    proxy_temp_path $TD/proxy;
    fastcgi_temp_path $TD/proxy;
    uwsgi_temp_path $TD/proxy;
    scgi_temp_path $TD/proxy;
    include $TD/site.conf;
}
EOF

if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t.out" 2>&1; then
  chk "полный xkit.conf (панель+подписки+5 маршрутов): nginx -t OK" 0 0
else
  chk "полный xkit.conf: nginx -t OK" 0 1
  cat "$TD/t.out"
fi

# идемпотентность: повторная генерация даёт валидный конфиг
gen_xkit_conf > "$TD/site2.conf"
sed -i 's/listen 80;/listen 8080;/; s/listen 443 ssl;/listen 8443 ssl;/' "$TD/site2.conf"
sed -i "s#include $TD/site.conf#include $TD/site2.conf#" "$TD/nginx.conf"
if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t2.out" 2>&1; then
  chk "повторная генерация: nginx -t OK (идемпотентность)" 0 0
else
  chk "повторная генерация: nginx -t OK" 0 1
  cat "$TD/t2.out"
fi

# старый синтаксис для nginx < 1.25.1 (имитация Ubuntu 24.04 с nginx 1.24)
sed -i 's/listen 8443 ssl;/listen 8443 ssl http2;/; /^    http2 on;$/d' "$TD/site.conf"
sed -i "s#include $TD/site2.conf#include $TD/site.conf#" "$TD/nginx.conf"
if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t3.out" 2>&1; then
  chk "старый синтаксис (nginx 1.24, Ubuntu 24.04): nginx -t OK" 0 0
else
  chk "старый синтаксис: nginx -t OK" 0 1
  cat "$TD/t3.out"
fi

# v4.1: нативные подписки панели + внутренний Reality-сервер (dest для xray)
XKIT_PANEL_SUB_PORT=41234; XKIT_PANEL_SUB_PATH="/sub-e2etok/"; XKIT_REALITY_INTERNAL=1
gen_xkit_conf > "$TD/site4.conf"
chk "v4.1 блоки в конфиге" "$(grep -c 'proxy_pass http://127.0.0.1:41234;\|listen 127.0.0.1:8444 ssl' "$TD/site4.conf")" 2
sed -i 's/listen 80;/listen 8080;/; s/listen 443 ssl;/listen 8443 ssl;/; s/listen 127.0.0.1:8444 ssl;/listen 127.0.0.1:9444 ssl;/' "$TD/site4.conf"
sed -i "s#include $TD/site.conf#include $TD/site4.conf#" "$TD/nginx.conf"
if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t4.out" 2>&1; then
  chk "v4.1 (подписки панели + internal Reality): nginx -t OK" 0 0
else
  chk "v4.1 блоки: nginx -t OK" 0 1
  cat "$TD/t4.out"
fi
XKIT_PANEL_SUB_PORT=""; XKIT_REALITY_INTERNAL=0

# v4.6 (ревью): IPv6-listen, XKIT_V6_LISTEN=1. Регресс: без двоеточия в
# [::]:443 nginx -t падал (invalid parameter) и ломал ЛЮБОЙ apply_config
# на серверах с глобальным IPv6; дубль http2 on; давал бы duplicate directive
XKIT_V6_LISTEN=1
gen_xkit_conf > "$TD/site5.conf"; chk "v6: gen_xkit_conf rc" 0 $?
grep -q 'listen \[::\]:443 ssl;' "$TD/site5.conf"; chk "v6: listen [::]:443 (двоеточие!)" 0 $?
if grep -q 'listen \[::\] [0-9]' "$TD/site5.conf"; then chk "v6: нет listen [::] без порта (старый баг)" 0 1; else chk "v6: нет listen [::] без порта (старый баг)" 0 0; fi
chk "v6: http2 on; ровно один (без дубля)" "$(grep -c 'http2 on;' "$TD/site5.conf")" 1
grep -q 'listen \[::\]:80;' "$TD/site5.conf"; chk "v6: [::]:80 в редирект-блоке" 0 $?
sed -i 's/listen 80;/listen 8080;/; s/listen \[::\]:80;/listen [::]:8080;/; s/listen 443 ssl;/listen 8443 ssl;/; s/listen \[::\]:443 ssl;/listen [::]:8443 ssl;/' "$TD/site5.conf"
sed -i "s#include $TD/site4.conf#include $TD/site5.conf#" "$TD/nginx.conf"
if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t5.out" 2>&1; then
  chk "v6-конфиг: nginx -t OK (новый синтаксис, nginx >= 1.25.1)" 0 0
else
  chk "v6-конфиг: nginx -t OK" 0 1
  cat "$TD/t5.out"
fi

# v6 + старый синтаксис (имитация Ubuntu 24.04 / nginx 1.24): http2 в listen
sed -i 's/listen 8443 ssl;/listen 8443 ssl http2;/; s/listen \[::\]:8443 ssl;/listen [::]:8443 ssl http2;/; /^    http2 on;$/d' "$TD/site5.conf"
if $NGX -p $WORK -t -c "$TD/nginx.conf" > "$TD/t6.out" 2>&1; then
  chk "v6 + старый синтаксис (nginx 1.24): nginx -t OK" 0 0
else
  chk "v6 + старый синтаксис: nginx -t OK" 0 1
  cat "$TD/t6.out"
fi

# v4-only (XKIT_V6_LISTEN=0): [::] в конфиге быть не должно — прежнее поведение
XKIT_V6_LISTEN=0
gen_xkit_conf > "$TD/site6.conf"
if grep -q '\[::\]' "$TD/site6.conf"; then chk "v4-only: нет [::] при XKIT_V6_LISTEN=0" 0 1; else chk "v4-only: нет [::] при XKIT_V6_LISTEN=0" 0 0; fi
XKIT_V6_LISTEN=auto

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "E2E ALL PASSED" || exit 1
