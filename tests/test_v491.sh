#!/bin/bash
# Тесты XKIT v4.9.1 (совместимость с 3X-UI v3.x — CSRF + переезд эндпоинтов):
#  1) версия/синтаксис + changelog + статика CSRF-кода
#  2) FAKE ПАНЕЛЬ v3 (поведенчески): GET csrf-token -> POST /login с X-CSRF-Token;
#     POST /login БЕЗ токена = 403 с ПУСТЫМ телом (ровно баг живой установки v4.9.0);
#     kit_session проходит, API_V3=1, CSRF_TOKEN получен
#  3) kit_login: диагностика — закрытый порт («Панель не отвечает», curl exit),
#     неверный пароль (HTTP 200 + «Ответ:»), 403 (подсказка «xkit update»)
#  4) клиенты v3: add -> /panel/api/clients/add {"client":..,"inboundIds":[id]},
#     del -> /panel/api/clients/del/:email, reset -> .../resetTraffic/:email
#  5) hosts v3: v3_host_upsert — add, повтор -> update того же groupId (без дублей)
#  6) настройки v3: panel_settings_get POST /panel/api/setting/all; set -> /update
#  7) xray-шаблон v3: чтение .obj.xraySetting (ОБЪЕКТ), запись POST /panel/api/xray/update
#  8) FAKE ПАНЕЛЬ v2 (поведенчески): csrf-роута нет — kit_session работает,
#     API_V3=0; addClient уходит в panel/api/inbounds/addClient со settings-строкой
set -u
PASS=0; FAIL=0
ck() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  [OK]   $1"
  else FAIL=$((FAIL+1)); echo "  [FAIL] $1"; fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${SCRIPT_DIR%/tests}"
XKIT="${BASE}/xkit.sh"
[ -f "$XKIT" ] || XKIT="${SCRIPT_DIR%/tests}/xkit.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== 1. Версия, синтаксис, статика CSRF-кода ==="
rg -q 'XKIT_VERSION="(4\.[456789]|5\.)' "$XKIT"; ck "версия 4.4-4.9/5.x" $?
rg -q 'История:      CHANGES\.md' "$XKIT"; ck "история вынесена в CHANGES.md" $?
bash -n "$XKIT" 2>/dev/null; ck "bash -n xkit.sh" $?
rg -q 'csrf-token' "$XKIT" && rg -q 'X-CSRF-Token' "$XKIT"; ck "xkit: csrf-token + заголовок X-CSRF-Token" $?
rg -q 'csrf_fetch\(\)' "$XKIT" && rg -q 'api_detect_generation\(\)' "$XKIT"; ck "xkit: csrf_fetch + api_detect_generation" $?
rg -q 'panel/api/clients/add' "$XKIT" && rg -q 'panel/api/clients/del/' "$XKIT" && rg -q 'panel/api/clients/resetTraffic/' "$XKIT"; ck "xkit: клиентские роуты v3" $?
rg -q 'panel/api/setting/all' "$XKIT" && rg -q 'panel/api/xray/update' "$XKIT"; ck "xkit: настройки и xray-шаблон v3" $?
rg -q 'panel/api/hosts' "$XKIT" && rg -q 'v3_host_upsert\(\)' "$XKIT"; ck "xkit: hosts вместо externalProxy (v3)" $?

#========================== FAKE ПАНЕЛЬ (python3) ==============================
cat > "$T/fake_panel.py" <<'PYEOF'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1]          # "v3" | "v2"
PORT = int(sys.argv[2])
BASE = sys.argv[3]          # "/MnTest123/"
LOG  = sys.argv[4]          # jsonl-лог запросов
lock = threading.Lock()
sess = {}                   # sid -> {"token": str, "authed": bool}
hosts = []                  # v3: host-группы
hsid = [0]
hscore = [0]

