
# nginx-локейшн дашборда: секретный путь + security-заголовки + Basic Auth
# + опц. allow IP/CIDR. ВНИМАНИЕ: функция пишет В STDOUT конфига — warn/ok тут
# запрещены (ушли бы в файл конфига), невалидные адреса молча пропускаются
# (deny all; остаётся — fail-closed)
generate_dash_block() {
  local dp; dp="$(dash_path)"
  cat <<BLK

    # --- веб-дашборд xkit (секретный путь; данные: ${XKIT_DASH_DIR}) ---
    location = ${dp%/} {
        return 301 ${dp};
    }
    location ^~ ${dp} {
        alias ${XKIT_DASH_DIR}/;
        index index.html;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        access_log off;
BLK
  if [ "${XKIT_DASH_AUTH:-1}" = "1" ] && [ -s "${XKIT_DASH_HTPASSWD}" ]; then
    printf '        auth_basic "xkit-dashboard";\n'
    printf '        auth_basic_user_file %s;\n' "${XKIT_DASH_HTPASSWD}"
  fi
  if [ -n "${XKIT_DASH_ALLOW:-}" ]; then
    local -a _dash_ips=()          # local: не утекает в глобальный scope
    local a
    IFS=',' read -ra _dash_ips <<<"${XKIT_DASH_ALLOW}"
    for a in "${_dash_ips[@]}"; do
      a="${a// /}"; [ -n "$a" ] || continue
      # кривой адрес НЕ печатаем (иначе nginx -t падает и откат блокирует все
      # будущие apply); ручная правка xkit.env больше не ломает nginx
      is_ip "$a" || is_cidr "$a" || continue
      printf '        allow %s;\n' "$a"
    done
    printf '        deny all;\n'
  fi
  printf '    }\n'
}

# HTML-каркас дашборда (статичный; данные подтягивает JS из ./data.json)
dash_write_html() { # stdout: index.html
  cat <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>System</title>
<style>
:root{--bg:#0b1220;--card:#121b2e;--line:#22304d;--tx:#dbe4f5;--mut:#7c8db0;
--ok:#22c55e;--warn:#f59e0b;--bad:#ef4444;--acc:#38bdf8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);
font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;padding:20px}
.wrap{max-width:1180px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px}
h1 .dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:8px;vertical-align:middle}
.sub{color:var(--mut);font-size:12px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:18px}
.grid .card{margin-bottom:0}
.card h3{margin:0 0 10px;font-size:12px;text-transform:uppercase;letter-spacing:.07em;color:var(--mut)}
.kv{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:3px 0;font-size:13px}
.kv b{font-weight:600}
.badge{display:inline-block;padding:1px 9px;border-radius:99px;font-size:12px;font-weight:600}
.ok{color:var(--ok);background:rgba(34,197,94,.12)}
.warn{color:var(--warn);background:rgba(245,158,11,.14)}
.bad{color:var(--bad);background:rgba(239,68,68,.14)}
.mut{color:var(--mut)}
table{width:100%;border-collapse:collapse;font-size:13px}
th{color:var(--mut);text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;
letter-spacing:.05em;padding:6px 8px;border-bottom:1px solid var(--line)}
td{padding:7px 8px;border-bottom:1px solid rgba(34,48,77,.5);white-space:nowrap}
tr:last-child td{border-bottom:none}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{padding:2px 9px;border-radius:7px;font-size:12px;font-weight:600}
.pill.ok{background:rgba(34,197,94,.12)}.pill.warn{background:rgba(245,158,11,.14)}.pill.bad{background:rgba(239,68,68,.16)}
.err{color:var(--bad);padding:12px 14px;border:1px solid rgba(239,68,68,.4);border-radius:10px;margin:0 0 16px}
.solo{color:var(--mut);padding:10px 14px;border:1px dashed var(--line);border-radius:10px;margin:0 0 16px;font-size:13px}
footer{color:var(--mut);font-size:12px;margin-top:8px}
@media(max-width:640px){td,th{white-space:normal}}
</style>
</head>
<body>
<div class="wrap">
<h1><span class="dot" id="dot"></span>XKIT &mdash; дашборд</h1>
<div class="sub" id="hdr">загрузка данных&hellip;</div>
<div class="err" id="err" style="display:none"></div>
<div class="solo" id="solo" style="display:none"></div>
<div class="grid" id="cards"></div>
<div class="card"><h3>Ноды: туннели, каналы, трафик, аренда</h3>
<div style="overflow-x:auto"><table id="nodes"></table></div></div>
<div class="card"><h3>Инбаунды мастер-сервера</h3>
<div style="overflow-x:auto"><table id="inbounds"></table></div></div>
<div class="card"><h3>Топ пользователей по потреблённому трафику</h3>
<div style="overflow-x:auto"><table id="users"></table></div></div>
<footer>XKIT v<span id="ver">?</span> &middot; данные строит cron каждые 5 минут &middot;
страница автообновляется каждые 30 секунд</footer>
</div>
<script>
"use strict";
var D=null;
function $(id){return document.getElementById(id);}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){
  return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function fmtB(b){b=Number(b)||0;var u=["Б","КиБ","МиБ","ГиБ","ТиБ"],i=0;
  while(b>=1024&&i<4){b/=1024;i++;}
  return (i?b.toFixed(1):String(Math.round(b)))+" "+u[i];}
function svcB(s){if(s==="active")return '<span class="badge ok">active</span>';
  if(s==="inactive"||s==="failed")return '<span class="badge bad">'+esc(s)+'</span>';
  return '<span class="badge warn">'+esc(s||"n/a")+'</span>';}
function panB(s){if(s==="ok")return '<span class="badge ok">OK</span>';
  if(s==="down")return '<span class="badge bad">недоступна</span>';
  if(s==="fail")return '<span class="badge bad">ошибка входа</span>';
  return '<span class="badge warn">'+esc(s||"n/a")+'</span>';}
function stB(s){if(s==="ok")return '<span class="badge ok">жив</span>';
  if(s==="down")return '<span class="badge bad">недоступен</span>';
  return '<span class="badge warn">'+esc(s)+'</span>';}
function expChip(d,dl){if(!d)return '<span class="mut">—</span>';
  var cls="ok",t;
  if(dl==null){cls="warn";t="?";}
  else if(dl<0){cls="bad";t="ИСТЁК "+(-dl)+" дн. назад";}
  else if(dl<=7){cls="bad";t=dl+" дн.";}
  else if(dl<=30){cls="warn";t=dl+" дн.";}
  else t=dl+" дн.";
  return '<span class="pill '+cls+'">'+esc(d)+" · "+t+'</span>';}
function keyExp(ms){if(!ms||ms<=0)return '<span class="mut">∞</span>';
  var dd=new Date(ms).toISOString().slice(0,10);
  var dl=Math.ceil((ms-Date.now())/86400000);
  return expChip(dd,dl);}
function render(){
  if(!D)return;
  $("ver").textContent=D.version||"?";
  $("hdr").textContent=D.host+" · построено: "+(D.generated_str||"?")+" · обновление данных: каждые 5 минут"
    +((D.stale)?" · данные панели устарели (панель была недоступна при построении)":"");
  var solo=$("solo");
  if(D.mode==="solo"){solo.style.display="block";
    solo.innerHTML="Одиночный режим: ноды не подключены — пустая таблица ниже это норма. Добавить ноды: <b>xkit nodes</b> (пункт меню 17)";}
  else{solo.style.display="none";}
  var dot=$("dot");
  dot.style.background=(D.panel==="ok")?"var(--ok)":"var(--bad)";
  var m=D.master||{};
  var cards="";
  cards+='<div class="card"><h3>'+(D.mode==="solo"?"Этот сервер":"Этот сервер (мастер)")+'</h3>'
    +'<div class="kv"><span>nginx</span>'+svcB(m.nginx)+'</div>'
    +'<div class="kv"><span>3X-UI (панель)</span>'+svcB(m.xui)+'</div>'
    +'<div class="kv"><span>API панели</span>'+panB(D.panel)+'</div>'
    +'<div class="kv"><span>Uptime</span><b>'+(m.uptime_days!=null?m.uptime_days.toFixed(1)+" дн.":"—")+'</b></div>'
    +'<div class="kv"><span>Load (1m)</span><b>'+esc(m.load1!=null?m.load1:"—")+'</b></div>'
    +'<div class="kv"><span>RAM</span><b>'+(m.mem_pct!=null?m.mem_pct+"%":"—")+'</b></div>'
    +'<div class="kv"><span>Диск /</span><b>'+(m.disk_pct!=null?m.disk_pct+"%":"—")+'</b></div>'
    +'<div class="kv"><span>Сертификат до</span><b>'+esc(m.cert_end||"—")+'</b></div>'
    +'</div>';
  var t=D.totals||{};
  cards+='<div class="card"><h3>Трафик мастера (суммарно)</h3>'
    +'<div class="kv"><span>↑ отдано</span><b>'+fmtB(t.up)+'</b></div>'
    +'<div class="kv"><span>↓ принято</span><b>'+fmtB(t.down)+'</b></div>'
    +'<div class="kv"><span>Σ всего</span><b>'+fmtB(t.total)+'</b></div>'
    +'<div class="kv"><span>Балансировка нод</span><b>'+esc(D.strategy||"—")+'</b></div>'
    +'</div>';
  var em=D.expiry_master;
  cards+='<div class="card"><h3>Аренда: мастер</h3>'
    +(em&&em.date
      ?'<div class="kv"><span>действует до</span>'+expChip(em.date,em.days_left)+'</div>'
         +(em.note?'<div class="kv"><span>заметка</span><b>'+esc(em.note)+'</b></div>':'')
      :'<div class="mut">Срок не задан.<br><br>Задать: <b>xkit expiry set master ГГГГ-ММ-ДД</b><br>или пункт меню «Сроки аренды»</div>')
    +'</div>';
  $("cards").innerHTML=cards;

  var ns=D.nodes||[],h="";
  h+='<tr><th>Нода</th><th>Хост</th><th>Туннель</th><th>Отклик</th><th>Панель</th>'
    +'<th class="num">↑</th><th class="num">↓</th><th class="num">Σ</th><th>Аренда</th></tr>';
  if(!ns.length)h+='<tr><td colspan="9" class="mut">Нод нет</td></tr>';
  for(var i=0;i<ns.length;i++){var n=ns[i];
    h+='<tr><td><b>'+esc(n.name)+'</b>'+(n.note?' <span class="mut">('+esc(n.note)+')</span>':'')+'</td>'
      +'<td>'+esc(n.host)+'</td>'
      +'<td>:'+esc(n.tunnel_port)+' '+stB(n.status)+'</td>'
      +'<td>'+(n.latency_ms!=null?n.latency_ms+" мс":"—")+'</td>'
      +'<td>'+panB(n.panel)+'</td>'
      +'<td class="num">'+fmtB(n.up)+'</td><td class="num">'+fmtB(n.down)+'</td><td class="num">'+fmtB(n.total)+'</td>'
      +'<td>'+expChip(n.expiry,n.days_left)+'</td></tr>';
  }
  $("nodes").innerHTML=h;

  var ib=D.inbounds||[],h2="";
  h2+='<tr><th>Инбаунд</th><th class="num">Порт</th><th>Протокол</th><th>Статус</th>'
    +'<th class="num">Клиентов</th><th class="num">↑</th><th class="num">↓</th><th class="num">Σ</th></tr>';
  if(!ib.length)h2+='<tr><td colspan="8" class="mut">Нет данных (панель недоступна или инбаундов нет)</td></tr>';
  for(var j=0;j<ib.length;j++){var b=ib[j];
    h2+='<tr><td>'+esc(b.tag)+'</td><td class="num">'+esc(b.port)+'</td><td>'+esc(b.proto)+'</td>'
      +(b.enable?'<td><span class="badge ok">вкл</span></td>':'<td><span class="badge warn">выкл</span></td>')
      +'<td class="num">'+esc(b.clients)+'</td>'
      +'<td class="num">'+fmtB(b.up)+'</td><td class="num">'+fmtB(b.down)+'</td><td class="num">'+fmtB(b.total)+'</td></tr>';
  }
  $("inbounds").innerHTML=h2;

  var us=D.users||[],h3="";
  h3+='<tr><th>Пользователь</th><th>Инбаунд</th><th class="num">↑</th><th class="num">↓</th>'
    +'<th class="num">Σ</th><th>Срок ключа</th></tr>';
  if(!us.length)h3+='<tr><td colspan="6" class="mut">Нет данных</td></tr>';
  for(var k=0;k<us.length;k++){var u=us[k];
    h3+='<tr><td>'+esc(u.email)+'</td><td class="mut">'+esc(u.ib)+'</td>'
      +'<td class="num">'+fmtB(u.up)+'</td><td class="num">'+fmtB(u.down)+'</td>'
      +'<td class="num"><b>'+fmtB(u.total)+'</b></td>'
      +'<td>'+keyExp(u.expiryTime)+'</td></tr>';
  }
  $("users").innerHTML=h3;
}
function load(){
  fetch("./data.json?ts="+Date.now(),{cache:"no-store"})
    .then(function(r){if(!r.ok)throw new Error("HTTP "+r.status);return r.json();})
    .then(function(j){D=j;$("err").style.display="none";render();})
    .catch(function(e){
      $("err").textContent="Не удалось прочитать data.json ("+e.message+
        "). Данные строит cron каждые 5 минут, либо выполните на сервере: xkit dash gen";
      $("err").style.display="block";
      $("dot").style.background="var(--bad)";
    });
}
load();
setInterval(load,30000);
</script>
</body>
</html>
HTML
}

