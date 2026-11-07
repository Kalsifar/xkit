#!/bin/bash
# E2E v3: конфиг "одним шагом" (панель + подписки + 3 инбаунда) через настоящий nginx -t
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR%/tests}/nginx-xray-manager-v3.sh"
NGX=/tmp/ngxtest/rootfs/usr/sbin/nginx
NGXARGS="-p /tmp/ngxtest"
WORK=/tmp/ngxtest
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

export PATH=/tmp/ngxtest/rootfs/usr/sbin:$PATH
source "$SCRIPT" || exit 1

# сертификат как issue_cert_selfsigned
mkdir -p $WORK/ssl $WORK/tmp $WORK/body $WORK/proxy
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout $WORK/ssl/privkey.pem -out $WORK/ssl/fullchain.pem \
  -days 3650 -subj "/CN=203.0.113.10" -addext "subjectAltName=IP:203.0.113.10" 2>/dev/null
[ -s $WORK/ssl/fullchain.pem ]; chk "cert ok" 0 $?

# --- блоки как их генерирует v3.2: панель за nginx НЕ проксируется (она
# слушает 127.0.0.1 и доступна по SSH-туннелю) — в nginx живут только
# ws/grpc/xh-локейшены групп + статический блок подписок
LOC=""
LOC+=$(generate_location_block 2 /api-ws  127.0.0.1:2080 true)
LOC+=$(generate_location_block 1 /api-grp 127.0.0.1:2081 true)
LOC+=$(generate_location_block 3 /api-xh  127.0.0.1:2082 true)
# подписки — дословно как в nginx_ensure_sub_location
LOC+=$(cat <<'EOF'
    # --- Подписки клиентов (раздаёт сам xray-mesh) ---
    location ^~ /sub/ {
        alias /var/www/xmesh-subs/;
        default_type text/plain;
        add_header Cache-Control "no-store";
        access_log off;
    }
EOF
)

H2=$(build_h2_block)
H2="${H2/443/8443}"
echo "H2: [$H2]"

cat <<EOF > $WORK/site3.conf
server {
    listen 8080;
    server_name 203.0.113.10;
    return 301 https://\$host\$request_uri;
}
server {
$H2
    server_name 203.0.113.10;
    ssl_certificate $WORK/ssl/fullchain.pem;
    ssl_certificate_key $WORK/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    server_tokens off;
    keepalive_timeout 1h;
    client_max_body_size 0;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
$LOC
}
EOF

cat <<EOF > $WORK/nginx.conf
worker_processes 1;
error_log $WORK/error.log warn;
pid $WORK/nginx.pid;
events { worker_connections 64; }
http {
    access_log $WORK/access.log;
    client_body_temp_path $WORK/body;
    proxy_temp_path $WORK/proxy;
    fastcgi_temp_path $WORK/proxy;
    uwsgi_temp_path $WORK/proxy;
    scgi_temp_path $WORK/proxy;
    include $WORK/site3.conf;
}
EOF

if $NGX $NGXARGS -t -c $WORK/nginx.conf > $WORK/t3.out 2>&1; then
  chk "one-step config (subs+3 inbounds): nginx -t OK" 0 0
else
  chk "one-step config: nginx -t OK" 0 1
  cat $WORK/t3.out
fi

# повторная вставка через механизм ветки 2 (nginx_ensure_group_location:
# generate_location_block + вставка блока в готовый конфиг)
NEWB=$(generate_location_block 2 "/grp2" "127.0.0.1:2083" "true")
cp $WORK/site3.conf $WORK/site3b.conf
sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' $WORK/site3b.conf
[ "$(tail -n 1 $WORK/site3b.conf | xargs)" = "}" ]; chk "last line }" 0 $?
{ head -n -1 $WORK/site3b.conf; printf '%s\n' "$NEWB"; echo "}"; } > $WORK/site3b.tmp
mv $WORK/site3b.tmp $WORK/site3b.conf
sed -i "s#include $WORK/site3.conf#include $WORK/site3b.conf#" $WORK/nginx.conf
if $NGX $NGXARGS -t -c $WORK/nginx.conf > $WORK/t3b.out 2>&1; then
  chk "add panel via branch2 mechanism: nginx -t OK" 0 0
else
  chk "add panel via branch2: nginx -t OK" 0 1
  cat $WORK/t3b.out
fi

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "E2E ALL PASSED" || exit 1
