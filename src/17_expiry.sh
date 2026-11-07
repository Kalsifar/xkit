
#=========================== v4.1: ПОЛЬЗОВАТЕЛЬ — СБРОС ТРАФИКА ===============
client_reset() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  list_inbounds_menu || return 1
  local ib="$PICK_IB" id
  id="$(jq -r '.id' <<<"$ib")"
  local -a cls=()
  mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
  [ "${#cls[@]}" -gt 0 ] || { warn "В инбаунде нет клиентов"; return 0; }
  echo ""
  local i=0 cl
  for cl in "${cls[@]}"; do
    i=$((i+1))
    printf '%-3s %s\n' "$i" "$(jq -r '.email // "-"' <<<"$cl" | cut -c1-40)"
  done
  read -r -p "Номер пользователя [1-$i] (Enter — отмена): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "Отменено"; return 0; }
  [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { warn "Отменено"; return 0; }
  cl="${cls[$((n-1))]}"
  local email
  email="$(jq -r '.email // empty' <<<"$cl" | tr -dc 'A-Za-z0-9._@-')"
  [ -n "$email" ] || { err "У клиента нет email"; return 1; }
  read -r -p "Сбросить трафик '$email'? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  local resp
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/clients/resetTraffic/${email}")"
  else
    resp="$(api_post_raw "panel/api/inbounds/${id}/resetClientTraffic/${email}")"
  fi
  if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    ok "Трафик '$email' сброшен"
  else
    err "Не удалось сбросить: $(jq -r '.msg // "?"' <<<"$resp" 2>/dev/null | head -c 200)"
  fi
  return 0
}

#=========================== v4.1: SSH-ВХОД ===================================
# Авто-меню при входе по SSH: /root/.bashrc вызывает xkit для интерактивных сессий
ssh_hook_toggle() {
  require_root
  if [ -f "$0" ]; then
    cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN" \
      && ok "Команда xkit установлена/обновлена: $XKIT_BIN"
  fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  if grep -q "# >>> xkit-menu >>>" /root/.bashrc 2>/dev/null; then
    sed -i '/# >>> xkit-menu >>>/,/# <<< xkit-menu <<</d' /root/.bashrc
    ok "Авто-меню при входе по SSH ВЫКЛЮЧЕНО (запускайте xkit вручную)"
  else
    cat >> /root/.bashrc <<'EOF'

# >>> xkit-menu >>>
if [[ $- == *i* && -t 0 && -t 1 && -z "$XKIT_NOMENU" ]] && command -v xkit >/dev/null 2>&1; then
  xkit || true
fi
# <<< xkit-menu <<<
EOF
    ok "Авто-меню при входе по SSH ВКЛЮЧЕНО (выйти в шелл: 0 в меню)"
    warn "Отключить: этот же пункт, либо задать XKIT_NOMENU=1"
  fi
  return 0
}

#=========================== СРОКИ АРЕНДЫ СЕРВЕРОВ (v4.3) =====================
# Отдельный сохраняемый параметр: когда заканчивается аренда мастер-сервера
# и каждой ноды. Файл $XKIT_EXPIRY (tab-separated):
#   scope<TAB>id<TAB>date<TAB>note      scope: master | node; id: "-" или имя ноды
days_left() { # $1 YYYY-MM-DD -> целое число дней (может быть <0); пусто если дата кривая
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  local d
  d="$(date -d "$1" +%s 2>/dev/null)" || return 0
  echo $(( (d - $(date +%s)) / 86400 ))
}

expiry_get() { # $1 scope, $2 id -> дата (или пусто)
  [ -r "$XKIT_EXPIRY" ] || return 0
  awk -F'\t' -v s="$1" -v i="$2" '$1==s && $2==i {print $3; exit}' "$XKIT_EXPIRY" 2>/dev/null
}

expiry_note() { # $1 scope, $2 id -> заметка
  [ -r "$XKIT_EXPIRY" ] || return 0
  awk -F'\t' -v s="$1" -v i="$2" '$1==s && $2==i {print $4; exit}' "$XKIT_EXPIRY" 2>/dev/null
}

