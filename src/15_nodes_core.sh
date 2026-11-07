
node_own_key() {
  local key="${XKIT_DIR}/id_ed25519"
  # приватный ключ: каталог обязан быть 0700 ДО генерации (аудит №7) —
  # save_xkit_env мог ещё не выполняться
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  chmod 700 "$XKIT_DIR" 2>/dev/null || true
  [ -f "$key" ] || ssh-keygen -t ed25519 -N "" -f "$key" -C "xkit-node" -q >/dev/null 2>&1
  printf '%s' "$key"
}

node_ssh() { # $1 rec-json, остальные — команда на ноде
  local rec="$1"; shift
  local host port user auth key
  host="$(jq -r '.host' <<<"$rec")"
  port="$(jq -r '.ssh_port // 22' <<<"$rec")"
  user="$(jq -r '.ssh_user // "root"' <<<"$rec")"
  auth="$(jq -r '.auth // "key"' <<<"$rec")"
  key="$(jq -r '.key_path // ""' <<<"$rec")"
  # постоянный known_hosts: первый коннект TOFU (accept-new), дальше — жёсткая проверка ключа
  local kh="${XKIT_DIR}/known_hosts"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true; touch "$kh" 2>/dev/null || true; chmod 600 "$kh" 2>/dev/null || true
  # V-05 (аудит №2): отпечаток показывается и подтверждается ДО первого
  # коннекта — при парольной аутентификации sshpass отправляет пароль сразу
  node_ssh_host_key "$host" "$port" "$kh" \
    || { err "Ключ хоста ${host}:${port} не подтверждён — подключение отменено (V-05)"; return 1; }
  local -a a=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" -o ConnectTimeout=10 -p "$port")
  if [ "$auth" = "password" ]; then
    command -v sshpass >/dev/null 2>&1 || { err "sshpass не найден (apt install sshpass)"; return 1; }
    SSHPASS="$NODE_SSH_PASS" sshpass -e ssh "${a[@]}" "${user}@${host}" "$@"
  else
    ssh -i "$key" -o BatchMode=yes "${a[@]}" "${user}@${host}" "$@"
  fi
}

# узел-TOFU (V-05): снимаем ключ через keyscan, показываем отпечаток, ждём
# подтверждения ДО того, как что-то (тем более пароль) уедет на ноду
node_ssh_host_key() { # $1 host, $2 port, $3 known_hosts -> 0 = можно подключаться
  local host="$1" port="$2" kh="$3" scan fp a
  ssh-keygen -F "[${host}]:${port}" -f "$kh" >/dev/null 2>&1 && return 0
  ssh-keygen -F "${host}" -f "$kh" >/dev/null 2>&1 && return 0
  scan="$(timeout 15 ssh-keyscan -T 8 -p "$port" "$host" 2>/dev/null)" || scan=""
  [ -n "$scan" ] || { err "Не удалось снять отпечаток ключа ${host}:${port} (V-05)"; return 1; }
  fp="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  warn "Первое подключение к ${host}:${port}; отпечаток ключа: ${fp:-?}"
  if [ "${XKIT_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    warn "Принимаю без подтверждения (XKIT_YES/не-интерактив; TOFU — сверьте с консолью провайдера)"
  else
    read -r -p "Совпадает с консолью провайдера? [y/N]: " a || a=""
    case "$a" in y|Y|yes|Yes) ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$scan" >> "$kh"
  return 0
}

# отпечаток публичного ключа сертификата (пин, как SSH TOFU): защита panel-API
# ноды от MITM. Снимается при добавлении ноды и проверяется curl при каждом вызове
cert_pin() { # $1 host, $2 port -> base64 sha256 публичного ключа (или пусто)
  echo | timeout 8 openssl s_client -connect "$1:$2" -servername "$1" 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | base64 -w0 2>/dev/null
}

