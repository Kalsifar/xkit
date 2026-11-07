
#=========================== СВОДКА (реквизиты) ================================
# После установки/операций — всё важное в /root/xkit-info.txt (chmod 600).
# ПАРОЛИ по умолчанию МАСКИРОВАНЫ в stdout (аудит №4): терминальный scrollback,
# tee/script/CI-логи не должны собирать секреты. Полные — только в файл 600
# (xkit_summary_save/xkit_info пишут его через --show-secrets).
xkit_summary_text() { # stdout: plain-текст без цветов
  local show_secrets=0
  [ "${1:-}" = "--show-secrets" ] && show_secrets=1
  load_xkit_env 2>/dev/null || true
  read_panel_settings >/dev/null 2>&1 || true
  local -a L=()
  L+=("XKIT v${XKIT_VERSION} — сводка сервера")
  L+=("Обновлено: $(date '+%Y-%m-%d %H:%M:%S %Z')")
  L+=("================================================================")
  if [ -n "${XKIT_HOST:-}" ]; then
    L+=("Сервер:            ${XKIT_HOST}")
    # v4.5: явный режим сервера
    local nc; nc="$(jq 'length' <<<"$(nodes_load 2>/dev/null || printf '[]')" 2>/dev/null || echo 0)"
    if [ "$nc" -gt 0 ]; then
      L+=("Режим:             мастер (${nc} нод; балансировка ${XKIT_BAL_STRATEGY:-roundRobin})")
    else
      L+=("Режим:             одиночный сервер (ноды не подключены)")
    fi
    [ -n "${PANEL_PORT:-}" ] && [ -n "${PANEL_WBP:-}" ] \
      && L+=("Панель 3X-UI:      https://${XKIT_HOST}${PANEL_WBP}")
    [ -n "${PANEL_USER:-}" ] && L+=("Логин панели:      ${PANEL_USER}")
    if [ -n "${PANEL_PASS:-}" ]; then
      if [ "$show_secrets" = "1" ]; then
        L+=("Пароль панели:     ${PANEL_PASS}")
      else
        L+=("Пароль панели:     ********  (полные реквизиты: cat ${XKIT_INFO_FILE})")
      fi
    fi
    [ -n "${XKIT_SUB_TOKEN:-}" ] && L+=("Подписки xkit:     https://${XKIT_HOST}$(sub_path)")
    if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
      L+=("Веб-дашборд:       https://${XKIT_HOST}$(dash_path)")
      [ -n "${XKIT_DASH_USER:-}" ] && L+=("Логин дашборда:    ${XKIT_DASH_USER}")
      if [ -n "${XKIT_DASH_PASS:-}" ]; then
        if [ "$show_secrets" = "1" ]; then
          L+=("Пароль дашборда:   ${XKIT_DASH_PASS}")
        else
          L+=("Пароль дашборда:   ********  (полные реквизиты: cat ${XKIT_INFO_FILE})")
        fi
      fi
      [ -n "${XKIT_DASH_ALLOW:-}" ] && L+=("Дашборд: allow IP: ${XKIT_DASH_ALLOW}")
    fi
    # v4.5: состояние Telegram-алертов (токен не показываем)
    if [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ]; then
      L+=("Telegram алерты:   включены (чат ${XKIT_TG_CHAT})")
    else
      L+=("Telegram алерты:   не настроены (xkit telegram setup)")
    fi
  else
    L+=("(xkit ещё не установлен — запустите: xkit install)")
  fi
  # ноды
  local arr; arr="$(nodes_load 2>/dev/null || printf '[]')"
  if [ "$(jq 'length' <<<"${arr:-[]}" 2>/dev/null || echo 0)" -gt 0 ]; then
    L+=("")
    L+=("Ноды:")
    local nr
    while IFS= read -r nr; do
      [ -z "$nr" ] && continue
      L+=("  - $(jq -r '.name' <<<"$nr"): $(jq -r '.host' <<<"$nr"), туннель :$(jq -r '.tunnel.port // 443' <<<"$nr"), панель :$(jq -r '.panel.port // "?"' <<<"$nr")")
    done < <(jq -c '.[]' <<<"$arr")
  fi
  # сроки аренды
  if [ -s "$XKIT_EXPIRY" ]; then
    L+=("")
    L+=("Сроки аренды:")
    local es ei ed enote edl
    while IFS=$'\t' read -r es ei ed enote; do
      [ -z "$es" ] && continue
      edl="$(days_left "$ed")"
      L+=("  - ${es}/${ei}: до ${ed}${edl:+, осталось ${edl} дн.}${enote:+ (${enote})}")
    done < "$XKIT_EXPIRY"
  fi
  L+=("")
  L+=("Файлы: ${XKIT_ENV} | ${XKIT_CONF}")
  L+=("Меню: команда xkit | Эта сводка: xkit info")
  printf '%s\n' "${L[@]}"
}

xkit_info() { # в терминал (пароли маскируются) И в /root/xkit-info.txt (полные)
  local txt tfull
  txt="$(xkit_summary_text)" || return 1
  tfull="$(xkit_summary_text --show-secrets)" || return 1
  printf '%s\n' "$txt"
  log "Пароли не печатаются в терминал (scrollback/логи) — полные реквизиты: cat ${XKIT_INFO_FILE}"
  if printf '%s\n' "$tfull" > "$XKIT_INFO_FILE" 2>/dev/null && chmod 600 "$XKIT_INFO_FILE" 2>/dev/null; then
    ok "Сводка сохранена: ${XKIT_INFO_FILE} (chmod 600)"
  else
    warn "Не удалось записать ${XKIT_INFO_FILE}"
  fi
  return 0
}

xkit_summary_save() { # тихо: только файл (вызывается после операций)
  local txt
  txt="$(xkit_summary_text --show-secrets)" || return 1
  if printf '%s\n' "$txt" > "$XKIT_INFO_FILE" 2>/dev/null && chmod 600 "$XKIT_INFO_FILE" 2>/dev/null; then
    ok "Сводка обновлена: ${XKIT_INFO_FILE}"
  else
    warn "Не удалось обновить ${XKIT_INFO_FILE}"
  fi
  return 0
}