expiry_set() { # $1 scope, $2 id, $3 date, $4 note
  local scope="$1" id="$2" d="$3" note="${4:-}"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Дата в формате YYYY-MM-DD (например 2027-01-15)"; return 1; }
  date -d "$d" +%s >/dev/null 2>&1 || { err "Некорректная дата: $d"; return 1; }
  # заметка не должна ломать tab-separated формат (4-е поле съедает остаток)
  note="${note//$'\t'/ }"; note="${note//$'\r'/ }"; note="${note//$'\n'/ }"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  # flock: параллельные записи (cron dash_gen / CLI) не теряют правки друг друга
  (
    flock -w 5 9 || { err "Файл сроков занят другой операцией — повторите"; exit 1; }
    local tmp; tmp="$(mktemp)"
    [ -f "$XKIT_EXPIRY" ] && awk -F'\t' -v s="$scope" -v i="$id" '!($1==s && $2==i)' "$XKIT_EXPIRY" > "$tmp"
    printf '%s\t%s\t%s\t%s\n' "$scope" "$id" "$d" "$note" >> "$tmp"
    mv -f "$tmp" "$XKIT_EXPIRY"
    chmod 600 "$XKIT_EXPIRY"
    exit 0
  ) 9>"${XKIT_EXPIRY}.lock"
}

expiry_del() { # $1 scope, $2 id
  [ -f "$XKIT_EXPIRY" ] || return 0
  (
    flock -w 5 9 || { err "Файл сроков занят другой операцией — повторите"; exit 1; }
    local tmp; tmp="$(mktemp)"
    awk -F'\t' -v s="$1" -v i="$2" '!($1==s && $2==i)' "$XKIT_EXPIRY" > "$tmp"
    mv -f "$tmp" "$XKIT_EXPIRY"; chmod 600 "$XKIT_EXPIRY"
    exit 0
  ) 9>"${XKIT_EXPIRY}.lock"
}

expiry_list() {
  if [ ! -s "$XKIT_EXPIRY" ]; then
    warn "Записей о сроках аренды нет — задайте: xkit expiry set master ГГГГ-ММ-ДД"
    return 0
  fi
  echo ""
  printf '%-10s %-10s %-12s %-14s %s\n' "ОБЪЕКТ" "ID" "ДО" "ОСТАЛОСЬ" "ЗАМЕТКА"
  echo "--------------------------------------------------------------------"
  local s i d note who dl mark
  while IFS=$'\t' read -r s i d note; do
    [ -z "$s" ] && continue
    who="$i"; [ "$s" = "master" ] && who="мастер"
    dl="$(days_left "$d")"
    if [ -z "$dl" ]; then mark="?"
    elif [ "$dl" -lt 0 ]; then mark="${RED}ПРОСРОЧЕНО${NC}"
    elif [ "$dl" -le 7 ]; then mark="${RED}${dl} дн.${NC}"
    elif [ "$dl" -le 30 ]; then mark="${YELLOW}${dl} дн.${NC}"
    else mark="${GREEN}${dl} дн.${NC}"; fi
    printf '%-10s %-10s %-12s %s %s\n' "$who" "$i" "$d" "$mark" "${note:--}"
  done < "$XKIT_EXPIRY"
  return 0
}

expiry_check() {
  load_xkit_env 2>/dev/null || true
  [ -s "$XKIT_EXPIRY" ] || { ok "Сроки аренды не заданы"; return 0; }
  local s i d note dl bad=0
  while IFS=$'\t' read -r s i d note; do
    [ -z "$s" ] && continue
    dl="$(days_left "$d")"
    [ -z "$dl" ] && continue
    if [ "$dl" -lt 0 ]; then
      err "СРОК АРЕНДЫ ИСТЁК: ${s}/${i} (${d}) — провайдер может отключить сервер в любой момент"
      bad=1
    elif [ "$dl" -le 7 ]; then
      err "Осталось ${dl} дн. аренды: ${s}/${i} (${d})"
      bad=1
    elif [ "$dl" -le 30 ]; then
      warn "Осталось ${dl} дн. аренды: ${s}/${i} (${d})"
    fi
  done < "$XKIT_EXPIRY"
  [ "$bad" -eq 0 ] && ok "Критичных сроков аренды нет"
  return 0
}

