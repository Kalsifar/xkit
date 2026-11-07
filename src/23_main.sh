
usage() {
  cat <<EOF
XKIT v${XKIT_VERSION} — nginx(TLS 443) + 3X-UI одним шагом, меню как у родного x-ui

Использование:
  xkit                 — полноэкранный TUI (при наличии; иначе классическое меню)
  xkit --classic       — классическое Bash-меню (6 групп с подменю)
  xkit protocols       — REALITY/XHTTP/AmneziaWG/Hysteria 2
  xkit protocols list [--json] — санитизированная сводка профилей
  xkit snapshot        — JSON состояния для TUI (без секретов)
  xkit install         — установка одним шагом (при уже установленном — меню:
                         обновить / переустановить чисто / починить поверх)
  xkit reinstall       — ЧИСТАЯ переустановка: бэкап -> полное удаление -> установка
  xkit uninstall [--full] — удалить xkit (бэкап делается ОБЯЗАТЕЛЬНО;
                         --full = вместе с 3X-UI и /etc/nginx/ssl)
  xkit route [--yes]   — автопроброс всех инбаундов за nginx (без вопросов: --yes)
  xkit sub [-q]        — перегенерировать подписки и показать URL (-q тихо, для cron)
  xkit client add|del|list|reset — управление пользователями
  xkit reality          — Reality: создать inbound (wizard)
  xkit nodes            — меню нод (добавить/список/health/стратегия/удалить)
  xkit nodes repair     — переприменить конфигурацию нод (после сбоя apply)
  xkit nodes repin [имя|all] — перепинить сертификат панели ноды (MITM-защита)
  xkit nodes metrics    — обновить трафик, скорость, ping и системные CPU/RAM нод
  xkit extfix           — externalProxy + подписки панели (корректные ссылки в UI)
  xkit health          — проверка жизнеспособности
  xkit backup          — бэкап сейчас (БД панели + конфиг + серты + подписки)
  xkit restore [файл]  — восстановить (по умолчанию из последнего)
  xkit status          — сервисы, порты, что светится наружу
  xkit dash [install|gen|url|rotate|uninstall] — веб-дашборд (статусы/трафик/аренда;
                         rotate — новый токен URL + новый логин/пароль)
  xkit expiry set <master|имя_ноды> ГГГГ-ММ-ДД [заметка]
  xkit expiry list|check|del <master|имя_ноды> — сроки аренды серверов
  xkit telegram [setup|check|test|off] — Telegram-алерты: настроить,
                         проверить сейчас (как cron), тест, выключить.
                         Доставка напрямую, при неудаче — через ноды (их IP)
  xkit info            — сводка в терминал (пароли маскируются) + полная в ${XKIT_INFO_FILE}
  xkit update [URL]    — обновить xkit из репозитория (SHA-256 + бэкап; URL = .../main)
  xkit help            — эта справка

Неинтерактивный режим (CI/cloud-init): XKIT_YES=1 (согласие на вопросы) и
  XKIT_FORCE=1 (установка поверх существующей без меню).
  install.sh пробрасывает: bash install.sh -y | --yes | --force

Файлы:
  $XKIT_ENV    — состояние (адрес, серты, токен подписок)
  $XKIT_ROUTES — таблица маршрутов (id/mode/net/path/target)
  $XKIT_NODES  — реестр нод (туннели, панель ноды, стратегия)
  $XKIT_CONF   — конфиг nginx (генерируется xkit, не правьте руками)
  $SUBS_DIR    — файлы подписок (base64, раздаются nginx по /s-<token>/)
  $XKIT_EXPIRY — сроки аренды серверов (мастер + ноды)
  $XKIT_DASH_DIR — веб-дашборд (index.html + data.json)
  $XKIT_INFO_FILE — сводка-реквизиты (обновляется после установки и операций)
EOF
}

main() {
  case "${1:-menu}" in
    menu|"") if xkit_tui_run; then exit 0; fi; xkit_load_menu || exit 1; menu_loop ;;
    --classic|classic) xkit_load_menu || exit 1; menu_loop ;;
    protocols|proto) shift; require_root; xkit_protocols_load || exit 1; protocols_main "$@" ;;
    snapshot) xkit_snapshot ;;
    install) require_root; one_step_install ;;
    reinstall) require_root; xkit_reinstall ;;
    uninstall) shift; require_root; xkit_uninstall "${1:-}" ;;
    route)   shift; [ "${1:-}" = "--yes" ] && export XKIT_YES=1; require_root; auto_route ;;
    sub)     shift; [ "${1:-}" = "-q" ] && export SUB_QUIET=1; require_root; sub_regen ;;
    client)  shift; require_root
             case "${1:-list}" in
               add) client_add ;; del) client_del ;; list) client_list ;; reset) client_reset ;;
               *) err "xkit client add|del|list|reset"; exit 1 ;;
             esac ;;
    reality) require_root; load_xkit_env || true; reality_wizard ;;
    nodes)   shift; require_root
             case "${1:-menu}" in
               repair) nodes_repair ;;
               repin)  shift; node_repin "${1:-all}" ;;
               metrics) nodes_metrics_collect >/dev/null && ok "Метрики нод обновлены: $XKIT_NODES_METRICS" ;;
               *) nodes_menu ;;
             esac ;;
    extfix)  require_root; external_proxy_fix ;;
    health)  health_check ;;
    backup)  require_root; backup_now ;;
    restore) shift; require_root; backup_restore "${1:-}" ;;
    status)  show_status ;;
    dash)    shift; require_root
             case "${1:-menu}" in
               install|on) dash_install ;;
               uninstall|off) dash_uninstall ;;
               gen|build) dash_gen ;;
               url) dash_url ;;
               rotate|rekey) dash_rotate ;;
               *) dash_menu ;;
             esac ;;
    expiry)  shift; require_root
             case "${1:-menu}" in
               set) shift; expiry_cli_set "$@" ;;
               del|rm) shift; expiry_cli_del "$@" ;;
               list) expiry_list ;;
               check) expiry_check ;;
               *) expiry_menu ;;
             esac ;;
    telegram) shift; require_root
             case "${1:-menu}" in
               setup) telegram_setup ;;
               check) load_xkit_env >/dev/null 2>&1 || true; notify_check ;;
               test)  load_xkit_env >/dev/null 2>&1 || true
                      if xkit_tg_send "[XKIT] тест: канал доставки работает"; then ok "Доставлено"; else err "Не доставлено (напрямую и через ноды)"; exit 1; fi ;;
               off)   telegram_off ;;
               *)     telegram_menu ;;
             esac ;;
    update)  shift; xkit_self_update "${1:-}" ;;
    info)    require_root; xkit_info ;;
    help|-h|--help) usage ;;
    *) err "Неизвестная команда: $1 (xkit help)"; exit 1 ;;
  esac
}

# при прямом запуске — main; при source (тесты) — только определения
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