node_api() { # $1 rec, $2 path, $3 method, $4 JSON-body, $5 cookie
  local rec="$1" path="$2" method="${3:-GET}" body="${4:-}" ck="$5"
  local base url tls sch="http"
  base="$(normalize_panel_path "$(jq -r '.panel.base // "/"' <<<"$rec")")"
  tls="$(jq -r '.panel.tls // "false"' <<<"$rec")"
  [ "$tls" = "true" ] && sch="https"
  url="${sch}://$(jq -r '.host' <<<"$rec"):$(jq -r '.panel.port' <<<"$rec")${base}"
  local -a a=(-s --max-time 20 -c "$ck" -b "$ck" -X "$method")
  if [ "$sch" = "https" ]; then
    local pin; pin="$(jq -r '.panel.pincert // ""' <<<"$rec")"
    if [ -n "$pin" ]; then
      a+=(--pinnedpubkey "sha256//$pin")   # пин снят при добавлении — MITM не пройдёт
    else
      a+=(-k)   # самоподписанный сертификат панели ноды (пина нет)
    fi
  fi
  [ -n "$body" ] && a+=(-H 'Content-Type: application/json' --data @-)
  # V-03 (аудит №2): тело через stdin — пароль панели ноды не виден в /proc/<pid>/cmdline
  if [ -n "$body" ]; then
    printf '%s' "$body" | curl "${a[@]}" "${url}${path}"
  else
    curl "${a[@]}" "${url}${path}"
  fi
}

node_login() { # $1 rec, $2 cookie
  local rec="$1" ck="$2" out
  out="$(node_api "$rec" "login" POST \
    "$(jq -nc --arg u "$(jq -r '.panel.user' <<<"$rec")" --arg p "$(jq -r '.panel.pass' <<<"$rec")" '{username:$u,password:$p}')" \
    "$ck")"
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1
}

nodes_load() {
  # битый nodes.json не должен ронять jq у вызывающих и показывать «одиночный
  # сервер» при наличии нод (аудит №11): не массив — считаем нод нет + warn в stderr
  if [ -s "$XKIT_NODES" ] && jq -e 'type=="array"' "$XKIT_NODES" >/dev/null 2>&1; then
    cat "$XKIT_NODES"
  else
    [ -s "$XKIT_NODES" ] && echo -e "${YELLOW}[WARN] nodes.json повреждён (не массив) — считаю, что нод нет; восстановите из бэкапа или переподключите ноды${NC}" >&2
    printf '[]'
  fi
}