dash_install() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "${XKIT_HOST:-}" ] || die "Сначала установка (пункт 1)"

  echo ""
  echo -e "${YELLOW}=== ВЕБ-ДАШБОРД: статусы нод, каналы, трафик, сроки аренды ===${NC}"
  echo "Секретная страница рядом с панелью: https://${XKIT_HOST}/d-<токен>/"
  echo "(без токена — обычный 404, как у панели; сверх токена — Basic Auth; access_log выключен)"

  if [ -z "${XKIT_DASH_TOKEN:-}" ]; then
    XKIT_DASH_TOKEN="$(rand_str 24)"
  fi
  # Basic Auth — как у панели: случайные логин/пароль (хранятся в xkit.env, 600)
  XKIT_DASH_AUTH="1"
  if [ -z "${XKIT_DASH_USER:-}" ] || [ -z "${XKIT_DASH_PASS:-}" ]; then
    XKIT_DASH_USER="$(dash_user_gen)"
    XKIT_DASH_PASS="$(rand_str 20)"
  fi
  dash_htpasswd_write || { err "Не удалось создать htpasswd для дашборда"; return 1; }
  local allow a ok_all _al _ka
  if [ -n "${XKIT_DASH_ALLOW:-}" ]; then
    log "Текущее ограничение IP: ${XKIT_DASH_ALLOW}"
    read -r -p "Оставить ограничение IP как есть? [Y/n]: " _ka
    [[ "$_ka" =~ ^[Nn] ]] && XKIT_DASH_ALLOW=""
  fi
  if [ -z "${XKIT_DASH_ALLOW:-}" ]; then
    read -r -p "Ограничить доступ по IP/CIDR (несколько — через запятую; Enter — доступ с любого): " allow
    if [ -n "$allow" ]; then
      ok_all=1
      IFS=',' read -ra _al <<<"$allow"
      for a in "${_al[@]}"; do
        a="${a// /}"; [ -n "$a" ] || continue
        is_ip "$a" || is_cidr "$a" || { err "Не похоже на IP/CIDR: $a"; ok_all=0; }
      done
      [ "$ok_all" = "1" ] || return 1
      XKIT_DASH_ALLOW="$allow"
    else
      XKIT_DASH_ALLOW=""
    fi
  fi
  XKIT_DASH="1"
  save_xkit_env

  local mexp mexd
  mexp="$(expiry_get master -)"
  if [ -z "$mexp" ]; then
    read -r -p "Срок аренды ЭТОГО сервера (YYYY-MM-DD, Enter — пропустить): " mexd
    [ -n "$mexd" ] && expiry_set master "-" "$mexd" ""
  fi

  log "Пересобираю конфиг nginx (секретный location дашборда)..."
  regen_conf_and_apply || { err "Не удалось применить конфиг nginx — дашборд НЕ установлен"; XKIT_DASH="0"; save_xkit_env; return 1; }
  dash_cron_install
  log "Первое построение данных..."
  dash_gen || warn "Первое построение не удалось — cron повторит через 5 минут"

  echo ""
  ok "Дашборд установлен: https://${XKIT_HOST}$(dash_path)"
  ok "Логин: ${XKIT_DASH_USER}   Пароль: ${XKIT_DASH_PASS}   (Basic Auth; ротация: xkit dash rotate)"
  [ -n "${XKIT_DASH_ALLOW:-}" ] && ok "Доступ ограничен IP/CIDR: ${XKIT_DASH_ALLOW}"
  ok "Данные: cron каждые 5 минут; на странице автообновление каждые 30 сек"
  ok "Реквизиты также в ${XKIT_INFO_FILE} и ${XKIT_ENV} (chmod 600)"
  warn "Ссылку потеряли: xkit dash url. Выключить: xkit dash uninstall"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