def log_req(h, body=None):
    with lock:
        with open(LOG, "a") as f:
            f.write(json.dumps({"m": h.command, "p": h.path,
                                "csrf": h.headers.get("X-CSRF-Token"),
                                "cookie": h.headers.get("Cookie", ""),
                                "body": body}) + "\n")

def session(h):
    c = h.headers.get("Cookie", "")
    for part in c.split(";"):
        part = part.strip()
        if part.startswith("sid="):
            sid = part[4:]
            return sid, sess.get(sid, None)
    return None, None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj=None, raw=None, cookie=None):
        data = (raw if raw is not None else json.dumps(obj)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if cookie: self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(data)

    def new_sid(self, authed=False):
        hsid[0] += 1
        sid = "s%d" % hsid[0]
        import secrets
        sess[sid] = {"token": "tok-" + secrets.token_hex(8), "authed": authed}
        return sid, "sid=%s; Path=/" % sid

    def do_GET(self):
        p = self.path
        if MODE == "v3":
            if p == BASE + "csrf-token":
                # EnsureCSRFToken: используется СУЩЕСТВУЮЩАЯ сессия (в т.ч. авторизованная)
                sid, st = session(self)
                if st is None:
                    sid, ck = self.new_sid()
                else:
                    st["token"] = "tok-" + sid
                    ck = "sid=%s; Path=/" % sid
                log_req(self)
                return self.send(200, {"success": True, "obj": sess[sid]["token"]}, cookie=ck)
            if p == BASE + "panel/api/openapi.json":
                log_req(self)
                _, st = session(self)
                if not (st or {}).get("authed"):
                    return self.send(401, {"success": False, "msg": "unauthorized"})
                return self.send(200, {"openapi": "3.0.1", "info": {"title": "3x-ui"}})
            if p == BASE + "panel/api/inbounds/list":
                log_req(self)
                _, st = session(self)
                if not (st or {}).get("authed"):
                    return self.send(401, {"success": False, "msg": "unauthorized"})
                return self.send(200, {"success": True, "msg": "", "obj": []})
            if p == BASE + "panel/api/hosts/list":
                log_req(self)
                _, st = session(self)
                if not (st or {}).get("authed"):
                    return self.send(401, {"success": False, "msg": "unauthorized"})
                return self.send(200, {"success": True, "obj": hosts})
            if p == BASE or p == BASE + "login":
                log_req(self)
                return self.send(200, raw="<html>login</html>")
        else:  # v2
            if p == BASE + "csrf-token":
                log_req(self)
                return self.send(404, raw="404 page not found\n")
            if p == BASE + "panel/api/inbounds/list":
                log_req(self)
                return self.send(200, {"success": True, "msg": "", "obj": []})
            if p == BASE + "panel/setting/all":
                log_req(self)
                return self.send(200, {"success": True, "obj": {"subPort": "20951"}})
            if p == BASE or p == BASE + "login":
                log_req(self)
                return self.send(200, raw="<html>login</html>")
        self.send(404, raw="404 page not found\n")

    def do_POST(self):
        p = self.path
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode() if n else ""
        log_req(self, raw)

        if MODE == "v3":
            sid, s = session(self)
            # СТРОГО как в реальном 3x-ui: CSRFMiddleware; нет сессии/токена -> 403
            # С ПУСТЫМ телом (после логина s.Clear() СТИРАЕТ токен из сессии)
            if p in (BASE + "login", BASE + "logout") or p.startswith(BASE + "panel/api/"):
                if p.startswith(BASE + "panel/api/"):
                    if not (s or {}).get("authed"):
                        return self.send(401, {"success": False, "msg": "unauthorized"})
                tok = (s or {}).get("token") or ""
                if not tok or self.headers.get("X-CSRF-Token") != tok:
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            if p == BASE + "login":
                import urllib.parse
                form = dict(urllib.parse.parse_qsl(raw))
                if form.get("username") == "admin" and form.get("password") == "goodpass":
                    if s is not None:
                        s["authed"] = True
                        s["token"] = ""   # SetLoginUser -> s.Clear(): токен аннулирован
                        ck = "sid=%s; Path=/" % sid
                    else:
                        sid, ck = self.new_sid(authed=True)
                    return self.send(200, {"success": True, "msg": "", "obj": None}, cookie=ck)
                return self.send(200, {"success": False, "msg": "wrong username or password"})
            if p == BASE + "panel/api/clients/add":
                try: b = json.loads(raw)
                except Exception: return self.send(200, {"success": False, "msg": "bad json"})
                if not isinstance(b.get("client"), dict) or not isinstance(b.get("inboundIds"), list):
                    return self.send(200, {"success": False, "msg": "wrong payload shape"})
                return self.send(200, {"success": True, "msg": "", "obj": None})
            if p.startswith(BASE + "panel/api/clients/del/") or \
               p.startswith(BASE + "panel/api/clients/resetTraffic/"):
                return self.send(200, {"success": True, "msg": "", "obj": None})
            if p == BASE + "panel/api/setting/all":
                return self.send(200, {"success": True, "obj": {"subPort": "20951",
                    "subPath": "/sub-abc/", "subEnable": "true"}})
            if p == BASE + "panel/api/setting/update":
                return self.send(200, {"success": True, "msg": ""})
            if p == BASE + "panel/api/setting/restartPanel":
                return self.send(200, {"success": True, "msg": ""})
            if p == BASE + "panel/api/xray/":
                return self.send(200, {"success": True, "obj": {"xraySetting":
                    {"log": {"loglevel": "warning"}}, "inboundTags": []}})
            if p == BASE + "panel/api/xray/update":
                return self.send(200, {"success": True, "msg": ""})
            if p == BASE + "panel/api/hosts/add":
                try: b = json.loads(raw)
                except Exception: return self.send(200, {"success": False, "msg": "bad json"})
                hscore[0] += 1
                g = dict(b); g["groupId"] = "g%d" % hscore[0]
                hosts.append(g)
                return self.send(200, {"success": True, "obj": g})
            if p.startswith(BASE + "panel/api/hosts/update/"):
                gid = p.rsplit("/", 1)[1]
                try: b = json.loads(raw)
                except Exception: return self.send(200, {"success": False, "msg": "bad json"})
                for i, g in enumerate(hosts):
                    if g.get("groupId") == gid:
                        hosts[i] = dict(b, groupId=gid)
                        return self.send(200, {"success": True, "obj": hosts[i]})
                return self.send(200, {"success": False, "msg": "no group"})
        else:  # v2
            if p == BASE + "login":
                return self.send(200, {"success": True, "msg": "", "obj": None})
            if p == BASE + "panel/api/inbounds/addClient":
                try: b = json.loads(raw)
                except Exception: return self.send(200, {"success": False, "msg": "bad json"})
                if "id" not in b or "settings" not in b:
                    return self.send(200, {"success": False, "msg": "wrong payload shape"})
                return self.send(200, {"success": True, "msg": "", "obj": None})
            if p == BASE + "panel/setting/update" or p == BASE + "panel/setting/all":
                return self.send(200, {"success": True, "msg": ""})
        self.send(404, raw="404 page not found\n")

srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
srv.serve_forever()
PYEOF

# свободные порты
P3=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
P2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
BP="/MnTest123/"
python3 "$T/fake_panel.py" v3 "$P3" "$BP" "$T/log3.jsonl" >/dev/null 2>&1 & PID3=$!
python3 "$T/fake_panel.py" v2 "$P2" "$BP" "$T/log2.jsonl" >/dev/null 2>&1 & PID2=$!
trap 'kill $PID3 $PID2 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.7

# подмена цели на закрытый порт для теста диагностики
CLOSED=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

# запуск функции xkit против фейка: stdout = результат, stderr сохраняем
xf() { # $1 порт, $2... — код в subshell (PANEL_* читаются из install-result.env)
  local port="$1"; shift
  printf 'XUI_PANEL_PORT=%s\nXUI_WEB_BASE_PATH=%s\nXUI_USERNAME=admin\nXUI_PASSWORD=goodpass\n' \
    "$port" "$BP" > "$T/result.env"
  XF_PORT="$port" bash -c '
    source "'"$XKIT"'" 2>/dev/null
    XKIT_ENV="'"$T"'/no.env"; XUI_RESULT="'"$T"'/result.env"
    read_panel_settings >/dev/null || exit 3
    PANEL_SCHEME="http"
    '"$*"'
  ' 2>"$T/err.txt"
}

echo "=== 2. Воспроизведение бага: POST /login без CSRF = 403 с пустым телом ==="
code=$(curl -s -o "$T/resp.bin" -w '%{http_code}' -X POST "http://127.0.0.1:${P3}${BP}login" \
  --data-urlencode "username=admin" --data-urlencode "password=goodpass")
[ "$code" = "403" ]; ck "панель v3 без X-CSRF-Token отвечает 403 (баг существует)" $?
[ ! -s "$T/resp.bin" ]; ck "тело ответа 403 ПУСТОЕ (симптом «нет строки Ответ:»)" $?

echo "=== 3. kit_session против панели v3 (фикс) ==="
out=$(xf "$P3" 'kit_session && echo "API_V3=$API_V3 CSRF=[${CSRF_TOKEN:0:8}...]"')
echo "$out" | tail -1
grep -q "API_V3=1" <<<"$out"; ck "kit_session: логин прошёл, поколение API определено (API_V3=1)" $?
rg -q "CSRF=\[tok-" <<<"$out"; ck "CSRF_TOKEN получен от /csrf-token" $?

echo "=== 4. kit_login: диагностика ==="
errout=$(xf "$CLOSED" 'kit_login' 2>&1 >/dev/null; cat "$T/err.txt")
rg -q "Панель не отвечает" <<<"$errout" && rg -q "curl exit" <<<"$errout"; ck "закрытый порт -> «Панель не отвечает (curl exit N)»" $?
errout=$(xf "$P3" 'PANEL_PASS="badpass"; kit_login' 2>&1 >/dev/null; cat "$T/err.txt")
rg -q "Не удалось войти в API панели" <<<"$errout" && rg -q "HTTP 200" <<<"$errout" && rg -q "Ответ:" <<<"$errout"; ck "неверный пароль -> HTTP-код + тело ответа" $?

echo "=== 5. Клиенты на панели v3 (новые роуты) ==="
out=$(xf "$P3" '
  kit_session || exit 1
  CJ="{\"id\":\"uuid-1111\",\"flow\":\"\",\"email\":\"u1@mail\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"sub123\",\"reset\":0}"
  api_add_client 7 "$CJ" "{\"clients\":[]}" && echo ADD_OK
  api_del_client 7 "u1@mail" "uuid-1111" && echo DEL_OK
  api_post_raw "panel/api/clients/resetTraffic/u1@mail" >/dev/null && echo RESET_SENT
')
rg -q "ADD_OK" <<<"$out"; ck "api_add_client -> /panel/api/clients/add" $?
rg -q "DEL_OK" <<<"$out"; ck "api_del_client -> /panel/api/clients/del/:email" $?
rg -q "RESET_SENT" <<<"$out"; ck "сброс трафика -> /panel/api/clients/resetTraffic/:email" $?
jq -s -e '[.[] | select(.p=="'"$BP"'panel/api/clients/add") | .body | fromjson | select(.client.id=="uuid-1111" and .inboundIds==[7])] | length == 1' \
  "$T/log3.jsonl" >/dev/null; ck "тело clients/add: {client:{...}, inboundIds:[id]}" $?
jq -s -e '[.[] | select(.p=="'"$BP"'panel/api/clients/del/u1@mail")] | length == 1' "$T/log3.jsonl" >/dev/null; ck "del/:email дошёл до панели" $?

echo "=== 6. CSRF-заголовок на API-запросах ==="
jq -s -e '[.[] | select(.p=="'"$BP"'panel/api/clients/add") | .csrf | select(startswith("tok-"))] | length == 1' "$T/log3.jsonl" >/dev/null; ck "clients/add шлёт X-CSRF-Token (иначе 403 в v3)" $?

echo "=== 7. Настройки и xray-шаблон на панели v3 ==="
out=$(xf "$P3" '
  kit_session || exit 1
  S="$(panel_settings_get)" && jq -r ".obj.subPort" <<<"$S"
')
[ "$(echo "$out" | tail -1)" = "20951" ]; ck "panel_settings_get читает .obj.subPort через POST setting/all" $?
out=$(xf "$P3" '
  kit_session || exit 1
  panel_settings_set "subEnable=true" "subPort=20951" && echo SET_OK
  R="$(api_post_json "panel/api/xray/" "{}")" && jq -r ".obj.xraySetting.log.loglevel" <<<"$R"
')
rg -q "SET_OK" <<<"$out"; ck "panel_settings_set -> panel/api/setting/update" $?
[ "$(echo "$out" | tail -1)" = "warning" ]; ck "xray-шаблон v3: .obj.xraySetting (объект) читается" $?
out=$(xf "$P3" '
  kit_session || exit 1
  api_post_raw "panel/api/xray/update" --data-urlencode "xraySetting={\"log\":{}}" >/dev/null && echo XRAY_SAVED
')
rg -q "XRAY_SAVED" <<<"$out"; ck "запись шаблона -> POST panel/api/xray/update" $?

echo "=== 8. v3_host_upsert: add, затем update того же groupId ==="
out=$(xf "$P3" '
  kit_session || exit 1
  v3_host_upsert 7 "1.2.3.4" 443 tls && echo UPSERT1_OK
  v3_host_upsert 7 "5.6.7.8" 8443 tls && echo UPSERT2_OK
')
rg -q "UPSERT1_OK" <<<"$out" && rg -q "UPSERT2_OK" <<<"$out"; ck "оба upsert прошли" $?
[ "$(jq -s '[.[] | select(.p=="'"$BP"'panel/api/hosts/add")] | length' "$T/log3.jsonl")" = "1" ]; ck "создана ОДНА группа (нет дублей при повторе)" $?
jq -e 'select(.p=="'"$BP"'panel/api/hosts/update/g1") | .body | fromjson | select(.hosts==["5.6.7.8"] and .port==8443)' \
  "$T/log3.jsonl" >/dev/null; ck "повтор пошёл в update/g1 с новым адресом" $?

echo "=== 9. Фолбэк v2: всё по-старому ==="
out=$(xf "$P2" 'kit_session && echo "API_V3=$API_V3 CSRF=[${CSRF_TOKEN}]"')
rg -q "API_V3=0" <<<"$out"; ck "панель v2: API_V3=0" $?
out=$(xf "$P2" '
  kit_session || exit 1
  CJ="{\"id\":\"uuid-2222\",\"email\":\"u2@mail\",\"subId\":\"s2\"}"
  api_add_client 9 "$CJ" "{\"clients\":[{\"email\":\"old\"}]}" && echo ADD2_OK
')
rg -q "ADD2_OK" <<<"$out"; ck "v2: addClient уходит в panel/api/inbounds/addClient" $?
jq -e 'select(.p=="'"$BP"'panel/api/inbounds/addClient") | .body | fromjson | select(.id==9 and (.settings|fromjson|.clients[1].id=="uuid-2222"))' \
  "$T/log2.jsonl" >/dev/null; ck "v2: тело {id, settings} с добавленным клиентом" $?
[ "$(jq -s '[.[] | select(.csrf != null)] | length' "$T/log2.jsonl")" = "0" ]; ck "v2: заголовок CSRF не отправляется (панель без токена)" $?

echo ""
echo "================================"
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