nodes_ensure_pool() {
  if [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    if jq -e --argjson id "${XKIT_POOL_INBOUND:-0}" 'any(.[]; .id==$id)' <<<"$INBOUNDS" >/dev/null 2>&1; then
      XKIT_POOL_TAG="$(jq -r --argjson id "$XKIT_POOL_INBOUND" \
        '[.[]|select(.id==$id)][0].tag // "inbound-pool"' <<<"$INBOUNDS")"
      # early-return ТОЛЬКО если nginx реально знает маршрут pool:
      # после сбоя apply env мог остаться со старым id — тогда пересоздаём,
      # иначе «нода в реестре, но без маршрута» и reapply невозможен
      local pib ppath
      pib="$(jq -c --argjson id "$XKIT_POOL_INBOUND" '[.[]|select(.id==$id)][0]' <<<"$INBOUNDS" 2>/dev/null)"
      ppath="$(jq -r '.streamSettings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | .wsSettings.path // ""' <<<"${pib:-}" 2>/dev/null)"
      if [ -n "$ppath" ] && grep -qF "location ${ppath}" "$XKIT_CONF" 2>/dev/null; then
        return 0
      fi
      warn "Pool-инбаунд #${XKIT_POOL_INBOUND} есть, но маршрута в nginx нет (${ppath:-путь не найден}) — пересоздаю"
    fi
  fi
  local port path uuid subid email settings stream ib
  port="$(rand_free_port 20000 40000)" || { err "Нет свободного порта для pool"; return 1; }
  path="$(auto_path_for ws "$port")"
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="pool-$(rand_hex 2)"
  settings="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" '
    {clients:[{id:$id, flow:"", email:$email, limitIp:0, totalGB:0, expiryTime:0,
               enable:true, tgId:"", subId:$sub, reset:0}], decryption:"none", fallbacks:[]}')"
  stream="$(jq -nc --arg p "$path" '{network:"ws", security:"none", wsSettings:{path:$p, headers:{}}}')"
  ib="$(jq -nc --arg port "$port" --arg tag "inbound-${port}" --arg s "$settings" --arg st "$stream" '
    {up:0, down:0, total:0, remark:"xkit-pool", enable:true, expiryTime:0, listen:"127.0.0.1",
     port:($port|tonumber), protocol:"vless", settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"
  api_add_inbound "$ib" || return 1
  local newlist ibid fresh
  newlist="$(api_list)" || return 1
  ibid="$(jq -r --arg t "inbound-${port}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$newlist")"
  [ -n "$ibid" ] || { err "Pool-инбаунд создан, но id не найден"; return 1; }
  fresh="$(api_get_inbound "$ibid")" || true
  if [ "$API_V3" = "1" ]; then
    # v3: externalProxy заменён host-группами; pool за nginx = tls на 443
    v3_host_upsert "$ibid" "$XKIT_HOST" 443 "tls" || \
      warn "host-группа pool не создалась (ссылки в панели покажут 127.0.0.1 — пункт 19 пересоздаст)"
  elif [ -n "$fresh" ]; then
    fresh="$(jq -c --arg d "$XKIT_HOST" '.externalProxy = [{"dest":$d,"port":443,"remark":"xkit"}]' <<<"$fresh")"
    api_update_inbound "$ibid" "$fresh" >/dev/null 2>&1 || true
  fi
  # старый pool мог иметь другой id — осиротевший location /xk-ws-<старый>/ удаляем,
  # иначе nginx продолжает проксировать путь в закрытый порт
  if [ -n "${XKIT_POOL_INBOUND:-}" ] && [ "${XKIT_POOL_INBOUND}" != "$ibid" ]; then
    routes_del "${XKIT_POOL_INBOUND}"
    # сирота в ПАНЕЛИ (аудит №3): раньше чистился только маршрут nginx, а старый
    # pool-инбаунд навсегда оставался в панели — теперь удаляем через API
    if api_del_inbound "${XKIT_POOL_INBOUND}" 2>/dev/null; then
      log "Старый pool-инбаунд #${XKIT_POOL_INBOUND} удалён из панели"
    else
      warn "Старый pool-инбаунд #${XKIT_POOL_INBOUND} НЕ удалён из панели — удалите вручную (Панель -> Inbounds)"
    fi
  fi
  routes_upsert "$ibid" local ws "$path" "127.0.0.1:${port}" "inbound-${port}"
  XKIT_POOL_INBOUND="$ibid"; XKIT_POOL_TAG="inbound-${port}"
  save_xkit_env
  if ! regen_conf_and_apply; then
    err "Конфиг nginx НЕ применился после создания pool — путь ${path} не отвечает."
    err "Полуприменённое состояние: повторите (пункт 2 / xkit route) и проверьте nginx -t."
    err "Pool-инбаунд #${ibid} остаётся в панели: при повторе будет заменён автоматически (старый удалится, если id сменится)."
    return 1
  fi
  ok "Pool-инбаунд #$ibid создан: ws ${path} -> 127.0.0.1:${port} (за nginx)"
  return 0
}

# применяет аутбаунды нод + balancer + observatory к шаблону xray на мастере
# чистая функция (тестируемая): $1 текущий шаблон, $2 путь к nodes.json ИЛИ его
# содержимое (совместимость с тестами; V-03: прод-вызов идёт через tmpfile 600),
# $3 pool_tag, $4 стратегия
nodes_merge_template() {
  command -v python3 >/dev/null 2>&1 || { err "python3 не найден — выполните: apt-get install -y python3"; return 1; }
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, json, os
tpl = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
src = sys.argv[2]
# V-03: прод передаёт ПУТЬ к файлу (секреты не в argv); тесты — само содержимое
if os.path.isfile(src):
    # (мелочь №5, аудит v5.2.1): явные with/encoding вместо голого open()
    with open(src, encoding="utf-8") as fh:
        nodes = json.load(fh)
else:
    nodes = json.loads(src)
pool_tag = sys.argv[3]
strategy = sys.argv[4] if sys.argv[4] in ("roundRobin", "random", "leastPing", "leastLoad") else "roundRobin"

outb = tpl.get("outbounds") or []
outb = [o for o in outb if not str(o.get("tag", "")).startswith("node-")]
for n in nodes:
    t = n.get("tunnel") or {}
    outb.append({
        "tag": n.get("outbound_tag") or ("node-" + n.get("name", "")),
        "protocol": "vless",
        "settings": {"vnext": [{"address": n.get("host"), "port": int(t.get("port", 443)),
                                "users": [{"id": t.get("uuid"), "encryption": "none",
                                           "flow": t.get("flow", "xtls-rprx-vision"), "level": 0}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
                           "realitySettings": {"serverName": t.get("sni", ""),
                                               "fingerprint": "chrome",
                                               "publicKey": t.get("pbk", ""),
                                               "shortId": t.get("sid", ""),
                                               "spiderX": ""}},
        "mux": {"enabled": False, "concurrency": -1}})
tpl["outbounds"] = outb

r = tpl.setdefault("routing", {})
rules = r.get("rules") or []
rules = [x for x in rules if x.get("balancerTag") != "XKIT_POOL"]
if pool_tag and nodes:
    rules.insert(0, {"inboundTag": [pool_tag], "balancerTag": "XKIT_POOL"})
r["rules"] = rules

bal = r.get("balancers") or []
bal = [b for b in bal if b.get("tag") != "XKIT_POOL"]
if nodes:
    bal.append({"tag": "XKIT_POOL", "selector": ["node-"], "strategy": {"type": strategy}})
r["balancers"] = bal

tpl.pop("observatory", None)
tpl.pop("burstObservatory", None)
if nodes and strategy == "leastPing":
    tpl["observatory"] = {"subjectSelector": ["node-"],
                          "probeUrl": "https://www.google.com/generate_204",
                          "probeInterval": "1m", "enableConcurrency": True}
if nodes and strategy == "leastLoad":
    tpl["burstObservatory"] = {"subjectSelector": ["node-"],
                               "pingConfig": {"destination": "https://www.google.com/generate_204",
                                              "connectivity": "http://www.google.com/generate_204",
                                              "interval": "1m", "timeout": "5s", "sampling": 2}}
print(json.dumps(tpl, ensure_ascii=False, separators=(",", ":")))
PY
}

nodes_apply_template() {
  local nodes_json; nodes_json="$(nodes_load)"
  local cur merged resp
  if [ "$API_V3" = "1" ]; then
    # v3: xrayTemplateConfig ИЗ settings ВЫВЕДЕН — шаблон живёт в /panel/api/xray
    # (GET-ответ: {.obj.xraySetting:<объект конфига>,...}; запись: POST /update,
    # поле формы xraySetting; панель сама рестартует xray)
    resp="$(api_post_json "panel/api/xray/" "{}")"
    if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      err "panel/api/xray: $(jq -r '.msg // "нет ответа"' <<<"$resp" 2>/dev/null | head -c 200)"
      return 1
    fi
    cur="$(jq -c '.obj.xraySetting // {}' <<<"$resp")"
  else
    local all
    all="$(panel_settings_get)" || return 1
    cur="$(jq -r '.obj.xrayTemplateConfig // "{}"' <<<"$all")"
  fi
  jq -e . <<<"$cur" >/dev/null 2>&1 || cur="{}"
  # V-03 (аудит №2): nodes.json (пароли панелей нод, UUID) — через tmpfile 600,
  # НЕ аргументом в python3 (виден через ps/proc)
  local nodes_file; nodes_file="$(mktemp /tmp/.xkit-nodes.XXXXXX)" || return 1
  chmod 600 "$nodes_file" 2>/dev/null || true
  printf '%s' "$nodes_json" > "$nodes_file"
  local mrc=0
  merged="$(nodes_merge_template "$cur" "$nodes_file" "${XKIT_POOL_TAG:-}" "${XKIT_BAL_STRATEGY:-roundRobin}")" || mrc=$?
  rm -f "$nodes_file"
  [ "$mrc" -eq 0 ] || { err "Не удалось собрать шаблон xray"; return 1; }
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/xray/update" --data-urlencode "xraySetting=${merged}")"
    if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      err "panel/api/xray/update: $(jq -r '.msg // "нет ответа"' <<<"$resp" 2>/dev/null | head -c 200)"
      return 1
    fi
  else
    panel_settings_set "xrayTemplateConfig=${merged}" || return 1
  fi
  xray_restart
  return 0
}

# скан подсети С САМОЙ НОДЫ (кандидаты видны из её сети/гео); результат в RDEST / RSNI
node_reality_scan_pick() { # $1 rec ноды
  local rec="$1" t tlist
  local out="${XKIT_DIR}/reality-scan-node.tsv"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  read -r -p "Что сканируем С НОДЫ? CIDR/список через пробел (Enter = /24 самой ноды) -> " t
  tlist=""
  if [ -n "$t" ]; then
    tlist="$(reality_expand_targets "$t")"
    case "$tlist" in ERR:*) err "$tlist"; return 1 ;; esac
  fi
  log "Сканирую с ноды: TCP :443 (50 потоков) -> TLS-детали..."
  # V-01 (аудит №2): список целей уходит на ноду base64'ом (вне shell-строки);
  # токены уже валидированы в reality_expand_targets — двойной барьер
  local tb64; tb64="$(printf '%s' "$tlist" | base64 -w0)"
  node_ssh "$rec" "TARGETS_B64='${tb64}' bash -s" > "$out" <<'EOS' || true
TARGETS=""
[ -n "${TARGETS_B64:-}" ] && TARGETS="$(printf '%s' "$TARGETS_B64" | base64 -d)"
probe() { timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$1" 2>/dev/null && echo "$1"; }
export -f probe
TMP="$(mktemp)"; OPEN="$(mktemp)"
trap 'rm -f "$TMP" "$OPEN"' EXIT INT TERM   # чистка даже при обрыве SSH-сессии
if [ -n "${TARGETS:-}" ]; then printf '%s\n' "$TARGETS" | grep -v '^$' > "$TMP"; else
  P="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | awk -F. '{print $1"."$2"."$3}')"
  [ -n "$P" ] || { echo "ERR: не удалось определить IP ноды"; exit 1; }
  i=1; while [ "$i" -le 254 ]; do echo "$P.$i"; i=$((i+1)); done > "$TMP"
fi
xargs -a "$TMP" -P 50 -n 1 probe >> "$OPEN" 2>/dev/null || true
while IFS= read -r ip; do
  [ -z "$ip" ] && continue
  brief="$(echo | timeout 6 openssl s_client -brief -connect "${ip}:443" -servername "${ip}" 2>&1)"
  t13=no;  grep -q "TLSv1.3" <<<"$brief" && t13=yes
  h2=no;   grep -qi "ALPN protocol: *h2" <<<"$brief" && h2=yes
  x2=no;   grep -q "X25519" <<<"$brief" && x2=yes
  cert="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>/dev/null \
          | openssl x509 -noout -subject -issuer -ext subjectAltName -enddate 2>/dev/null)"
  cn="$(sed -n 's/^subject=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
  san="$(awk '/^X509v3 Subject Alternative Name:/{getline; sub(/^ +/,""); print; exit}' <<<"$cert" \
         | sed 's/DNS://g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^\*' | head -n1)"
  [ -n "$san" ] || san="$cn"
  issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
  end="$(sed -n 's/^notAfter=//p' <<<"$cert" | head -n1)"
  vrf_out="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>&1)"
  notvalid=yes
  if grep -q 'Verify return code: 0 (ok)' <<<"$vrf_out" \
     || grep -qE 'Verify return code: 0[[:space:]]*$' <<<"$vrf_out"; then
    notvalid=no
  fi
  verdict="НЕТ"
  if [ "$t13" = "yes" ] && [ "$notvalid" = "no" ] && { [ -n "$san" ] || [ -n "$cn" ]; }; then
    verdict="ДА"; [ "$h2" = "yes" ] && [ "$x2" = "yes" ] && verdict="ДА+"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ip" "$t13" "$h2" "$x2" "$notvalid" "${cn:--}" "${san:--}" "${end:--}" "$verdict"
done < "$OPEN"
rm -f "$TMP" "$OPEN"
EOS
  [ -s "$out" ] || { warn "Нода: ни один адрес не ответил на :443 (или SSH-сессия оборвалась)"; return 1; }
  grep -q '^ERR:' "$out" && { err "$(head -n1 "$out")"; return 1; }
  reality_scan_choose "$out"
}