dash_uninstall() {
  require_root
  load_xkit_env 2>/dev/null || true
  XKIT_DASH="0"
  save_xkit_env >/dev/null 2>&1 || true
  rm -f "$XKIT_CRON_DASH"
  if [ -f "$XKIT_CONF" ]; then
    log "Убираю location дашборда из nginx..."
    regen_conf_and_apply >/dev/null 2>&1 || warn "Не удалось пересобрать конфиг nginx — проверьте вручную"
  fi
  ok "Дашборд выключен (nginx + cron); файлы в ${XKIT_DASH_DIR} сохранены"
  ok "Логин/пароль дашборда сохранены в ${XKIT_ENV} — повторный install их не меняет (сменить: xkit dash rotate)"
  ok "Сроки аренды (expiry) не тронуты — вернуть дашборд: xkit dash install"
  return 0
}

# ротация секрета дашборда: новый токен URL + новый логин/пароль Basic Auth
# (если токен/пароль засветились — не надо переустанавливать дашборд целиком)
dash_rotate() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ] \
    || die "Дашборд не установлен (xkit dash install)"
  local old_token="${XKIT_DASH_TOKEN}" old_user="${XKIT_DASH_USER}" old_pass="${XKIT_DASH_PASS}"
  log "Старый URL (перестанет работать): https://${XKIT_HOST}$(dash_path)"
  # бэкап htpasswd: откат — КОПИРОВАНИЕМ, а не пересчётом openssl (аудит №6:
  # пересчёт мог упасть и оставить новый пароль в htpasswd при старом env)
  local htbk; htbk="$(mktemp /tmp/.xkit-htbk.XXXXXX 2>/dev/null)" || htbk=""
  if [ -n "$htbk" ]; then
    # (мелочь №4, аудит v5.2.1): cp не удался — подчищаем созданный mktemp-файл
    if cp -f "$XKIT_DASH_HTPASSWD" "$htbk" 2>/dev/null; then :; else rm -f "$htbk"; htbk=""; fi
  fi
  if [ -z "$htbk" ]; then
    # №4 (аудит №1): без бэкапа откат невозможен — рассинхрон «nginx требует
    # новый пароль, env — старый». Честно отменяем ДО генерации новых значений
    err "Не удалось создать бэкап htpasswd — ротация отменена, ничего не изменено"
    return 1
  fi
  XKIT_DASH_TOKEN="$(rand_str 24)"
  XKIT_DASH_USER="$(dash_user_gen)"
  XKIT_DASH_PASS="$(rand_str 20)"
  # htpasswd перезаписывается НОВЫМ паролем — при сбое apply откатим и его
  if ! dash_htpasswd_write; then
    err "Не удалось записать htpasswd"
    XKIT_DASH_TOKEN="$old_token"; XKIT_DASH_USER="$old_user"; XKIT_DASH_PASS="$old_pass"
    [ -n "$htbk" ] && rm -f "$htbk"
    return 1
  fi
  # ВАЖНО (аудит №4): env на диск — только ПОСЛЕ успешного apply. Иначе при
  # падении regen_conf_and_apply nginx откатится на старый путь, а в xkit.env
  # остался бы новый токен: «ротация прошла», а URL отдаёт 404 (рассинхрон)
  if ! regen_conf_and_apply; then
    XKIT_DASH_TOKEN="$old_token"; XKIT_DASH_USER="$old_user"; XKIT_DASH_PASS="$old_pass"
    if [ -n "$htbk" ] && [ -f "$htbk" ]; then
      if cp -f "$htbk" "$XKIT_DASH_HTPASSWD"; then
        chown root:www-data "$XKIT_DASH_HTPASSWD" 2>/dev/null || true
        chmod 640 "$XKIT_DASH_HTPASSWD" 2>/dev/null || true
      else
        err "ВНИМАНИЕ: старый htpasswd не восстановлен — выполните xkit dash rotate повторно"
      fi
      rm -f "$htbk"
    else
      dash_htpasswd_write 2>/dev/null || err "ВНИМАНИЕ: вернуть старый htpasswd не удалось — выполните xkit dash rotate повторно"
    fi
    err "Не удалось применить конфиг nginx — ротация ОТМЕНЕНА (старые реквизиты действуют)"
    return 1
  fi
  [ -n "$htbk" ] && rm -f "$htbk" 2>/dev/null
  # аудит №13: apply уже прошёл — при сбое записи env новые реквизиты остались
  # бы только в этом выводе; кричим об этом явно
  save_xkit_env || err "Не удалось сохранить xkit.env — НОВЫЕ реквизиты напечатаны выше, запишите их вручную"
  echo ""
  ok "Дашборд ротирован: https://${XKIT_HOST}$(dash_path)"
  ok "Новый логин: ${XKIT_DASH_USER}   Пароль: ${XKIT_DASH_PASS}"
  warn "Старая ссылка и старый пароль больше не работают"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