expiry_menu_set() {
  echo "Кому задать срок:  1) этот сервер (мастер)   2) нода"
  read -r -p "Выбор [1]: " w; w="${w:-1}"
  local scope id
  if [ "$w" = "2" ]; then
    nodes_list || true
    read -r -p "Имя ноды: " id
    jq -e --arg n "$id" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
      || { err "Нода '$id' не найдена"; return 1; }
    scope="node"
  else
    scope="master"; id="-"
  fi
  local d note
  read -r -p "Дата окончания аренды (YYYY-MM-DD): " d
  read -r -p "Заметка (провайдер/тариф, Enter — нет): " note
  expiry_set "$scope" "$id" "$d" "$note" || return 1
  xkit_summary_save >/dev/null 2>&1 || true
  ok "Сохранено. Текущие сроки:"
  expiry_list
  return 0
}

expiry_menu_del() {
  [ -s "$XKIT_EXPIRY" ] || { warn "Записей нет"; return 0; }
  expiry_list
  read -r -p "Удалить запись для (master или имя ноды, Enter — отмена): " id
  [ -z "$id" ] && return 0
  if [ "$id" = "master" ]; then expiry_del master "-"; else expiry_del node "$id"; fi
  ok "Запись удалена (если была)"
  return 0
}

expiry_menu() {
  require_root
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== СРОКИ АРЕНДЫ СЕРВЕРОВ (мастер + ноды) ===${NC}"
    expiry_list
    echo " 1) Задать/обновить срок"
    echo " 2) Удалить запись"
    echo " 3) Проверка: что скоро истекает"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) expiry_menu_set; pause_enter ;;
      2) expiry_menu_del; pause_enter ;;
      3) expiry_check; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

expiry_cli_set() { # expiry set <master|имя ноды> ГГГГ-ММ-ДД [заметка...]
  load_xkit_env 2>/dev/null || true
  [ $# -ge 2 ] || { err "Использование: xkit expiry set <master|имя_ноды> ГГГГ-ММ-ДД [заметка]"; return 1; }
  local scope="$1" d="$2"; shift 2
  local note="$*" s id="-"
  case "$scope" in
    master|main|server) s="master" ;;
    *)
      jq -e --arg n "$scope" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
        || { err "Нода '$scope' не найдена (для этого сервера укажите: master)"; return 1; }
      s="node"; id="$scope" ;;
  esac
  expiry_set "$s" "$id" "$d" "$note" || return 1
  ok "Срок аренды ${scope}: ${d}"
  xkit_summary_save >/dev/null 2>&1 || true
}

expiry_cli_del() { # expiry del <master|имя ноды>
  [ $# -ge 1 ] || { err "Использование: xkit expiry del <master|имя_ноды>"; return 1; }
  local scope="$1" s id="-"
  case "$scope" in
    master|main|server) s="master" ;;
    *) s="node"; id="$scope" ;;
  esac
  expiry_del "$s" "$id" && ok "Запись '${scope}' удалена (если была)"
}

#=========================== ВЕБ-ДАШБОРД (v4.3) ===============================
# Скрытая страница рядом с панелью: https://ДОМЕН/d-<токен>/
# Показывает: статусы нод и каналов (туннелей), потреблённый трафик
# (инбаунды мастера, ноды, топ пользователей), сроки аренды серверов.
# Данные строит dash_gen (API панели + nodes.json + expiry.tsv) и кладёт
# data.json + index.html в $XKIT_DASH_DIR; nginx раздаёт по секретному пути
# (noindex/no-referrer/no-store, access_log off, опционально allow IP).
# Обновление: cron каждые 5 минут (xkit dash gen) + автообновление JS 30 сек.