dash_url() {
  load_xkit_env 2>/dev/null || return 1
  [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ] \
    || { err "Дашборд не установлен (xkit dash install)"; return 1; }
  printf 'https://%s%s\n' "${XKIT_HOST}" "$(dash_path)"
  [ -n "${XKIT_DASH_USER:-}" ] \
    && printf 'Логин: %s   Пароль: %s\n' "${XKIT_DASH_USER}" "${XKIT_DASH_PASS}"
  return 0
}

dash_menu() {
  require_root
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== ВЕБ-ДАШБОРД (статусы нод / каналы / трафик / сроки аренды) ===${NC}"
    if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
      ok "Установлен: https://${XKIT_HOST:-?}$(dash_path)"
      [ -n "${XKIT_DASH_ALLOW:-}" ] && log "Доступ ограничен IP: ${XKIT_DASH_ALLOW}"
    else
      warn "Не установлен"
    fi
    echo " 1) Установить / переустановить (nginx-локейшн + cron + первое построение)"
    echo " 2) Построить данные сейчас (xkit dash gen)"
    echo " 3) Показать URL"
    echo " 4) Ротация: новый токен URL + логин/пароль (xkit dash rotate)"
    echo " 5) Выключить (убрать из nginx и cron; данные и сроки аренды остаются)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) dash_install; pause_enter ;;
      2) dash_gen; pause_enter ;;
      3) dash_url; pause_enter ;;
      4) dash_rotate; pause_enter ;;
      5) dash_uninstall; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}
