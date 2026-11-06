#!/bin/bash
#==============================================================================
#  XKIT v5.2.0 — TUI + профили доступа для nginx + 3X-UI (Ubuntu 24.04+)
#  Похож на родное меню x-ui: зашёл по SSH — меню само (или наберите `xkit`).
#
#  ГЛАВНОЕ:
#   • установка ОДНИМ ШАГОМ: 3X-UI + nginx + SSL + панель за nginx
#     (панель на 127.0.0.1, порт наружу не светится)
#   • ПУНКТ 2 — сам находит ВСЕ инбаунды через API панели, переводит их
#     на 127.0.0.1 и сам прописывает маршруты в nginx (ws/grpc/xhttp/
#     httpupgrade); Reality/UDP/raw-TCP помечает «direct» и не трогает
#   • пользователи: создать / удалить / список (через API панели)
#   • ПОДПИСКИ: xkit сам формирует ссылки вида https://ДОМЕН:443/путь
#     (а не 127.0.0.1:порт) и раздаёт их по секретному адресу /s-<token>/
#   • проверка жизнеспособности: сервисы, пути, серты, «что светится наружу»
#   • бэкапы: БД панели + конфиг nginx + серты + подписки, авто по cron
#
#  НОВОЕ В v4.1:
#   • НОДЫ: подключение зарубежного сервера прямо из меню по SSH (ставим
#     3X-UI, создаём VLESS+Reality туннель, ufw), реестр нод, аутбаунды на
#     мастере, xray balancer (roundRobin/random/leastPing/leastLoad +
#     observatory): «главный сервер -> туннель до нод с умной балансировкой»
#   • REALITY: свой сайт-прикрытие с сертификатом (dest на свой домен),
#     скан подсети на подходящие dest (TLS1.3/H2/X25519/не self-signed),
#     готовый список проверенных dest, by-IP, показ ключей
#   • externalProxy + нативные подписки 3X-UI через nginx: ссылки и sub URL
#     В САМОЙ панели корректные (https://ДОМЕН:443/...), а не 127.0.0.1
#   • сброс трафика пользователя; авто-меню xkit при входе по SSH (вкл/выкл)
#
#  НОВОЕ В v4.2 (закрытие находок аудита безопасности):
#   • ufw на ноде: публичный IP валидируется (is_ip) и передаётся через env —
#     подмена ответа api.ipify.org больше не даёт RCE на ноде
#   • SSH к нодам: accept-new + постоянный known_hosts (MITM не пройдёт),
#     fingerprint ключа показывается при добавлении; пароль не светится в ps (sshpass -e)
#   • панель ноды: самоподписанный HTTPS — креды панели не ходят по HTTP
#   • фикс: реестр нод сохранялся в несуществующую переменную (KIT_NODES) —
#     ноды не запоминались между запусками
#   • ссылки подписок: path/host/sni URL-энкодятся; локейшн подписок:
#     Referrer-Policy no-referrer + access_log off
#   • скан Reality: цепочка сертификата проверяется openssl (CN==issuer — не критерий)
#   • extfix: Reality/прямые инбаунды не перезаписываются + подтверждение
#   • is_domain: TLD обязан содержать букву; email пользователя санитизируется
#   • `xkit update [URL]` — обновление из репозитория с проверкой SHA-256 и бэкапом
#
#  НОВОЕ В v4.3 (аудит №2: регрессии и дыры + ВЕБ-ДАШБОРД):
#   • КРИТИЧНО: ufw на ноде — все переменные через env (NPORT/TP/NPP), set -u + :?
#     и без глушения вывода. Раньше правила молча падали (quoted-heredoc), а
#     ufw enable с пустыми правилами отрезал SSH/туннель — «bricking» ноды
#   • скан Reality (мастер и нода): ЛЮБОЙ провал проверки цепочки сертификата
#     = кандидат непригоден. Раньше «строки verify нет» трактовалось как «годен»
#   • `xkit update` без аргументов работает из свежей SSH-сессии (читает xkit.env)
#   • nodes_ensure_pool: провал применения конфига = ошибка (не маскируется),
#     старый маршрут pool удаляется из routes.tsv (осиротевший location)
#   • в финале node_add — реальная схема панели ноды ($psch), а не захардкоженный http
#   • mktemp для установщиков 3X-UI (мастер и нода); install.sh: проверка
#     плейсхолдера YOUR_USERNAME + чистка временного каталога (без exec)
#   • v3: дефолтный сайт nginx сносится только ПОСЛЕ успешного reload;
#     бэкап проверяется tar tzf; установщик 3X-UI в mktemp
#   • new_uuid: корректный fallback 8-4-4-4-12; trap-чистка временных файлов скана
#
#  ВЕБ-ДАШБОРД (пункт 23 / xkit dash):
#   • секретная страница рядом с панелью: https://ДОМЕН/d-<токен>/ (noindex,
#     no-referrer, no-store, access_log off, опционально allow IP)
#   • статусы нод и каналов (туннель: TCP-проба + латентность; панель ноды)
#   • потреблённый трафик: инбаунды мастера, по нодам, топ-10 пользователей
#   • СРОКИ АРЕНДЫ серверов отдельным параметром (expiry.tsv): мастер и ноды,
#     дни до конца аренды в CLI (xkit expiry) и на дашборде; cron каждые 5 минут
#
#  НОВОЕ В v4.4 (аудит №3: дыры дашборда/expiry + реквизиты):
#   • КРИТИЧНО: ufw на ноде — если IP мастера не определён, панель ноды
#     ЗАКРЫВАЕТСЯ (ufw deny NPP/tcp), а не остаётся открытой в интернет
#   • КРИТИЧНО: data.json дашборда санитизируется — БЕЗ privateKey Reality,
#     UUID/subId клиентов (раньше утекал полный JSON инбаундов)
#   • Basic Auth на дашборде: случайные логин/пароль (как у панели ноды)
#   • права: /var/lib/xkit и dash-каталог 750 root:www-data, файлы 640
#   • dash_gen: flock в subshell (cron не блокируется открытым меню);
#     при недоступной панели прошлые данные НЕ затираются (stale)
#   • nodes_ensure_pool: early-return только если nginx знает маршрут pool;
#     `xkit nodes repair` — переприменение конфигурации после сбоя apply
#   • пин сертификата панели ноды (sha256, --pinnedpubkey) + `xkit nodes repin`
#   • human_bytes одна (IEC, B/KiB/MiB/GiB/TiB); _dash_ips local + CIDR в allow
#   • expiry: flock при записи, заметка без табов; `xkit dash rotate`
#   • СВОДКА после установки: терминал + /root/xkit-info.txt (chmod 600)
#
#  НОВОЕ В v4.4.1 (аудит №4: хвосты дашборда):
#   • КРИТИЧНО: stale-ветка dash_gen санитизирует данные при ЧТЕНИИ — апгрейд
#     v4.3 (raw data.json с privateKey) + падение панели до первого успешного
#     gen больше не возвращает утечку; плюс финальный sanitize перед записью
#   • трафик нод и totals мастера: total = up+down (потрачено), а не квота .total
#   • dash_rotate: при сбое apply откатываются и env, и htpasswd — старые
#     реквизиты остаются рабочими (рассинхрон URL↔nginx больше не возможен)
#   • пароли по умолчанию НЕ печатаются в stdout (xkit info): маска + подсказка
#     «cat /root/xkit-info.txt»; полные — только в файл 600 (scrollback/tee/logi
#     больше не собирают пароли); после установки реквизиты по-прежнему видны
#   • dash_fix_perms: группа nginx берётся через id -gn (CentOS/кастомные
#     сборки), при неудаче — явный warn; права 750 сразу, без окна 755;
#     файлы пишутся с umask 027 (сразу 640, а не 644 до dash_fix_perms)
#   • node_repin: смена пина требует подтверждения (TOFU: молча принять новый
#     пин после компрометации = легитимизировать MITM); без tty пин не меняется
#
#  НОВОЕ В v4.4.2 (хвост аудита №4 — dash_sanitize_inbounds):
#   • clients считается корректно для ВСЕХ форматов: raw API (клиенты внутри
#     settings-строки), settings-объект, .clients-массив (полу-sanitized),
#     .clients-число (sanitized), null/битое -> 0. Прежний else-вариант молча
#     давал 0 для полу-sanitized-массива; наивный «elif null -> 0» из ревью
#     сломал бы raw (у raw нет поля .clients — детект через .settings)
#   • функция всегда возвращает валидный JSON-массив (пустой вход jq раньше
#     давал пустой вывод с кодом 0 — теперь явный fallback на [])
#   • enable:false больше не теряется: «// true» в jq считает false пустым
#     значением — выключенный инбаунд/пользователь на дашборде показывался
#     как включённый (inbounds, users, whitelist — if enable==null)
#   • комментарий-предохранитель у umask 027 в dash_gen_locked (не выносить
#     из subshell — иначе маска 640 утечёт в интерактивную сессию)
#
#  НОВОЕ В v4.5 (удобство: режимы, pool-симметрия, Telegram):
#   • nodes_del: удаление ПОСЛЕДНЕЙ ноды убирает pool-инбаунд целиком (панель +
#     маршрут + env + перегенерация подписок). Раньше pool оставался, а правило
#     balancer уже исчезало из шаблона xray: ссылки пула продолжали работать,
#     молча меняя выход на IP мастера. Плюс «НОДЫ -> 8) убрать pool» — явный
#     возврат в одиночный режим (pool_remove_force: и из nodes_del, и из меню)
#   • auto_route помечает pool-инбаунд как POOL и не трогает его (раньше
#     отображался как обычный «ЗА nginx»)
#   • конец установки: развилка «1) одиночный / 2) мастер с нодами / 3) позже»
#     вместо одного вопроса про автопроброс (вариант 2 = автопроброс + nodes_menu)
#   • «Режим: одиночный/мастер (N нод)» в xkit info, xkit status, шапке меню
#     и на дашборде (баннер одиночного режима; поле mode в data.json)
#   • TELEGRAM-алерты (xkit telegram setup): только то, чего 3X-UI НЕ знает —
#     ноды упали/восстановились (гистерезис: алерт со 2-й проверки подряд,
#     одно сообщение на восстановление), аренда <=7 дн. и истёкшая (дедуп:
#     алерт при смене числа дней = максимум раз в сутки), сертификат <=14 дн.,
#     дашборд stale (>25 мин без обновления). Бот-команды и уведомления о
#     клиентах НЕ дублируем — это умеет 3X-UI.
#     Доставка: (1) напрямую с мастера, (2) при неудаче — через ноды по SSH
#     (curl на ноде, выход с её IP — решает недоступность api.telegram.org
#     с мастера). Выбор ноды балансировщиком не нужен: сообщение одно и то же,
#     идём по реестру до первой доставки. Токен не попадает в argv: curl
#     читает URL из stdin-конфига (-K -). Cron каждые 10 минут (/etc/cron.d/
#     xkit-notify); состояние алертов — ${XKIT_DIR}/notify.state (chmod 600)
#
#  НОВОЕ В v4.6.0 (аудит №5 + наблюдения эксплуатации):
#   • БЕЗОПАСНОСТЬ: все TCP-пробы /dev/tcp (5 мест) переведены на безопасный
#     bash -c '..."$1"...' _ host port — хост/порт больше не интерполируются в
#     командную строку (инъекция при ручной правке nodes.json); SSH-пользователь
#     ноды валидируется ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$; install-result.env
#     парсится БЕЗ source (sed, аудит №8); /etc/xkit = 0700 ДО ssh-keygen
#   • nodes_health: SSH-провал считается отдельным счётчиком — финал честный
#     («Туннели живы, но SSH недоступен на N нодах»), а не «Все ноды живы»
#   • nodes_ensure_pool: старый pool-инбаунд удаляется ИЗ ПАНЕЛИ (новый
#     api_del_inbound, 3x-ui POST /panel/api/inbounds/del/:id), а не только
#     маршрут nginx — сироты больше не копятся; при сбое apply сообщение
#     говорит, что будет с pool-инбаундом при повторе
#   • sub_regen под flock (аудит №5): cron «13 * * * * xkit sub -q» и ручной
#     запуск не пересекаются — нет окна 404/битого base64; второй процесс
#     non-blocking пропускает
#   • dash_rotate: откат htpasswd — КОПИРОВАНИЕМ из бэкапа (пересчёт openssl мог
#     упасть и оставить новый пароль при старом env, аудит №6); сбой
#     save_xkit_env после успешного apply кричит явно (№13); при сбое записи
#     htpasswd откатываются ВСЕ реквизиты, а не только токен
#   • rand_str: длина гарантирована (запас входа x3 + доводка), SIGPIPE-хрупкость
#     убрана, энтропия base64 сохранена (аудит №9); is_ipv6 -> inet_pton через
#     python3 с фолбэком (№10); nodes_load отбрасывает битый nodes.json
#     ([] + warn в stderr, №11); notify_state_set удаляет ключи awk'ом —
#     симметрично get, ключи с «.» безопасны (№14)
#   • python3 в списке пакетов установки + понятная ошибка в
#     nodes_merge_template/reality_expand_targets (№15); предупреждение, если
#     креды панели не извлечены из install-result.env (№17)
#   • АЛЕРТЫ (telegram check): СЕРВИСЫ мастера (nginx/x-ui упал/восстановился,
#     гистерезис как у нод) и ДИСК (>=85% предупреждение, >=95% тревога,
#     «место освободилось»; дедуп по уровню) — раньше мастер сообщал только о
#     нодах, а переполнение диска молча валило sqlite/certbot/бэкапы
#   • IPv6 (А3): при наличии глобального v6-адреса nginx слушает и [::]:443/80
#     (v6-only клиенты за CGNAT раньше не могли подключиться вовсе);
#     XKIT_V6_LISTEN=0|1|auto — принудительный режим
#   • ревью v4.6.0 (до релиза): IPv6-listen генерировался как «listen [::] 443»
#     БЕЗ двоеточия — nginx -t падал и откатывал ЛЮБОЙ apply_config на серверах
#     с глобальным v6; теперь [::]:443/[::]:80 валидны, «http2 on;» не
#     дублируется; notify_state_set пишет в subshell (umask не утекает при
#     сбоях), xui_env_val парсит awk'ом (ключ с метасимволами безопасен)
#
#  НОВОЕ В v5.2.0 (TUI + протоколы):
#   • отдельный полноэкранный TUI (Go/Bubble Tea), amd64/arm64; стрелки, поиск,
#     живой snapshot, запуск штатных CLI-команд; XKIT_TUI=0 и xkit --classic —
#     прежнее Bash-меню, pipe/cron автоматически используют fallback
#   • xkit protocols: VLESS+REALITY+Vision, новый VLESS+XHTTP+REALITY,
#     AmneziaWG и Hysteria 2 как отдельные systemd-службы; list/status --json
#   • Hysteria 2: официальный release asset + hashes.txt, SHA-256 обязателен;
#     Salamander, клиентская hy2://-ссылка, UFW и безопасные права
#   • AmneziaWG: официальный PPA, отдельные клиентские конфиги 600, стабильный
#     J/S/H-профиль без экспериментальных I1-I5; peer apply с откатом
#   • xkit snapshot — санитизированный JSON для TUI (без ключей и паролей)
#
#  НОВОЕ В v5.1.0 (security-релиз: подтверждённое из аудита №1 + P0/P1 аудита №2):
#   • K-01 КРИТИЧНО: nginx-конфиг собирается ТОЛЬКО из провалидированных значений:
#     is_nginx_path (запрет ~, .., //, *) для путей, строгий parse_hostport
#     ([v6]:port; заодно чинит IPv6-таргеты/F-3), is_port для PANEL_PORT.
#     Невалидное = отказ маршрута, а не «нормализация»
#   • K-02 КРИТИЧНО: supply chain fail-closed — без xkit.sh.sha256 установка
#     (install.sh) и обновление (xkit update/докачка меню) ОТМЕНЯЮТСЯ;
#     осознанный обход: XKIT_ALLOW_UNVERIFIED=1. http://-источники наружу
#     запрещены (localhost-зеркала — можно). Установщик 3X-UI — по тегу
#     последнего релиза (не master) + bash -n скачанного
#   • V-01: TARGETS уходит на ноду base64'ом (вне shell-строки) + валидация
#     токенов в reality_expand_targets
#   • V-02: меню грузится только из доверенных мест (root-владелец, без
#     group/world-write; /tmp, /var/tmp, /dev/shm — чёрный список)
#   • V-03: секреты ушли из argv: логин панели и node_api через --data @-
#     (stdin), nodes.json в python3 через tmpfile 600, openssl passwd -stdin
#   • V-05: SSH TOFU с подтверждением — отпечаток ключа ноды показывается и
#     подтверждается ДО первой отправки пароля (node_ssh_host_key)
#   • V-06: восстановление бэкапа — проверка членов tar, symlink'ов наружу и
#     командных подстановок в xkit.env; чужой архив — только через YES
#   • S-03: порт SSH из sshd -T/sshd_config; не определили — UFW не включаем
#   • v3: mktemp вместо /tmp/.xmesh_nginx_t (V-04); exit_ip/pbk ноды
#     валидируются (S-05/№10); ACTIVE на удалённой ноде -> block (№3);
#     бэкап юнита (№23); symlink-члены tar при restore (№15); подписки
#     750/640 (S-04); пароли панели нод через stdin (V-03); TOFU-подтверждение
#     при установке ключа (V-05); 3X-UI на ноде по тегу (K-02)
#   • дашборд: смешанный формат stale-данных больше не теряет пользователей (№1);
#     ротация отменяется при неудачном бэкапе htpasswd (№4); is_ipv6 без
#     python3 — через getent (№7/N-04)
#   • мелочи: api_del_inbound вместо сырого del/ (№2), валидация TG-токена из
#     env (№9), tonumber в client_list (№12), warn при нестандартном hosts/list
#     (№18), dirname вместо %/* (№19), ранний фолбэк XKIT_REPO_URL (№22),
#     ::ffff:127.0.0.1 в проверке «светится наружу» (№24), честные rc у
#     xkit_menu_fetch/install (F-1/F-2)
#
#  НОВОЕ В v5.0.0 (модульное меню):
#   • МЕНЮ ПЕРЕРАБОТАНО: плоский список из 26 пунктов собран в 6 групп с
#     подменю — 1) Установка и настройка 2) ПОЛЬЗОВАТЕЛИ (создать/удалить/
#     список/сброс трафика/подписки — раньше раскидано по пунктам 3-6 и 20)
#     3) Reality 4) НОДЫ 5) Обслуживание (серт/health/статус/бэкап/обновление)
#     6) Мониторинг (дашборд/Telegram/аренда/SSH-хук/реквизиты). Главное меню
#     помещается в один экран
#   • МЕНЮ ВЫНЕСЕНО В ОТДЕЛЬНЫЙ ФАЙЛ xkit_menu.sh: UI-слой больше не раздувает
#     xkit.sh (ядро: API, установка, nginx, ноды, дашборд — не тронуто).
#     xkit.sh ищет модуль рядом с собой, затем в /usr/local/lib/xkit,
#     /usr/local/bin и /etc/xkit; при отсутствии — сам докачивает с репо
#     (XKIT_REPO_URL) со сверкой SHA-256
#   • install.sh и `xkit update` качают ОБА файла; пломба xkit.sh.sha256 —
#     формат sha256sum, 2 строки (старые версии читают первую строку —
#     обновление с v4.x работает без переустановки)
#   • uninstall чистит /usr/local/lib/xkit; one_step_install/
#     hide_existing_panel/ssh_hook_toggle обновляют модуль меню вместе
#     с командой xkit
#
#  НОВОЕ В v4.9.1 (совместимость с 3X-UI v3.x — инсталлятор уже ставит 3.11):
#   • КРИТИЧНО: «Не удалось войти в API панели» сразу после свежей установки
#     (пункт 2 и все пункты с API). Причина: 3X-UI v3 закрыл ВСЕ POST-запросы
#     CSRF-мiddleware'ом — без заголовка X-CSRF-Token панель отвечает 403 с
#     ПУСТЫМ телом (выглядит как «панель не отвечает», в ответе нет «Ответ:»).
#     Теперь xkit действует как браузер: GET <base>/csrf-token (создаёт сессию
#     и возвращает токен) → POST /login с X-CSRF-Token; заголовок ставится и во
#     ВСЕ POST-запросы к /panel/api/*. На 3X-UI v2.x ничего не ломается:
#     роута csrf-token там нет — xkit работает по-старому
#   • 3X-UI v3 перенёс эндпоинты: клиенты теперь /panel/api/clients/
#     {add|del/:email|resetTraffic/:email} (в v2: inbounds/addClient,
#     inbounds/:id/delClient/:cid — УДАЛЕНЫ в v3), настройки —
#     /panel/api/setting/*, xray-шаблон — POST /panel/api/xray/ + /update
#     (xrayTemplateConfig из settings в v3 ВЫВЕДЕН — чтение через старый
#     endpoint возвращало пустоту, и nodes_apply_template затирал бы конфиг).
#     xkit определяет поколение API (GET /panel/api/openapi.json есть только
#     в v3) и шлёт запросы в нужном формате: работают И v3.11, И v2.x
#   • externalProxy в v3 заменён на host-группы: пункт 19 (extfix), Reality-
#     inbound и pool-инбаунд нод на v3 создают запись /panel/api/hosts
#     (remark "xkit", апдейт по groupId — без дублей при повторном запуске)
#   • kit_login различает: панель не отвечает (curl exit) / 403 (CSRF —
#     устаревший xkit, подсказка «xkit update») / неверные логин-пароль
#     (HTTP-код + тело ответа)
#
#  НОВОЕ В v4.9.0 (замечания с живой установки):
#   • ВЫБОР АДРЕСА показывает реальный IP: определённый pubip выводится как
#     пункт 1 («IP этого сервера — 1.2.3.4»), Enter = согласиться, 2 = свой
#     домен/другой IP. Раньше адрес просили набрать вслепую — реальный IP
#     на экране не показывался
#   • certbot >= 5.3 ставится СРАЗУ (шаг 1/7, после apt): в репо Ubuntu 24.04
#     certbot 2.9 без --ip-address, и раньше это всплывало вопросом посреди
#     установки и могло её оборвать. Теперь pip/venv-обновление — неинтерактивно
#     в начале; в issue_cert_le_ip вопрос убран, авто-попытка без вопросов
#   • ПРОВАЛ выпуска серта больше НЕ выбрасывает из установки: меню
#     сертификата показывается снова (до 5 попыток; EOF/Ctrl-D = пункт 4,
#     самоподписанный — работает всегда). Раньше return 1 из issue_cert_le_ip
#     обрывал one_step_install и выкидывал админа в консоль
#   • Email для Let's Encrypt спрашивается только для пунктов 1/3 (раньше —
#     для всех, включая самоподписанный и свои файлы)
#   • install.sh: ник репозитория вписан сразу (kalsifar) — установка одной
#     строкой работает без правки install.sh
#
#  НОВОЕ В v4.8.0 (правки финального ревью №2 + GitHub-инструкция):
#   • node_add: EOF (Ctrl-D) на ЛЮБОМ вводе — отмена, а не молчаливое
#     продолжение с дефолтами 22/root и попыткой коннекта к ноде
#     (симметрия с v3.2.1; раньше EOF на порту/юзере проходил незаметно)
#   • install.sh: -y/--force доезжают до xkit при запуске НЕ от root —
#     явный проброс XKIT_YES/XKIT_FORCE/XKIT_NO_COLOR/XKIT_NO_ANIM/
#     XKIT_REPO_URL через `sudo env` (sudo сам env не наследует, env_keep
#     зависит от sudoers); root-путь (curl | sudo bash -s -- -y) — через export
#   • install.sh: warn() тоже в stderr (симметрия с xkit.sh) — диагностика
#     не попадает в пайпы/захват stdout
#   • GITHUB_SETUP.md — пошаговая инструкция: как выложить файлы на GitHub,
#     чтобы работала установка одной строкой (curl | sudo bash), включая
#     sha256-канал для `xkit update` и обновление версий
#
#  НОВОЕ В v4.7.0 (ревью UX + переустановка):
#   • ПОВТОРНЫЙ `xkit install` на установленном сервере больше не «ставит
#     поверх молча»: preflight обнаруживает /etc/xkit/xkit.env и предлагает
#     меню — 1) обновить скрипт (xkit update, состояние не трогается)
#     2) ЧИСТУЮ переустановку (бэкап -> полное удаление -> установка с нуля)
#     3) накатить поверх (с честным предупреждением, ЧТО слетит).
#     Раньше: env не загружался -> НОВЫЙ SUB_TOKEN (все ссылки подписок
#     ломались) + save_xkit_env затирал TG/dash-токены нулями
#   • `xkit uninstall [--full]`: бэкап ОБЯЗАТЕЛЕН перед удалением (провал
#     бэкапа = отмена); удаляет cron'ы, nginx-сайт, /etc/xkit, /var/lib/xkit,
#     htpasswd даша; --full дополнительно сносит 3X-UI и /etc/nginx/ssl.
#     Бэкапы (/var/backups/xkit) и letsencrypt сохраняются ВСЕГДА.
#     `xkit reinstall` = бэкап -> uninstall --full -> one_step_install
#   • ЖИВОЙ UX установки: цвета гаснут при не-TTY (curl|bash не мусорит
#     ANSI-кодами в логи), спиннер вокруг apt-get/детекта схемы панели/webListen
#     (было 20-60 сек тишины), индикатор шагов [n/7], полный лог установки
#     /var/log/xkit-*.log (600) с подсказкой в ошибках
#   • preflight ДО изменений: занятые порты 80/443 (с именами процессов),
#     свободное место (<500MB = отказ), RAM (<400MB = предупреждение),
#     доступ к сети; подтверждение при предупреждениях
#   • confirm()-хелпер и XKIT_YES=1: неинтерактивный режим (CI/cloud-init);
#     install.sh пробрасывает -y/--yes и --force; trap INT/TERM во время
#     установки чистит временные файлы и подсказывает путь к логу
#   • фикс по итогам ревью v4.7.0: warn() теперь пишет в stderr — раньше
#     warn внутри detect_panel_scheme попадал в захват $(with_spinner -o),
#     и PANEL_SCHEME превращался в "[WARN] …\nhttp", ломая api_url;
#     лог reinstall больше не затирается фазой установки (один общий файл
#     xkit-reinstall-*.log); uninstall --full сбрасывает failed-статус x-ui
#
#  После установки команда `xkit` доступна в SSH (меню как у 3X-UI).
#  Для cron/скриптов есть субкоманды: xkit route|sub|health|backup|restore|status
#
#  Тестирование функций без запуска меню: source xkit.sh (main вызывается
#  только при прямом запуске).
#==============================================================================

set -u -o pipefail
export LC_ALL=C

XKIT_VERSION="5.2.0"
# TTY-детект (ревью v4.7.0): при не-терминале (curl|bash, cron, tee, CI) цвета
# гаснут — в логах не остаётся сырых \033[… кодов. XKIT_NO_COLOR=1 — ручной
# override; XKIT_NO_ANIM=1 отключает спиннер при живом TTY
if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then
  GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
  IS_TTY=1
else
  GREEN=''; BLUE=''; RED=''; YELLOW=''; NC=''
  IS_TTY=0
fi

log()  { echo -e "${BLUE}[INFO] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK]   $*${NC}"; }
# warn — диагностика, а не данные: ВСЕГДА в stderr. Иначе warn внутри функции,
# чей stdout захватывается ($(...) / with_spinner -o), попадает в значение —
# например PANEL_SCHEME становился "[WARN] …\nhttp" и ломал api_url (ревью v4.7.0)
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERR ] $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

#=========================== UX-ХЕЛПЕРЫ УСТАНОВКИ =============================
# confirm «Вопрос [y/N]: " [y|n] — 0=да. Принимаются латинское y/yes,
# русское д/да и кириллическая у (визуально похожа на y). Любой другой ответ,
# включая «нет», означает отказ. XKIT_YES=1 (CI) = согласие на всё;
# EOF (Ctrl-D) = отмена, а не молчаливый дефолт
confirm() {
  local prompt="$1" default="${2:-n}" ans
  [ "${XKIT_YES:-0}" = "1" ] && return 0
  read -r -p "$prompt" ans || return 1
  ans="${ans:-$default}"
  # Не используем Unicode-символы внутри regex [...]: в C-локали байтовое
  # сравнение может ошибочно принять «нет». Явные префиксы безопасны.
  case "$ans" in
    y*|Y*|д*|Д*|у*|У*) return 0 ;;
    *)                  return 1 ;;
  esac
}

# шаги установки: [n/7] + 10-клеточный индикатор (non-TTY — просто текст)
STEP=0; STEPS=7
step() {
  STEP=$((STEP+1))
  local n=$(( STEP * 10 / STEPS )) bar="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$i" -le "$n" ]; then bar+="#"; else bar+="-"; fi
  done
  echo ""
  echo -e "${GREEN}[${STEP}/${STEPS}]${NC} $*  [${bar}]"
}

# временные файлы установки: регистрируются и снимаются trap'ом INT/TERM/EXIT
XKIT_TMPS=()
xkit_tmp_track() { XKIT_TMPS+=("$1"); }
xkit_install_cleanup() {
  local f
  for f in "${XKIT_TMPS[@]:-}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done
  return 0
}
xkit_install_traps_on() {
  trap 'xkit_install_cleanup; [ -n "${XKIT_LOG:-}" ] && printf "Прервано. Подробности: %s\n" "$XKIT_LOG" >&2; exit 130' INT TERM
  trap 'xkit_install_cleanup' EXIT
}
xkit_install_traps_off() { trap - INT TERM EXIT; }

# with_spinner "сообщение" cmd [args...] — спиннер на stderr, пока cmd работает;
# вывод cmd пишется в $XKIT_LOG, при ошибке хвост в терминал. Без TTY (или
# XKIT_NO_ANIM=1) — прозрачный прогон без анимации. Опция -o: stdout команды
# Возвращается вызывающему (для функций с результатом: detect_panel_scheme)
with_spinner() {
  local capture=0
  [ "${1:-}" = "-o" ] && { capture=1; shift; }
  local msg="$1"; shift
  if [ "${IS_TTY:-0}" != "1" ] || [ "${XKIT_NO_ANIM:-0}" = "1" ]; then
    "$@"
    return $?
  fi
  local tmplog pid rc=1 i=0
  tmplog="$(mktemp /tmp/xkit-spin.XXXXXX)" || { "$@"; return $?; }
  xkit_tmp_track "$tmplog"
  # -o (захват значения): stderr НЕ заворачиваем в tmplog — иначе диагностика
  # (warn/err) возвращается вызывающему вместе с данными и ломает значение
  # (ревью v4.7.0: PANEL_SCHEME = "[WARN] …\nhttp"). stderr идёт в терминал —
  # то же поведение, что и в non-TTY пути выше. Без -o — тишина: всё в tmplog.
  if [ "$capture" = "1" ]; then
    "$@" >"$tmplog" &
  else
    "$@" >"$tmplog" 2>&1 &
  fi
  pid=$!
  local marks='-\|/'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s[%s]%s %s   ' "$GREEN" "${marks:$i:1}" "$NC" "$msg" >&2
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  wait "$pid"; rc=$?
  printf '\r\033[K' >&2                      # стереть строку спиннера
  if [ "$capture" = "1" ]; then
    if [ $rc -eq 0 ]; then cat "$tmplog"; else tail -n 10 "$tmplog" >&2; fi
  else
    [ -n "${XKIT_LOG:-}" ] && cat "$tmplog" >>"$XKIT_LOG" 2>/dev/null
    if [ $rc -eq 0 ]; then
      printf '%s[OK]%s   %s\n' "$GREEN" "$NC" "$msg" >&2
    else
      printf '%s[ERR]%s  %s%s\n' "$RED" "$NC" "$msg" "${XKIT_LOG:+ (подробности: $XKIT_LOG)}" >&2
      tail -n 20 "$tmplog" | sed 's/^/       /' >&2
    fi
  fi
  rm -f "$tmplog"
  return $rc
}

# XKIT_LOG — полный лог долгоиграющей операции (установка/переустановка/
# удаление): всё, что оборачивается спиннером, попадает сюда. chmod 600 —
# установщики печатают реквизиты
xkit_log_begin() { # $1 = префикс имени (install|reinstall|uninstall)
  # Первый вызов открывает новый лог. Повторный вызов в том же процессе
  # (reinstall: uninstall -> install) переиспользует уже открытый файл и
  # НЕ очищает его — обе фазы остаются в одном логе, имя — по первой фазе
  # (ревью v4.7.0: раньше `: >` затирало лог фазы удаления).
  if [ -n "${XKIT_LOG:-}" ]; then
    [ -e "$XKIT_LOG" ] || : >"$XKIT_LOG" 2>/dev/null || true
    return 0
  fi
  XKIT_LOG="/var/log/xkit-$1-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$XKIT_LOG")" 2>/dev/null || true
  : >"$XKIT_LOG" 2>/dev/null || true
  chmod 600 "$XKIT_LOG" 2>/dev/null || true
}

CERTBOT_MIN_IP="5.3"                 # certbot для --ip-address
XUI_INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

# K-02 (аудит №2): установщик 3X-UI — по тегу ПОСЛЕДНЕГО РЕЛИЗА (master плавает
# и может измениться в любой момент). Переопределить: XKIT_3XUI_TAG=vX.Y.Z
xui_install_url() {
  local tag="${XKIT_3XUI_TAG:-}"
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null \
      | jq -r '.tag_name // ""' 2>/dev/null || true)"
  fi
  if [[ "$tag" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
    printf 'https://raw.githubusercontent.com/mhsanaei/3x-ui/%s/install.sh' "$tag"
  else
    warn "Не удалось определить тег релиза 3X-UI — качаю master (зафиксируйте: XKIT_3XUI_TAG=vX.Y.Z)" >&2
    printf '%s' "$XUI_INSTALLER_URL"
  fi
}
XKIT_DIR="/etc/xkit"
XKIT_ENV="${XKIT_DIR}/xkit.env"
XKIT_ROUTES="${XKIT_DIR}/routes.tsv"
XKIT_NODES="${XKIT_DIR}/nodes.json"
XKIT_EXPIRY="${XKIT_DIR}/expiry.tsv"     # сроки аренды: scope<TAB>id<TAB>date<TAB>note
XKIT_DASH_DIR="/var/lib/xkit/dash"        # веб-дашборд (index.html + data.json)
XKIT_DASH_HTPASSWD="/etc/nginx/.xkit-dash.htpasswd"  # Basic Auth дашборда
XKIT_INFO_FILE="/root/xkit-info.txt"      # сводка-реквизиты (терминал + файл)
XKIT_NOTIFY_STATE="${XKIT_DIR}/notify.state"  # состояние Telegram-алертов (гистерезис/дедуп)
XKIT_BIN="/usr/local/bin/xkit"
XKIT_MENU_DIR="${XKIT_MENU_DIR:-/usr/local/lib/xkit}"  # модули XKIT
XKIT_PROTOCOLS_FILE="${XKIT_PROTOCOLS_FILE:-${XKIT_MENU_DIR}/xkit_protocols.sh}"
XKIT_TUI_FILE="${XKIT_TUI_FILE:-${XKIT_MENU_DIR}/xkit-tui}"
SUBS_DIR="/var/lib/xkit/subs"
BACKUP_DIR="/var/backups/xkit"
# cron-файлы кита — переменные (не хардкод), чтобы uninstall и тесты работали
# с переопределёнными путями
XKIT_CRON_MAIN="/etc/cron.d/xkit"
XKIT_CRON_DASH="/etc/cron.d/xkit-dash"
XKIT_CRON_NOTIFY="/etc/cron.d/xkit-notify"
XKIT_CONF="/etc/nginx/sites-available/xkit.conf"
XKIT_CONF_LINK="/etc/nginx/sites-enabled/xkit.conf"
XUI_RESULT="/etc/x-ui/install-result.env"
XUI_DB="/etc/x-ui/x-ui.db"

#=========================== ВАЛИДАЦИЯ ВВОДА ==================================
is_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] || return 1
  # TLD должен содержать букву: иначе "999.999.999.999" проходит как домен
  [[ "${1##*.}" =~ [a-zA-Z] ]]
}

is_ipv4() {
  local ip="$1" IFS='.' o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for o in $ip; do [ "$((10#$o))" -le 255 ] || return 1; done
  return 0
}

is_ipv6() {
  [[ "$1" =~ ^[0-9a-fA-F:]{2,45}$ ]] && [[ "$1" == *:* ]] || return 1
  # точная валидация inet_pton (regex пропускает a::b::c и «1234:», аудит №10);
  # python3 — зависимость (п.15), без него — фолбэк: двойное «::» невалидно
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket,sys; socket.inet_pton(socket.AF_INET6, sys.argv[1])' "$1" >/dev/null 2>&1
  else
    # №7 (аудит №1)/N-04 (№2): getent резолвит литерал ТОЛЬКО если это валидный
    # адрес (charset уже ограничен [0-9a-fA-F:] — DNS-имя сюда попасть не может)
    getent ahosts "$1" >/dev/null 2>&1
  fi
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_cidr() { # a.b.c.d/NN (0-32) или IPv6/NN (0-128) — для allow-списков nginx
  local ip="${1%%/*}" m="${1##*/}"
  [[ "$1" == */* ]] || return 1
  [[ "$m" =~ ^[0-9]{1,3}$ ]] || return 1
  if is_ipv4 "$ip"; then [ "$m" -le 32 ] 2>/dev/null
  elif is_ipv6 "$ip"; then [ "$m" -le 128 ] 2>/dev/null
  else return 1; fi
}

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_path() { [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$1" != *"//"* ]]; }

# Строгий location-путь для генерации nginx (K-01, аудит №2): панель/инбаунд/
# routes.tsv не должны уметь вставить директивы. Запрещены ~ (regex-маркер
# location), .. (alias-эскапада), // и * (модификатор location)
is_nginx_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] || return 1
  [[ "$1" != *"//"* && "$1" != *".."* && "$1" != *"~"* && "$1" != *"*"* ]]
}

# host:port / [v6]:port -> R_HOST/R_PORT (K-01; заодно F-3: IPv6-таргет
# раньше ломал domain_only="${target%%:*}" -> "[2001")
parse_hostport() {
  local s="$1"
  R_HOST=""; R_PORT=""
  case "$s" in
    \[*\]:*)
      R_HOST="${s%%]:*}"; R_HOST="${R_HOST#\[}"
      R_PORT="${s##*]:}"
      ;;
    *:*)
      [[ "$s" == *:*:* ]] && return 1   # голый IPv6 (несколько :) — только в скобках
      R_HOST="${s%%:*}"; R_PORT="${s##*:}"
      ;;
    *) return 1 ;;
  esac
  is_port "$R_PORT" || return 1
  case "$s" in
    \[*) is_ipv6 "$R_HOST" || return 1 ;;
    *)   is_ipv4 "$R_HOST" || is_hostname "$R_HOST" || return 1 ;;
  esac
  return 0
}

safe_conf_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

is_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# одно-меточное имя хоста без точки (localhost, relay-алиасы) — is_domain требует точку
is_hostname() { is_domain "$1" || [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

# СНАЧАЛА IP, потом домен: "1.2.3.4" проходит и доменную регулярку!
host_kind() { if is_ip "$1"; then echo "ip"; elif is_domain "$1"; then echo "domain"; else echo "bad"; fi }

# публичный IP этого сервера; если ответ не валидный IP (подмена/ошибка) — пусто
pubip() {
  local ip
  ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
  is_ip "$ip" || ip=""
  printf '%s' "$ip"
}

normalize_panel_path() {
  local p="$1"
  [ -n "$p" ] || p="/"
  case "$p" in /*) ;; *) p="/${p}" ;; esac
  case "$p" in */) ;; *) p="${p}/" ;; esac
  printf '%s' "$p"
}

read_host() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_domain "$v" || is_ip "$v"; then printf '%s' "$v"; return 0; fi
    err "Некорректно: '$v'. Нужен домен или IP — без http://, путей и портов"
  done
}

# ревью v4.9.0 (живая установка): адрес сервера раньше просили набрать вслепую —
# реальный IP на экране не показывался. Теперь определяем pubip и показываем его
# как пункт 1 (Enter = согласиться); 2 — свой домен/другой IP вручную.
# Результат — в глобальной CHOSEN_HOST (stdout занят меню, $() не использовать)
choose_host() {
  local prompt="${1:-Адрес этого сервера}" myip a
  myip="$(pubip)"
  if [ -z "$myip" ]; then
    warn "Публичный IP не определился (api.ipify.org недоступен?) — введите адрес вручную"
    CHOSEN_HOST="$(read_host "$prompt (домен/IP) -> ")"
    return 0
  fi
  echo ""
  echo -e "${YELLOW}${prompt}:${NC}"
  echo "1) IP этого сервера — $myip (определён автоматически)"
  echo "2) Свой домен или другой IP (ввести вручную)"
  while true; do
    read -r -p "Ваш выбор [1]: " a || { echo; a="1"; }
    case "${a:-1}" in
      1) CHOSEN_HOST="$myip"; return 0 ;;
      2) CHOSEN_HOST="$(read_host "Домен или IP -> ")"; return 0 ;;
      *) err "Пункт 1 или 2" ;;
    esac
  done
}

read_port() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_port "$v"; then printf '%s' "$v"; return 0; fi
    err "Порт должен быть числом 1-65535"
  done
}

read_path() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_path "$v"; then printf '%s' "$v"; return 0; fi
    err "Путь: начинается с /, буквы/цифры/._~/- (без пробелов)"
  done
}

#=========================== СЛУЧАЙНОСТИ ======================================
rand_str() { # [длина] -> [a-zA-Z0-9]; запас входа x3 + доводка циклом: длина всегда точная,
             # head в пайпе нет -> SIGPIPE не роняет цепочку (аудит №9), энтропия base64 сохранена
  local n="${1:-32}" s
  s="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  while [ "${#s}" -lt "$n" ]; do
    s+="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  done
  printf '%s' "${s:0:$n}"
}
rand_hex() { openssl rand -hex "$1" 2>/dev/null; }

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else
    # fallback в корректном формате UUID 8-4-4-4-12
    printf '%s-%s-%s-%s-%s' "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 6)"
  fi
}

port_busy() { ss -ltnH 2>/dev/null | awk -v p=":$1 " 'index($4, p)' | grep -q .; }

rand_free_port() {
  local lo="${1:-20000}" hi="${2:-60000}" p i
  for i in $(seq 1 100); do
    p=$(shuf -i "${lo}-${hi}" -n 1 2>/dev/null) || return 1
    if ! port_busy "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

enc_uri() { jq -rn --arg s "$1" '$s|@uri'; }
# как enc_uri, но '/' не кодируется — пути в ссылках остаются читаемыми (/xk-ws-2083/)
enc_uri_path() { jq -rn --arg s "$1" '$s|@uri' | sed 's/%2F/\//gi'; }

#=========================== ХЕЛПЕРЫ NGINX ====================================
nginx_ver() { nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p'; }

ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# синтаксис http2 под версию nginx (Ubuntu 24.04 = 1.24 -> старый синтаксис)
# $1 = "v6" -> строка listen для IPv6. ВАЖНО: двоеточие в [::]:443 обязательно
# (без него nginx -t падает — invalid parameter; ревью v4.6.0). «http2 on;»
# (новый синтаксис) выводится ТОЛЬКО в v4-строке: дубль дал бы duplicate
# directive; при старом синтаксисе http2 встроен в сам listen
build_h2_block() {
  local ver addr=""
  [ "${1:-}" = "v6" ] && addr="[::]:"
  ver=$(nginx_ver)
  if [ -n "$ver" ] && ver_ge "$ver" "1.25.1"; then
    if [ -n "$addr" ]; then
      printf '    listen [::]:443 ssl;'
    else
      printf '    listen 443 ssl;\n    http2 on;'
    fi
  else
    printf '    listen %s443 ssl http2;' "$addr"
  fi
}

# слушать ли IPv6 (А3: v6-only клиенты за CGNAT не достучатся без [::]:443):
# глобальный v6-адрес на сервере; XKIT_V6_LISTEN=0|1|auto — принудительно
v6_listen_enabled() {
  case "${XKIT_V6_LISTEN:-auto}" in
    0|false|no)  return 1 ;;
    1|true|yes)  return 0 ;;
  esac
  ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}

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
  # серт и ключ должны быть парными (одинаковый публичный ключ)
  [ "$(openssl x509 -noout -pubkey -in "$src/fullchain.pem" 2>/dev/null | sha256sum | awk '{print $1}')" = \
    "$(openssl pkey -pubout -in "$src/privkey.pem" 2>/dev/null | sha256sum | awk '{print $1}')" ] \
    || { err "fullchain.pem и privkey.pem не парные (разные ключи)"; return 1; }
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

#=========================== ПРОВЕРКА ОС ======================================
require_root() { [ "$EUID" -eq 0 ] || die "Запустите от root: sudo bash xkit.sh ..."; }

check_os() {
  local id="" ver=""
  if [ -f /etc/os-release ]; then
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  fi
  case "$id" in
    ubuntu)
      local major="${ver%%.*}"
      [ -n "$major" ] || major=0
      if [ "$major" -ge 24 ] 2>/dev/null; then
        ok "ОС: Ubuntu $ver — полностью поддерживается"
      else
        warn "ОС: Ubuntu $ver — рекомендован 24.04+, продолжаю"
      fi ;;
    debian) warn "ОС: Debian $ver — скрипт заточен под Ubuntu 24+, скорее всего тоже сработает" ;;
    *)      warn "ОС неопознана (${id} ${ver}) — скрипт рассчитан на Ubuntu 24+" ;;
  esac
  return 0
}

#=========================== 3X-UI: ХЕЛПЕРЫ ===================================
install_3xui_auto() {
  if command -v x-ui >/dev/null 2>&1; then
    warn "3X-UI уже установлен — использую текущие настройки"
    return 0
  fi
  log "Скачиваю официальный установщик 3X-UI (K-02: тег релиза, не master)..."
  local u; u="$(xui_install_url)"
  local dl; dl="$(mktemp /tmp/xkit-3xui.XXXXXX)" || die "mktemp не удался"
  curl -fsSL -o "$dl" "$u" \
    || { rm -f "$dl"; die "Не удалось скачать установщик 3X-UI (проверьте сеть)"; }
  bash -n "$dl" || { rm -f "$dl"; die "Скачанный установщик 3X-UI не проходит bash -n — отмена (K-02)"; }
  log "Устанавливаю 3X-UI в неинтерактивном режиме (случайные креды)..."
  if ! XUI_NONINTERACTIVE=1 bash "$dl" </dev/null; then
    rm -f "$dl"
    err "Установщик 3X-UI завершился с ошибкой"
    return 1
  fi
  rm -f "$dl"
  systemctl enable --now x-ui >/dev/null 2>&1 || true
  ok "3X-UI установлен"
  return 0
}

# PANEL_PORT / PANEL_WBP / PANEL_USER / PANEL_PASS из install-result.env
# (основной источник) или из `x-ui setting -show true` (запасной)
# значение из install-result.env БЕЗ source (аудит №8: файл пишет инсталлятор
# 3X-UI, но source произвольного файла — лишний вектор). Парсим построчно:
# снимаем surrounding-кавычки и CR, внутренности не трогаем
xui_env_val() { # $1 KEY, $2 файл -> значение
  # awk с точным сравнением $1==k: sed "s/^$1=//" трактовал метасимволы (& . * /)
  # в ключе как regex — с текущими статическими ключами безопасно, но awk
  # безопасен всегда (ревью v4.6.0); берём первое вхождение (exit)
  local v
  v="$(awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null)"
  v="${v%$'\r'}"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

read_panel_settings() {
  PANEL_PORT=""; PANEL_WBP=""; PANEL_USER=""; PANEL_PASS=""
  if [ -f "$XUI_RESULT" ]; then
    PANEL_PORT="$(xui_env_val XUI_PANEL_PORT "$XUI_RESULT")"
    PANEL_WBP="$(xui_env_val XUI_WEB_BASE_PATH "$XUI_RESULT")"
    PANEL_USER="$(xui_env_val XUI_USERNAME "$XUI_RESULT")"
    PANEL_PASS="$(xui_env_val XUI_PASSWORD "$XUI_RESULT")"
  fi
  if [ -z "$PANEL_PORT" ] || [ -z "$PANEL_WBP" ]; then
    if command -v x-ui >/dev/null 2>&1; then
      local s
      s=$(x-ui setting -show true 2>/dev/null || true)
      [ -z "$PANEL_PORT" ] && PANEL_PORT=$(echo "$s" | awk -F': ' '/port:/{print $2; exit}' | tr -d '[:space:]')
      [ -z "$PANEL_WBP" ]  && PANEL_WBP=$(echo "$s" | awk -F': ' '/webBasePath:/{print $2; exit}' | tr -d '[:space:]')
    fi
  fi
  [ -n "$PANEL_PORT" ] || { err "Не удалось определить порт панели 3X-UI"; return 1; }
  is_port "$PANEL_PORT" || { err "K-01: порт панели некорректен: ${PANEL_PORT:0:20}"; return 1; }
  PANEL_WBP=$(normalize_panel_path "$PANEL_WBP")
  is_nginx_path "$PANEL_WBP" || { err "K-01: webBasePath панели некорректен: ${PANEL_WBP:0:40}"; return 1; }
  return 0
}

# Панель слушает http или https на 127.0.0.1 (если инсталлятор выдал ей серт)
detect_panel_scheme() {
  local p="$1" code i
  for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "http"; return 0 ;; esac
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "https"; return 0 ;; esac
    sleep 2
  done
  warn "Панель не отвечает на 127.0.0.1:${p} — предполагаю http"
  echo "http"
}

# Панель должна слушать ТОЛЬКО 127.0.0.1 (webListen в БД панели).
# Если не выйдет (postgres / другая схема) — остаётся UFW deny.
force_panel_localhost() {
  local port="$1"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -f "$XUI_DB" ] || return 1
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key,value) VALUES ('webListen','127.0.0.1');" 2>/dev/null || return 1
  systemctl restart x-ui >/dev/null 2>&1 || return 1
  sleep 2
  # проверяем: слушает ли панель 0.0.0.0? (found=1 -> exit 0 -> exposed)
  if ss -ltnH 2>/dev/null | awk -v p=":${port} " '
      index($4, p) { if ($4 !~ /^127\.0\.0\.1/ && $4 !~ /^\[::1\]/) found=1 }
      END { exit (found ? 0 : 1) }'; then
    return 1
  fi
  return 0
}

#=========================== СОСТОЯНИЕ XKIT ===================================
save_xkit_env() {
  mkdir -p "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  chmod 700 "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  # запись в subshell (симметрично notify_state_set/dash_gen_locked, ревью
  # v4.6.0): umask 077 не утекает в вызывающую оболочку при любом сбое;
  # провал записи теперь честный — err + return 1, а не молчаливый ok
  (
    umask 077
    tmp="$(mktemp)" || exit 1
    {
      printf 'XKIT_VERSION=%q\n' "$XKIT_VERSION"
      printf 'XKIT_HOST=%q\n' "${XKIT_HOST:-}"
      printf 'XKIT_CRT=%q\n' "${XKIT_CRT:-}"
      printf 'XKIT_KEY=%q\n' "${XKIT_KEY:-}"
      printf 'XKIT_CERT_MODE=%q\n' "${XKIT_CERT_MODE:-}"
      printf 'XKIT_SUB_TOKEN=%q\n' "${XKIT_SUB_TOKEN:-}"
      printf 'XKIT_UFW=%q\n' "${XKIT_UFW:-0}"
      printf 'XKIT_PANEL_SUB_PORT=%q\n' "${XKIT_PANEL_SUB_PORT:-}"
      printf 'XKIT_PANEL_SUB_PATH=%q\n' "${XKIT_PANEL_SUB_PATH:-}"
      printf 'XKIT_REALITY_INTERNAL=%q\n' "${XKIT_REALITY_INTERNAL:-0}"
      printf 'XKIT_BAL_STRATEGY=%q\n' "${XKIT_BAL_STRATEGY:-roundRobin}"
      printf 'XKIT_POOL_INBOUND=%q\n' "${XKIT_POOL_INBOUND:-}"
      printf 'XKIT_POOL_TAG=%q\n' "${XKIT_POOL_TAG:-}"
      printf 'XKIT_REPO_URL=%q\n' "${XKIT_REPO_URL:-}"
      printf 'XKIT_DASH=%q\n' "${XKIT_DASH:-0}"
      printf 'XKIT_DASH_TOKEN=%q\n' "${XKIT_DASH_TOKEN:-}"
      printf 'XKIT_DASH_ALLOW=%q\n' "${XKIT_DASH_ALLOW:-}"
      printf 'XKIT_DASH_AUTH=%q\n' "${XKIT_DASH_AUTH:-1}"
      printf 'XKIT_DASH_USER=%q\n' "${XKIT_DASH_USER:-}"
      printf 'XKIT_DASH_PASS=%q\n' "${XKIT_DASH_PASS:-}"
      printf 'XKIT_TG_TOKEN=%q\n' "${XKIT_TG_TOKEN:-}"
      printf 'XKIT_TG_CHAT=%q\n' "${XKIT_TG_CHAT:-}"
      printf 'XKIT_TG_PROXY=%q\n' "${XKIT_TG_PROXY:-}"
    } > "$tmp"
    mv "$tmp" "$XKIT_ENV"
  ) || { err "Не удалось сохранить $XKIT_ENV"; return 1; }
  chmod 600 "$XKIT_ENV" 2>/dev/null
  ok "Состояние сохранено: $XKIT_ENV"
}

load_xkit_env() {
  XKIT_HOST=""; XKIT_CRT=""; XKIT_KEY=""; XKIT_CERT_MODE=""; XKIT_SUB_TOKEN=""; XKIT_UFW="0"
  XKIT_PANEL_SUB_PORT=""; XKIT_PANEL_SUB_PATH=""; XKIT_REALITY_INTERNAL="0"
  XKIT_BAL_STRATEGY="roundRobin"; XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  XKIT_DASH="0"; XKIT_DASH_TOKEN=""; XKIT_DASH_ALLOW=""
  XKIT_DASH_AUTH="1"; XKIT_DASH_USER=""; XKIT_DASH_PASS=""
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""
  local _repo="${XKIT_REPO_URL:-}"   # внешнее значение (от install.sh) не теряем
  XKIT_REPO_URL="$_repo"             # №22: фолбэк ДО чтения env — ранний return не теряет
  [ -r "$XKIT_ENV" ] || return 1
  # shellcheck disable=SC1090
  . "$XKIT_ENV"
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  return 0
}

# XKIT_SUB_PATH зависит от токена
sub_path() {
  printf '/s-%s/' "${XKIT_SUB_TOKEN:-CHANGE_ME}"
}

#=========================== МАРШРУТЫ (routes.tsv) ============================
# Формат: id<TAB>mode<TAB>net<TAB>path<TAB>target<TAB>tag
#   id:    id инбаунда панели (число) или m<rand> для ручных маршрутов
#   mode:  local (127.0.0.1) | relay (внешний сервер) | panel
#   net:   grpc | ws | xhttp | tcp | web
#   path:  внешний путь с слэшами /xk-ws-2083/
#   target:127.0.0.1:PORT | host:443
routes_load() {
  ROUTES=()
  [ -r "$XKIT_ROUTES" ] || return 0
  mapfile -t ROUTES < "$XKIT_ROUTES"
}

routes_upsert() { # $1..$6 поля строки
  local id="$1" line
  mkdir -p "$(dirname "$XKIT_ROUTES")" 2>/dev/null || true
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6")"
  if [ -f "$XKIT_ROUTES" ]; then
    awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
    mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
  fi
  printf '%s\n' "$line" >> "$XKIT_ROUTES"
  chmod 600 "$XKIT_ROUTES"
}

routes_del() {
  local id="$1"
  [ -f "$XKIT_ROUTES" ] || return 0
  awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
  mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
}

# путь для маршрута инбаунда: детерминированный, по типу транспорта и порту
auto_path_for() { # $1 net (ws|grpc|xhttp|hu|tc)  $2 port
  printf '/xk-%s-%s/' "$1" "$2"
}

#=========================== API ПАНЕЛИ (REST) ================================
# Слой для клиентов/автопроброса/подписок. Все ответы панель отдаёт как
# {"success":true/false,"msg":"...","obj":...}. Всё defensively через jq:
# если формат API когда-нибудь поменяется — увидите понятную ошибку.
#
# ПОКОЛЕНИЯ API (v4.9.1): 3X-UI v3.x (2026) закрыл ВСЕ POST-запросы
# CSRF-мiddleware'ом (без X-CSRF-Token — ответ 403 С ПУСТЫМ телом) и перенёс
# клиентские эндпоинты в /panel/api/clients/*, настройки — в /panel/api/setting/*,
# xray-шаблон — в /panel/api/xray/*. API_V3 определяется в kit_session по
# GET /panel/api/openapi.json (есть только в v3). На v2 всё по-старому.

api_url() { printf '%s://127.0.0.1:%s%s' "${PANEL_SCHEME:-http}" "${PANEL_PORT}" "${PANEL_WBP}"; }

API_V3=0      # 1 = панель 3X-UI v3+ (CSRF + /panel/api/clients|setting|xray/*)
CSRF_TOKEN="" # токен сессии для POST (v3+); пусто = панель v2 — заголовок не ставим

curl_panel() { # curl к панели с учётом схемы (свой/самоподписанный серт = -k)
  local -a a=(-s)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  curl "${a[@]}" "$@"
}

csrf_fetch() { # GET <base>/csrf-token -> CSRF_TOKEN (v3+; v2: роута нет, пусто)
  local out
  # -b -c: отправляем текущую сессию И обновляем jar (повторный вызов после
  # логина обязан привязать новый токен к АВТОРИЗОВАННОЙ сессии)
  out="$(curl_panel --max-time 8 -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$(api_url)csrf-token" 2>/dev/null)" || return 0
  if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    CSRF_TOKEN="$(jq -r '.obj // ""' <<<"$out" 2>/dev/null || true)"
  fi
  return 0
}

kit_login() {
  COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
  local url rc code out resp
  url="$(api_url)login"
  # 3X-UI v3+: POST /login без CSRF-токена = 403 с ПУСТЫМ телом. GET /csrf-token
  # создаёт сессию и возвращает токен (как у браузера); v2: 404 — без заголовка
  csrf_fetch
  resp="$(mktemp /tmp/xkit-login.XXXXXX)"; chmod 600 "$resp"
  local -a h=()
  [ -n "$CSRF_TOKEN" ] && h+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  # V-03 (аудит №2): тело через stdin (--data @-) — пароль не светится в argv
  local body
  body="username=$(jq -rn --arg v "${PANEL_USER:-}" '$v|@uri')&password=$(jq -rn --arg v "${PANEL_PASS:-}" '$v|@uri')"
  rc=0
  code="$(printf '%s' "$body" | curl_panel --max-time 8 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -o "$resp" -w '%{http_code}' -X POST "${h[@]}" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data @- "$url")" || rc=$?
  out="$(cat "$resp" 2>/dev/null || true)"; rm -f "$resp"
  if [ "$rc" -ne 0 ]; then
    err "Панель не отвечает (127.0.0.1:${PANEL_PORT}, curl exit ${rc}) — проверьте: systemctl status x-ui"
    return 1
  fi
  if [ "$code" = "403" ]; then
    err "Панель отклонила запрос (403: CSRF-мiddleware) — устаревший xkit для этой версии 3X-UI"
    err "Обновите меню:  xkit update  (или скачайте свежий xkit.sh из репозитория)"
    return 1
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "Не удалось войти в API панели (127.0.0.1:${PANEL_PORT}${PANEL_WBP}login, HTTP ${code})"
    if [ -n "$out" ]; then
      err "Ответ: $(head -c 300 <<<"$out")"
    else
      err "Тело ответа пустое (HTTP ${code}) — нестандартная сборка 3X-UI или прокси перед панелью"
    fi
    err "Проверьте логин/пароль панели (install-result.env или меню панели x-ui)"
    return 1
  fi
  # v4.9.1: после логина панель ЧИСТИТ сессию (SetLoginUser -> s.Clear()) —
  # CSRF-токен анонимной сессии аннулирован, и все POST вернули бы 403.
  # Переполучаем токен уже от АВТОРИЗОВАННОЙ сессии — как делает и фронтенд панели
  csrf_fetch
  return 0
}

api_get() {
  local url; url="$(api_url)panel/api/inbounds/$1"
  if [ "${PANEL_SCHEME:-http}" = "https" ]; then curl -sk --max-time 10 -b "$COOKIE_JAR" "$url"
  else curl -s --max-time 10 -b "$COOKIE_JAR" "$url"; fi
}

api_post() { # $1 путь, $2 JSON-тело (пусто = без тела)
  local url; url="$(api_url)panel/api/inbounds/$1"
  local -a args=(-s --max-time 15 -b "$COOKIE_JAR" -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "$CSRF_TOKEN" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  if [ -n "${2:-}" ]; then
    curl "${args[@]}" -H 'Content-Type: application/json' -d "$2" "$url"
  else
    curl "${args[@]}" "$url"
  fi
}

api_list() {
  local out
  out="$(api_get list)" || { err "Панель не отвечает на запрос списка инбаундов"; return 1; }
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "API list: $(jq -r '.msg // "неожиданный ответ (проверьте версию 3x-ui)"' <<<"$out" | head -c 200)"
    return 1
  fi
  jq '.obj // []' <<<"$out"
}

# полный JSON одного инбаунда по id
api_get_inbound() {
  local out
  out="$(api_get "get/$1")" || return 1
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1 || return 1
  jq '.obj' <<<"$out"
}

# обновить инбаунд целиком (панель применит listen/streamSettings)
api_update_inbound() { # $1 id, $2 полный JSON инбаунда
  local resp
  resp="$(api_post "update/$1" "$2")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "update инбаунда #$1: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# удалить инбаунд целиком (3x-ui API: POST /panel/api/inbounds/del/:id)
api_del_inbound() { # $1 id
  local resp
  resp="$(api_post "del/$1" "")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "del инбаунда #$1: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

api_post_json() { # $1 путь от base, $2 JSON-тело — для эндпоинтов вне /panel/api/inbounds
  local url; url="$(api_url)${1#/}"
  local -a args=(-s --max-time 20 -b "$COOKIE_JAR" -X POST -H 'Content-Type: application/json')
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "$CSRF_TOKEN" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  curl "${args[@]}" -d "$2" "$url"
}

# v4.9.1: 3X-UI v3 перенёс клиентов в /panel/api/clients/*:
#   add     POST /panel/api/clients/add              {"client":{...},"inboundIds":[id]}
#   del     POST /panel/api/clients/del/:email
#   reset   POST /panel/api/clients/resetTraffic/:email
# (старые v2-пути inbounds/addClient, inbounds/:id/delClient/:cid в v3 УДАЛЕНЫ)
api_add_client() { # $1 id инбаунда, $2 JSON ОДНОГО клиента, $3 текущая строка settings (для v2)
  local id="$1" cj="$2" settings="$3" resp
  if [ "$API_V3" = "1" ]; then
    local body
    body="$(jq -nc --argjson c "$cj" --argjson i "$id" '{client:$c, inboundIds:[$i]}')"
    resp="$(api_post_json "panel/api/clients/add" "$body")" || return 1
  else
    local body new_settings
    new_settings="$(jq -c --argjson c "$cj" '.clients += [$c]' <<<"$settings")" || return 1
    body="$(jq -n --arg id "$id" --arg s "$new_settings" '{"id":($id|tonumber),"settings":$s}')"
    resp="$(api_post addClient "$body")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "addClient: $(jq -r '.msg // "ошибка"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

api_del_client() { # $1 id инбаунда, $2 email, $3 clientId (uuid; нужен только v2)
  local resp
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/clients/del/$2")" || return 1
  else
    resp="$(api_post "$1/delClient/$3" "")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "delClient: $(jq -r '.msg // "ошибка"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

# единая точка входа: залогиниться и получить список инбаундов
# результат в глобальной INBOUNDS (JSON-массив)
kit_session() {
  load_xkit_env || true
  read_panel_settings || return 1
  PANEL_SCHEME=$(detect_panel_scheme "$PANEL_PORT")
  kit_login || return 1
  api_detect_generation
  INBOUNDS="$(api_list)" || return 1
  return 0
}

# поколение API: GET /panel/api/openapi.json отвечает JSON-ом только в v3+
# (v2: 404/SPA). Лениво и без цензуры: не определили — считаем v2 (старые пути)
api_detect_generation() {
  local out
  API_V3=0
  out="$(api_get_raw "panel/api/openapi.json" 2>/dev/null || true)"
  if jq -e '.openapi' <<<"$out" >/dev/null 2>&1; then
    API_V3=1
    log "Панель 3X-UI v3: клиенты/настройки через /panel/api/clients|setting|xray/*"
  fi
  return 0
}

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

reality_pbk() { # $1 = ТЕКСТ streamSettings (уже объект для jq)
  jq -r '.realitySettings.settings.publicKey // .realitySettings.publicKey // ""' <<<"$1" 2>/dev/null
}
reality_sid() { jq -r '.realitySettings.shortIds[0] // ""' <<<"$1" 2>/dev/null; }
reality_sni() { jq -r '.realitySettings.serverNames[0] // ""' <<<"$1" 2>/dev/null; }

# собирает одну ссылку для клиента
link_for_client() { # $1 inbound JSON, $2 client JSON (settings-объект)
  local ib="$1" cl="$2"
  local id port proto tag2 mode rnet rpath
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  IFS='|' read -r mode rnet rpath <<<"$(route_info "$id")"

  local stream="" host="" path="" svc="" sni="" pbk="" sid="" flow="" email="" uuid="" pass="" method=""
  stream="$(jq -r '.streamSettings // "{}"' <<<"$ib")"
  host="${XKIT_HOST}"
  email="$(jq -r '.email // "user"' <<<"$cl")"
  flow="$(jq -r '.flow // ""' <<<"$cl")"

  if [ "$mode" = "local" ]; then
    # за nginx: TLS на 443, путь из routes.tsv
    case "$rnet" in
      grpc) svc="$(inbound_path "$ib" grpc)"; [ -n "$svc" ] || svc="xk-gr-${port}" ;;
      ws|xhttp|httpupgrade) path="$(inbound_path "$ib" "$rnet")"; [ -n "$path" ] || path="$rpath" ;;
      tcp) path="$(inbound_path "$ib" tcp)"; [ -n "$path" ] || path="$rpath" ;;
    esac
    _link_proto "$proto" "$email" "$host" 443 "$rnet" "tls" "$path" "$svc" "$host" "" "" "" "$flow" "$cl" "$ib"
  else
    # direct: реальный порт, security из streamSettings ($stream — уже JSON-текст)
    local net="" sec=""
    net="$(jq -r '.network // "tcp"' <<<"$stream" 2>/dev/null)"
    sec="$(jq -r '.security // "none"' <<<"$stream" 2>/dev/null)"
    [ "$sec" = "tls" ] && sni="$host"
    if [ "$sec" = "reality" ]; then
      pbk="$(reality_pbk "$stream")"; sid="$(reality_sid "$stream")"; sni="$(reality_sni "$stream")"
      [ -n "$sni" ] || sni="$host"
    fi
    # v5.2: direct XHTTP/WS/gRPC тоже нуждаются в path/serviceName; раньше
    # direct-ветка всегда передавала пустые значения, и XHTTP-ссылка была неполной.
    case "$net" in
      ws|xhttp|splithttp|httpupgrade) path="$(inbound_path "$ib" "$net")" ;;
      grpc) svc="$(inbound_path "$ib" grpc)" ;;
      tcp) path="$(inbound_path "$ib" tcp)" ;;
    esac
    _link_proto "$proto" "$email" "$host" "$port" "$net" "$sec" "$path" "$svc" "${sni:-}" "$pbk" "$sid" "" "$flow" "$cl" "$ib"
  fi
}

# внутренний сборщик ссылки по протоколу
_link_proto() { # proto email host port net sec path svc sni pbk sid fp flow client ib
  local proto="$1" email="$2" host="$3" port="$4" net="$5" sec="$6" path="${7:-}" svc="${8:-}"
  local sni="${9:-}" pbk="${10:-}" sid="${11:-}" fp="${12:-}" flow="${13:-}" cl="${14}" ib="${15}"
  local q="" e; e="$(enc_uri "$email")"
  local link=""

  case "$proto" in
    vless)
      local uuid; uuid="$(jq -r '.id // ""' <<<"$cl")"
      [ -n "$uuid" ] || return 0
      q="type=${net}&security=${sec}"
      case "$net" in
        ws)          q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc)        q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
        httpupgrade) q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        tcp)         [ -n "$path" ] && q+="&headerType=http&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
      esac
      if [ "$sec" = "tls" ]; then
        q+="&sni=$(enc_uri "${sni:-$host}")&fp=${fp:-chrome}"
      elif [ "$sec" = "reality" ]; then
        q+="&sni=$(enc_uri "$sni")&fp=${fp:-chrome}&pbk=$(enc_uri "$pbk")"
        [ -n "$sid" ] && q+="&sid=$(enc_uri "$sid")"
        [ -n "$flow" ] && q+="&flow=$(enc_uri "$flow")"
      fi
      link="vless://${uuid}@${host}:${port}?${q}#${e}" ;;

    vmess)
      local uuid tls
      uuid="$(jq -r '.id // ""' <<<"$cl")"; [ -n "$uuid" ] || return 0
      [ "$sec" = "tls" ] && tls="tls" || tls=""
      [ "$net" = "xhttp" ] && net="xhttp"
      local cj
      cj="$(jq -nc --arg ps "$email" --arg add "$host" --arg port "$port" --arg id "$uuid" \
        --arg net "$net" --arg host "$host" --arg path "$path" --arg tls "$tls" --arg sni "${sni:-$host}" \
        --arg svc "$svc" --arg sec "$sec" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",
         host:$host,path:(if $net=="grpc" then $svc else $path end),
         tls:$tls,sni:(if $tls=="tls" then $sni else "" end),
         sn:(if $net=="grpc" then $svc else "" end)}')"
      link="vmess://$(printf '%s' "$cj" | base64 -w0)" ;;

    trojan)
      pass="$(jq -r '.password // .id // ""' <<<"$cl")"; [ -n "$pass" ] || return 0
      q="security=${sec}&type=${net}&sni=$(enc_uri "${sni:-$host}")"
      case "$net" in
        ws)   q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc) q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
      esac
      link="trojan://$(enc_uri "$pass")@${host}:${port}?${q}#${e}" ;;

    shadowsocks)
      # ss живёт прямым портом; клиент ss в 3x-ui: password в клиенте или в settings
      pass="$(jq -r '.password // ""' <<<"$cl")"
      [ -n "$pass" ] || pass="$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")"
      [ -n "$pass" ] || return 0
      method="$(jq -r '.settings|fromjson?|.method // "aes-256-gcm"' <<<"$ib")"
      link="ss://$(printf '%s' "${method}:${pass}" | base64 -w0)@${host}:${port}#${e}" ;;

    *) return 0 ;;
  esac
  printf '%s\n' "$link"
}

#=========================== ПОДПИСКИ =========================================
sub_regen_quiet() { SUB_QUIET=1 sub_regen; }
# flock-обёртка (аудит №5): cron «13 * * * * xkit sub -q» и ручной запуск не должны
# пересекаться — иначе rm -f ${SUBS_DIR}/* + пересборка дают окно 404/битого base64.
# non-blocking: второй процесс тихо пропускает (cron повторит в следующий час).
sub_regen() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  { flock -n 9 || { [ "${SUB_QUIET:-0}" = "1" ] || warn "Подписки уже пересобираются другим процессом — пропуск"; return 0; }
    sub_regen_impl
  } 9>"${XKIT_DIR}/.sub_regen.lock"
}
sub_regen_impl() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  log "Формирую подписки из данных панели..."
  kit_session || return 1
  routes_load

  mkdir -p "$SUBS_DIR"
  # 750 root:www-data (а не 755): содержимое читает только nginx, не все локальные юзеры
  chgrp www-data /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  rm -f "${SUBS_DIR:?}"/* 2>/dev/null
  local idx="${XKIT_DIR}/subs.index"
  : > "$idx"; chmod 600 "$idx"

  local n_links=0 n_subs=0
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local id port proto tag
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"; tag="$(jq -r '.tag // "inbound"' <<<"$ib")"

    # клиенты инбаунда (+ одиночный пользователь для shadowsocks)
    local -a clients=()
    mapfile -t clients < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "$proto" = "shadowsocks" ] && [ "${#clients[@]}" -eq 0 ]; then
      clients=("$(jq -nc --arg p "$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")" --arg t "$tag" '{password:$p,email:$t}')")
    fi
    [ "${#clients[@]}" -gt 0 ] || continue

    local cl
    for cl in "${clients[@]}"; do
      local email subid link
      email="$(jq -r '.email // "user"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] || continue
      n_links=$((n_links+1))
      if [ -n "$subid" ]; then
        printf '%s\n' "$link" >> "${SUBS_DIR}/.acc.${subid}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$subid" "$email" "${tag:0:20}" "$proto" "$port" >> "$idx"
      fi
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  # баз64-файлы по subId
  local acc f subid
  for acc in "${SUBS_DIR}"/.acc.*; do
    [ -e "$acc" ] || break
    subid="${acc##*.acc.}"
    f="${SUBS_DIR}/${subid}"
    sort -u "$acc" | tr '\n' '\n' | base64 -w0 > "$f"
    rm -f "$acc"
    chmod 644 "$f"
    n_subs=$((n_subs+1))
  done

  if [ "${SUB_QUIET:-0}" != "1" ]; then
    ok "Подписки собраны: ссылок $n_links, файлов подписок $n_subs"
    sub_show
  else
    ok "Подписки: ссылок $n_links, файлов $n_subs"
  fi
  return 0
}

# показать URL подписок (по одному на subId)
sub_show() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local idx="${XKIT_DIR}/subs.index"
  [ -s "$idx" ] || { warn "Подписок ещё нет — создайте пользователей (пункты 4-6) и выполните пункт 2"; return 0; }
  local sp; sp="$(sub_path)"
  echo ""
  log "URL подписок (вставить в клиент: v2rayNG / Streisand / Hiddify / v2rayN):"
  awk -F'\t' '{print $1"\t"$2"\t"$3}' "$idx" | sort -u | while IFS=$'\t' read -r subid email tag; do
    printf '  %-18s %-18s https://%s%s%s\n' "${subid:0:18}" "${email}" "$XKIT_HOST" "$sp" "$subid"
  done
  echo ""
  log "Формат: base64-список vless/vmess/trojan/ss ссылок (стандарт v2ray-подписок)"
}

#=========================== ПОЛЬЗОВАТЕЛИ (клиенты) ===========================
list_inbounds_menu() { # показывает нумерованный список, результат в PICK_IB (JSON)
  local i=0 line
  local -a rows=()
  echo ""
  printf '%-3s %-4s %-22s %-9s %-6s %s\n' "#" "ID" "TAG" "PROTO" "PORT" "РЕЖИМ"
  echo "------------------------------------------------------------------------"
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local rid rmode
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    i=$((i+1))
    rows+=("$ib")
    printf '%-3s %-4s %-22s %-9s %-6s %s\n' "$i" "$(jq -r '.id' <<<"$ib")" \
      "$(jq -r '.tag // "inbound"' <<<"$ib" | cut -c1-22)" "$(jq -r '.protocol' <<<"$ib")" \
      "$(jq -r '.port' <<<"$ib")" "$([ "$rmode" = "local" ] && echo "за nginx" || echo "direct")"
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$i" -eq 0 ] && { warn "Активных инбаундов нет — создайте в панели (пункт 2 потом их пробросит)"; return 1; }
  read -r -p "Номер инбаунда [1-$i]: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { err "Нет такого номера"; return 1; }
  PICK_IB="${rows[$((n-1))]}"
  return 0
}

client_add() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  list_inbounds_menu || return 1
  local ib="$PICK_IB"
  local id port proto sec
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"

  local settings email uuid subid total=0 days=0 flow=""
  settings="$(jq -r '.settings' <<<"$ib")"
  jq -e . <<<"$settings" >/dev/null 2>&1 || { err "settings инбаунда #$id не парсятся как JSON — обновите 3x-ui"; return 1; }
  read -r -p "Имя (email) пользователя [u$(rand_hex 2)]: " email
  email="${email:-u$(rand_hex 2)}"
  # таб/перевод строки ломают subs.index (awk -F'\t') — вырезаем; остальное — предупреждение
  email="${email//$'\t'/}"; email="${email//$'\r'/}"; email="${email//$'\n'/}"; email="${email// /}"
  [[ "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] || warn "Имя содержит нестандартные символы — лучше только A-Za-z0-9._@+-"
  read -r -p "Квота трафика, ГБ (0 = без лимита) [0]: " total; total="${total:-0}"
  read -r -p "Срок жизни, дней (0 = бессрочно) [0]: " days; days="${days:-0}"
  if [ "$sec" = "reality" ] && [ "$proto" = "vless" ]; then
    read -r -p "Flow [xtls-rprx-vision]: " flow; flow="${flow:-xtls-rprx-vision}"
  fi
  uuid="$(new_uuid)"
  subid="$(rand_str 16)"

  local expiry=0 gb=0
  [ "$days" -gt 0 ] 2>/dev/null && expiry=$(( $(date +%s) * 1000 + days * 86400000 ))
  [ "$total" -gt 0 ] 2>/dev/null && gb=$(( total * 1073741824 ))

  local cj
  if [ "$proto" = "trojan" ] || [ "$proto" = "shadowsocks" ]; then
    cj="$(jq -nc --arg id "$uuid" --arg pass "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, password:$pass, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  else
    cj="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  fi

  log "Добавляю пользователя через API панели..."
  if ! api_add_client "$id" "$cj" "$settings"; then return 1; fi
  ok "Пользователь '$email' добавлен в инбаунд #$id"

  # свежая ссылка + подписка
  local link
  link="$(link_for_client "$ib" "$cj")"
  [ -n "$link" ] && { echo ""; ok "Ссылка для клиента (или в подписке ниже):"; printf '  %s\n' "$link"; }
  sub_regen_quiet || true
  local sp; sp="$(sub_path)"
  echo ""
  ok "Подписка этого пользователя: https://${XKIT_HOST}${sp}${subid}"
  return 0
}

client_del() {
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
  printf '%-3s %-28s %-38s %s\n' "#" "EMAIL" "UUID/KEY" "SUBID"
  local i=0 cl
  for cl in "${cls[@]}"; do
    i=$((i+1))
    printf '%-3s %-28s %-38s %s\n' "$i" "$(jq -r '.email // "-"' <<<"$cl" | cut -c1-28)" \
      "$(jq -r '.id // .password // "-"' <<<"$cl" | cut -c1-38)" \
      "$(jq -r '.subId // "-"' <<<"$cl" | cut -c1-12)"
  done
  read -r -p "Номер пользователя для удаления [1-$i] (Enter — отмена): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "Отменено"; return 0; }
  [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { warn "Отменено"; return 0; }
  cl="${cls[$((n-1))]}"
  local email cid
  email="$(jq -r '.email // "-"' <<<"$cl")"
  cid="$(jq -r '.id // .password // empty' <<<"$cl")"
  [ -n "$cid" ] || { err "Не найден id клиента"; return 1; }
  read -r -p "Удалить '$email'? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || { warn "Отменено"; return 0; }
  if api_del_client "$id" "$email" "$cid"; then
    ok "Пользователь '$email' удалён"
    sub_regen_quiet || true
  fi
  return 0
}

human_bytes() { # $1 байты -> читаемый вид (IEC; ЕДИНСТВЕННАЯ версия — не переопределять)
  awk -v b="${1:-0}" 'BEGIN{
    split("B KiB MiB GiB TiB",u," "); i=1
    while (b>=1024 && i<5){b/=1024;i++}
    printf (i==1?"%d %s":"%.1f %s"), b, u[i]}'
}
human_expiry() { local ms="$1"; if [ "$ms" -gt 0 ] 2>/dev/null; then date -d @$((ms/1000)) '+%Y-%m-%d' 2>/dev/null; else echo "∞"; fi; }

client_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  echo ""
  local any=0 ib cl rmode
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    local tag proto port
    tag="$(jq -r '.tag // "inbound"' <<<"$ib")"; proto="$(jq -r '.protocol' <<<"$ib")"
    port="$(jq -r '.port' <<<"$ib")"
    echo -e "${GREEN}── ${tag}  (${proto}, порт ${port}, $([ "$rmode" = "local" ] && echo "за nginx" || echo "direct"))${NC}"
    local -a cls=()
    mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "${#cls[@]}" -eq 0 ]; then echo "   (нет клиентов)"; continue; fi
    any=$((any+1))
    printf '   %-26s %-12s %-10s %-11s %s\n' "EMAIL" "QUOTA" "ИСТЕКАЕТ" "ПОДПИСКА" "ТРАФИК (↑+↓)"
    local used
    for cl in "${cls[@]}"; do
      local email subid totalgb exp up down
      email="$(jq -r '.email // "-"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      totalgb="$(jq -r '.totalGB // 0 | (tonumber? // 0)' <<<"$cl")"
      exp="$(jq -r '.expiryTime // 0' <<<"$cl")"
      up=0; down=0
      up="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (.clientStats // []) end)[]? | select(.email==$e) | (.up|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      down="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (.clientStats // []) end)[]? | select(.email==$e) | (.down|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      used="$(human_bytes $((up+down)))"
      printf '   %-26s %-12s %-10s %-11s %s\n' "${email:0:26}" \
        "$([ "${totalgb:-0}" -gt 0 ] 2>/dev/null && human_bytes "$totalgb" || echo "∞")" \
        "$(human_expiry "${exp:-0}")" "$([ -n "$subid" ] && echo "${subid:0:10}" || echo "-")" "$used"
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  echo ""
  sub_show
  return 0
}

#=========================== РУЧНОЙ РЕЛЕЙ-МАРШРУТ =============================
# Проброс пути на ВНЕШНИЙ сервер (Relay): nginx 443 -> https/грpc upstream.
add_relay_route() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo "Транспорт: 1) gRPC  2) WebSocket  3) XHTTP"
  read -r -p "Выбор: " t
  case "$t" in 1) net=grpc ;; 2) net=ws ;; 3) net=xhttp ;; *) die "1-3" ;; esac
  path="$(read_path "Внешний путь (например /relay1/) -> ")"
  [ -n "$path" ] || die "Путь обязателен"
  rh="$(read_host "Внешний сервер (домен/IP backend) -> ")"
  [ -n "$rh" ] || die "Хост обязателен"
  rp=443
  if [ "$net" != "grpc" ]; then
    read -r -p "Порт backend [443]: " rp; rp="${rp:-443}"; is_port "$rp" || die "Порт некорректен"
  fi
  routes_upsert "m$(rand_hex 3)" relay "$net" "$path" "${rh}:${rp}" "manual"
  regen_conf_and_apply || return 1
  ok "Relay-маршрут: $path -> $rh:$rp (TLS до backend, SNI=$rh)"
  warn "Relay-маршруты НЕ попадают в подписки xkit — отдавайте клиенту ссылку вручную"
  return 0
}

#=========================== ПРОВЕРКА ЖИЗНЕСПОСОБНОСТИ ========================
# Что проверяем: сервисы, панель через nginx, серт, каждый маршрут, подписки,
# и главное — ЧТО СВЕТИТСЯ НАРУЖУ (порты на 0.0.0.0/::).
http_code_url() { # $1 url → код или 000
  curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null || printf '000'
}

health_check() {
  load_xkit_env || die "Нет состояния xkit — сначала установка (пункт 1)"
  local fails=0 warns=0 oks=0
  local mark_ok mark_bad mark_warn
  sect() { echo ""; echo -e "${BLUE}── $* ${NC}"; }
  okln()  { echo "  [OK]   $*"; oks=$((oks+1)); }
  warnln(){ echo "  [ВНИМ] $*"; warns=$((warns+1)); }
  badln() { echo "  [СБОЙ] $*"; fails=$((fails+1)); }

  sect "Сервисы"
  for s in nginx x-ui; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then okln "$s: работает"
    else badln "$s: НЕ работает (systemctl status $s)"; fi
  done

  sect "Панель за nginx"
  if read_panel_settings >/dev/null 2>&1; then
    local code
    code="$(http_code_url "https://${XKIT_HOST}${PANEL_WBP}")"
    if [ "$code" != "000" ]; then okln "панель отвечает через nginx (HTTP $code): https://${XKIT_HOST}${PANEL_WBP}"
    else badln "панель недоступна через nginx (${PANEL_WBP})"; fi
    # не слушает ли панель снаружи
    if ss -ltnH 2>/dev/null | awk -v p=":${PANEL_PORT} " 'index($4,p) && $4 !~ /^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\])/' | grep -q .; then
      warnln "порт панели ${PANEL_PORT} слушает НЕ только 127.0.0.1! Выполните: ufw deny ${PANEL_PORT}/tcp"
    else
      okln "порт панели ${PANEL_PORT} наружу не светится (только 127.0.0.1)"
    fi
  else
    badln "не удалось прочитать настройки панели"
  fi

  sect "Сертификат"
  if [ -f "${XKIT_CRT:-}" ]; then
    local end days
    end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2)"
    if [ -n "$end" ]; then
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if [ "$days" -lt 0 ]; then badln "сертификат ПРОСРОЧЕН"
      elif [ "$days" -lt 3 ] && [ "$XKIT_CERT_MODE" = "3" ]; then warnln "IP-серт живёт $days дн. (shortlived, авто-продление включено)"
      elif [ "$days" -lt 14 ]; then warnln "серт истекает через $days дн."
      else okln "серт действителен ещё $days дн. ($end)"; fi
    else badln "не удалось прочитать $XKIT_CRT"; fi
  else badln "сертификат не найден: ${XKIT_CRT:-не задан}"; fi

  sect "Маршруты инбаундов (любой HTTP-код = живой; 000 = труп)"
  routes_load
  if [ "${#ROUTES[@]}" -eq 0 ]; then warnln "маршрутов нет — выполните пункт 2 после создания инбаундов"
  else
    local row r_id r_mode r_net r_path r_target r_tag
    for row in "${ROUTES[@]}"; do
      IFS=$'\t' read -r r_id r_mode r_net r_path r_target r_tag <<<"$row"
      [ "$r_mode" = "local" ] || continue
      local c
      c="$(http_code_url "https://${XKIT_HOST}${r_path}")"
      if [ "$c" = "000" ]; then badln "$r_path -> $r_target: НЕ отвечает"
      else okln "$r_path -> $r_target: живой (HTTP $c)"; fi
    done
  fi

  sect "Подписки"
  local idx="${XKIT_DIR}/subs.index"
  if [ -s "$idx" ]; then
    local first_sub; first_sub="$(awk -F'\t' '{print $1; exit}' "$idx")"
    local sp c2
    sp="$(sub_path)"
    c2="$(http_code_url "https://${XKIT_HOST}${sp}${first_sub}")"
    if [ "$c2" = "200" ]; then okln "подписки раздаются через nginx (HTTP 200)"
    else badln "файл подписки не читается через nginx (HTTP $c2)"; fi
  else warnln "подписок нет (нет пользователей с subId)"; fi

  sect "Что СВЕТИТСЯ НАРУЖУ (слушатели не на 127.0.0.1/::1)"
  local exposed=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;;
      *) continue ;;
    esac
    case "$port" in 80|443) continue ;; esac
    if echo "$proc" | grep -qE "sshd|openssh"; then okln "SSH :$port — нужно для доступа, это нормально"; continue; fi
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if ufw status 2>/dev/null | grep -qE "^${port}/(tcp|udp)[[:space:]]+ALLOW"; then
        warnln "порт ${netid}/${port} ($proc) открыт И в фаерволе — видно снаружи!"
      else
        warnln "порт ${netid}/${port} ($proc) слушает все интерфейсы, но закрыт фаерволом (ufw)"
      fi
    else
      badln "порт ${netid}/${port} ($proc) слушает все интерфейсы, ufw ВЫКЛЮЧЕН — видно снаружи!"
    fi
    exposed=$((exposed+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$exposed" -eq 0 ] && okln "лишних слушателей нет — наружу только 80/443 (+SSH)"

  sect "DNS (для домена)"
  if [ "$(host_kind "$XKIT_HOST")" = "domain" ]; then
    local myip dnsip
    myip="$(pubip)"
    dnsip="$(getent hosts "$XKIT_HOST" 2>/dev/null | awk '{print $1; exit}')"
    if [ -n "$myip" ] && [ -n "$dnsip" ]; then
      if [ "$myip" = "$dnsip" ]; then okln "$XKIT_HOST -> $dnsip (верно)"
      else badln "$XKIT_HOST -> $dnsip, а IP сервера $myip — исправьте A-запись!"; fi
    else warnln "не удалось проверить DNS (нет сети?)"
    fi
  else okln "$XKIT_HOST — IP-режим"; fi

  sect "Итог"
  echo "  OK: $oks | предупреждений: $warns | сбоев: $fails"
  [ "$fails" -eq 0 ] && ok "Всё живо" || err "Есть сбои — см. строки [СБОЙ] выше"
  return 0
}

#=========================== БЭКАПЫ ===========================================
backup_now() {
  load_xkit_env || true
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local f="$BACKUP_DIR/xkit-$(date +%Y%m%d-%H%M%S).tar.gz"
  local -a paths=()
  [ -d "$XKIT_DIR" ] && paths+=("$XKIT_DIR")
  [ -f "$XKIT_CONF" ] && paths+=("$XKIT_CONF")
  [ -d "$SUBS_DIR" ] && paths+=("$SUBS_DIR")
  [ -f "$XUI_RESULT" ] && paths+=("$XUI_RESULT")
  [ -f "$XUI_DB" ] && paths+=("$XUI_DB")
  [ -d /etc/nginx/ssl ] && paths+=("/etc/nginx/ssl")
  [ -d /etc/letsencrypt ] && paths+=("/etc/letsencrypt")
  # v5.2: отдельные службы протоколов тоже входят в аварийный архив.
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null && paths+=("/etc/amnezia/amneziawg/awg0.conf")
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && paths+=("/etc/systemd/system/xkit-hysteria2.service")
  [ -f /etc/sysctl.d/99-xkit-awg.conf ] && paths+=("/etc/sysctl.d/99-xkit-awg.conf")
  [ "${#paths[@]}" -eq 0 ] && { warn "Нечего бэкапить"; return 1; }
  # БД панели в PostgreSQL tar'ом не забрать — честно предупреждаем
  if [ -f "$XUI_RESULT" ] && grep -q "XUI_DB_TYPE=postgres" "$XUI_RESULT" 2>/dev/null; then
    warn "БД панели — PostgreSQL: файл x-ui.db в бэкап НЕ попадёт. Бэкап панели делайте в самой панели (Panel Settings -> Backup)."
    local -a kept=() pth
    for pth in "${paths[@]}"; do [ "$pth" = "$XUI_DB" ] || kept+=("$pth"); done
    paths=("${kept[@]}")
  fi
  tar czf "$f" -C / "${paths[@]}" 2>/dev/null || { err "tar не смог собрать бэкап"; return 1; }
  chmod 600 "$f"
  find "$BACKUP_DIR" -name 'xkit-*.tar.gz' -mtime +13 -delete 2>/dev/null
  ok "Бэкап: $f ($(du -h "$f" 2>/dev/null | cut -f1)); храним 14 дней"
  return 0
}

backup_cron_install() {
  cat > "$XKIT_CRON_MAIN" <<EOF
# XKIT: авто-бэкап раз в сутки + перегенерация подписок каждый час
17 3 * * * root ${XKIT_BIN} backup >/dev/null 2>&1
13 * * * * root ${XKIT_BIN} sub -q >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_MAIN"
  ok "Cron: бэкап ежедневно 03:17, подписки перегенерируются ежечасно"
}

backup_restore() {
  local file="${1:-}"
  [ -z "$file" ] && file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] && [ -f "$file" ] || die "Бэкапы не найдены в $BACKUP_DIR"
  # V-06 (аудит №2): чужой бэкап = root RCE через содержимое. Вне BACKUP_DIR —
  # только через явное YES (или XKIT_ALLOW_UNTRUSTED_BACKUP=1)
  case "$(readlink -f -- "$file" 2>/dev/null || echo "$file")" in
    "$BACKUP_DIR"/*) ;;
    *)
      if [ "${XKIT_ALLOW_UNTRUSTED_BACKUP:-0}" != "1" ]; then
        warn "Файл вне ${BACKUP_DIR}: $(basename -- "$file")"
        local a; read -r -p "Чужой бэкап может выполнить команды от root. Точно восстановить? Введите YES: " a || { echo; return 1; }
        [ "$a" = "YES" ] || { log "Отменено"; return 0; }
      fi
      ;;
  esac
  log "Восстанавливаю из: $file"
  # V-06: члены архива — без ../ и абсолютных путей (проверка ДО распаковки)
  if tar -tzf "$file" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    err "Архив содержит небезопасные пути (../ или абсолютные) — восстановление отменено"
    return 1
  fi
  local t; t="$(mktemp -d)"
  tar xzf "$file" -C "$t" || { err "Архив битый"; rm -rf "$t"; return 1; }
  # V-06: symlink-члены не должны указывать наружу (легитимные внутренние — можно)
  local badlink
  badlink="$(find "$t" -type l 2>/dev/null | while read -r l; do
    lt="$(readlink -f "$l" 2>/dev/null || true)"
    case "$lt" in "$t"|"$t"/*) ;; *) echo "$l"; break ;; esac
  done)"
  if [ -n "$badlink" ]; then
    err "Архив содержит symlink наружу (${badlink#"$t"/}) — восстановление отменено (V-06)"
    rm -rf "$t"; return 1
  fi
  # V-06: xkit.env из архива НЕ исполняем вслепую — командная подстановка = отказ
  if [ -f "$t${XKIT_ENV}" ] && grep -qE '`|\$\(|\$\{' "$t${XKIT_ENV}" 2>/dev/null; then
    err "xkit.env в архиве содержит командную подстановку — восстановление отменено (V-06)"
    rm -rf "$t"; return 1
  fi

  systemctl stop x-ui 2>/dev/null || true
  if [ -f "$t${XUI_DB}" ]; then
    backup_file "$XUI_DB" >/dev/null
    cp "$t${XUI_DB}" "$XUI_DB" && ok "БД панели восстановлена"
  fi
  if [ -f "$t$XKIT_CONF" ]; then
    backup_file "$XKIT_CONF" >/dev/null
    cp "$t$XKIT_CONF" "$XKIT_CONF"; chmod 644 "$XKIT_CONF"
    ln -sf "$XKIT_CONF" "$XKIT_CONF_LINK"
    ok "Конфиг nginx восстановлен"
  fi
  if [ -d "$t$XKIT_DIR" ]; then
    backup_file "$XKIT_ENV" >/dev/null
    cp -a "$t$XKIT_DIR/." "$XKIT_DIR/" 2>/dev/null && ok "Состояние xkit восстановлено"
  fi
  if [ -d "$t$SUBS_DIR" ]; then
    cp -a "$t$SUBS_DIR/." "$SUBS_DIR/" 2>/dev/null && ok "Файлы подписок восстановлены"
  fi
  # v5.2: конфиги отдельных протоколов; бинарники в tar не хранятся.
  local rp
  for rp in /etc/amnezia/amneziawg/awg0.conf /etc/systemd/system/xkit-hysteria2.service /etc/sysctl.d/99-xkit-awg.conf; do
    if [ -f "$t$rp" ]; then mkdir -p "$(dirname "$rp")"; cp -f "$t$rp" "$rp"; fi
  done
  rm -rf "$t"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && systemctl enable --now xkit-hysteria2 >/dev/null 2>&1 || true
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || true

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    ok "Nginx перезагружен"
  else
    err "nginx -t не прошёл после восстановления — проверьте конфиг"
  fi
  systemctl start x-ui 2>/dev/null || true
  sleep 2
  load_xkit_env || true
  if read_panel_settings >/dev/null 2>&1 && detect_panel_scheme "$PANEL_PORT" >/dev/null; then
    COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
    if kit_login; then ok "Панель снова отвечает на логин"
    else warn "Панель запущена, но логин не прошёл — проверьте креды"; fi
  fi
  return 0
}

#=========================== СТАТУС: ЧТО ВИДНО СНАРУЖИ ========================
show_status() {
  load_xkit_env || die "Нет состояния — сначала установка"
  echo ""
  echo -e "${GREEN}==== XKIT v${XKIT_VERSION}: ${XKIT_HOST} ====${NC}"
  echo "  Панель:  https://${XKIT_HOST}$(read_panel_settings >/dev/null 2>&1 && echo "${PANEL_WBP}")"
  echo "  Подписки: https://${XKIT_HOST}$(sub_path)<subId>"
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
    echo "  Дашборд: https://${XKIT_HOST}$(dash_path) (данные: cron каждые 5 мин)"
  fi
  # v4.5: явный режим — «мастер» это состояние (nodes.json не пуст), а не отдельная установка
  local ncnt; ncnt="$(nodes_load 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "$ncnt" -gt 0 ]; then
    echo "  Режим:   мастер (${ncnt} нод; балансировка ${XKIT_BAL_STRATEGY:-roundRobin})"
  else
    echo "  Режим:   одиночный сервер (ноды не подключены)"
  fi
  echo ""
  echo "  Сервисы:  nginx=$(systemctl is-active nginx 2>/dev/null)  x-ui=$(systemctl is-active x-ui 2>/dev/null)  ufw=$(ufw status 2>/dev/null | sed -n 's/Status: //p')"
  echo ""
  echo "  Слушатели, видимые снаружи (0.0.0.0/::):"
  local found=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;; *) continue ;; esac
    echo "    ${netid}/${port}  ${proc:-?}"
    found=$((found+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$found" -eq 0 ] && echo "    (нет)"
  echo ""
  echo "  Локальные (127.0.0.1 — снаружи НЕ видны):"
  ss -tlnpH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1/ {print "    "$4"  "$7}' | head -n 20
  echo ""
  routes_load
  echo "  Маршруты за nginx: ${#ROUTES[@]}"
  local row
  for row in "${ROUTES[@]}"; do
    IFS=$'\t' read -r _ r_mode r_net r_path r_target _ <<<"$row"
    echo "    $r_path -> $r_target [$r_mode/$r_net]"
  done
  return 0
}

#=========================== УСТАНОВКА ОДНИМ ШАГОМ ============================
setup_ufw() {
  command -v ufw >/dev/null 2>&1 || { warn "ufw не найден — пропускаю настройку фаервола"; return 0; }
  if ufw status 2>/dev/null | head -n1 | grep -q "inactive"; then
    local ssh_port a
    # S-03 (аудит №2): порт SSH из sshd -T/sshd_config, НЕ из ss-парсинга;
    # не определили — UFW НЕ включаем (fallback на 22 = lockout при нестандартном порте)
    ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [ -n "$ssh_port" ] || ssh_port="$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
    [ -n "$ssh_port" ] || ssh_port="$(ss -tlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]; exit}')"
    if [ -n "$ssh_port" ] && ! is_port "$ssh_port"; then ssh_port=""; fi
    if [ -z "$ssh_port" ]; then
      if [ -t 0 ]; then
        read -r -p "Не смог определить порт SSH. Укажите его вручную (Enter — пропустить ufw): " ssh_port || ssh_port=""
      fi
      is_port "${ssh_port:-}" 2>/dev/null || ssh_port=""
    fi
    if [ -z "$ssh_port" ]; then
      warn "Порт SSH не определён — UFW НЕ включаю (риск заблокировать себя). Вручную: ufw allow <порт>/tcp && ufw enable"
      return 0
    fi
    read -r -p "Включить ufw (наружу останутся только SSH ${ssh_port}, 80, 443)? [Y/n]: " a || a=""
    if [[ "$a" =~ ^[Nn] ]]; then
      warn "UFW не включён — панель/инбаунды на 127.0.0.1 всё равно не видны, но проверьте открытые порты сами"
      return 0
    fi
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1
    ufw allow 80/tcp  >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 && ok "UFW включён: наружу только SSH ${ssh_port}, 80, 443"
    XKIT_UFW=1
  else
    ok "UFW уже активен"
    XKIT_UFW=1
  fi
  return 0
}

#=========================== PREFLIGHT (v4.7) ==================================
# Проверки ДО каких-либо изменений: уже установлен / порты / диск / RAM / сеть.
# Раньше повторный `xkit install` молча ставил поверх: env не загружался ->
# НОВЫЙ SUB_TOKEN (все ссылки подписок у клиентов отваливались) + save_xkit_env
# затирал TG/dash-токены нулями. Теперь — явный выбор.
preflight_installed_menu() { # 0 = продолжать установку поверх, 1 = стоп
  local a
  echo ""
  warn "xkit уже установлен: ${XKIT_ENV}"
  echo "  1) Обновить скрипт (xkit update) — состояние/ноды/подписки НЕ трогаются"
  echo "  2) Чистая переустановка: бэкап -> полное удаление -> установка с нуля"
  echo "  3) Починить поверх: пакеты/панель/конфиг заново, состояние сохраняется"
  echo "  0) Выход"
  read -r -p "Выбор [0]: " a || { echo; return 1; }   # EOF (cron/pipe) — безопасный выход
  case "${a:-0}" in
    1) xkit_self_update; return 1 ;;
    2) xkit_reinstall; return 1 ;;
    3) warn "Починка поверх: пакеты/панель/конфиг переустановятся, текущее состояние"
       warn "(адрес, путь подписок, Telegram, дашборд) СОХРАНИТСЯ и подхватится."
       confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
       return 0 ;;
    *) log "Выход без изменений"; return 1 ;;
  esac
}

preflight() { # 0 = можно ставить, 1 = стоп
  # 1) уже установленный xkit: спросить, а не молча перезаписать
  if [ -f "$XKIT_ENV" ]; then
    if [ "${XKIT_FORCE:-0}" = "1" ]; then
      warn "XKIT_FORCE=1: ставлю поверх существующей установки (SUB_TOKEN/TG/dash слетят)"
    else
      preflight_installed_menu || return 1
    fi
  fi

  # 2) порты 80/443 (важно ДО certbot): nginx-оккупант будет перенастроен сам,
  #    чужой процесс (apache/другой vpn) — предупреждение с именем процесса
  local warns=0 p line
  if command -v ss >/dev/null 2>&1; then
    for p in 80 443; do
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if printf '%s' "$line" | grep -q nginx; then
          log "Порт ${p} уже слушает nginx — xkit перенастроит его сайт"
        else
          warn "Порт ${p} занят: ${line}"
          warns=$((warns+1))
        fi
      done < <(ss -ltnpH "sport = :${p}" 2>/dev/null)
    done
  fi

  # 3) диск: certbot + БД + бэкапы не живут на <500 MB
  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 500 ] 2>/dev/null; then
    err "Свободно ${avail_mb} MB на / — нужно >=500 MB (сертификаты, БД панели, бэкапы)"
    return 1
  fi

  # 4) RAM: x-ui + nginx + certbot на 512 MB впритык
  local mem_mb
  mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 400 ] 2>/dev/null; then
    warn "RAM ${mem_mb} MB — x-ui/nginx/certbot могут упасть по OOM (рекомендую >=512 MB)"
    warns=$((warns+1))
  fi

  # 5) сеть: без этих хостов установка не пройдёт (3X-UI качается с github)
  local u
  for u in https://raw.githubusercontent.com https://api.ipify.org; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 3 -o /dev/null "$u" 2>/dev/null || { warn "Нет доступа к ${u} — часть установки может не пройти"; warns=$((warns+1)); }
    fi
  done

  if [ "$warns" -gt 0 ]; then
    confirm "Продолжить несмотря на предупреждения? [y/N]: " n || { log "Отменено"; return 1; }
  fi
  return 0
}

#=========================== УДАЛЕНИЕ / ПЕРЕУСТАНОВКА =========================
# xkit_uninstall [--full]: бэкап ОБЯЗАТЕЛЕН (провал = отмена), затем чистая
# зачистка следов кита. --full дополнительно удаляет 3X-UI и /etc/nginx/ssl.
# НИКОГДА не удаляются: бэкапы ($BACKUP_DIR), /etc/letsencrypt, сам nginx и
# чужие сайты, UFW-правила 22/80/443. Ноды (xray на них) не трогаются.
# KEEP_BIN=1 — внутренний флаг reinstall: не удалять $XKIT_BIN (running-скрипт).
xkit_uninstall() {
  local full=0
  [ "${1:-}" = "--full" ] && full=1
  require_root
  load_xkit_env 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}============================================================${NC}"
  warn "УДАЛЕНИЕ XKIT С ЭТОГО СЕРВЕРА"
  echo -e "${YELLOW}============================================================${NC}"
  echo "Удаляется:   cron-задачи xkit (3 шт), nginx-сайт xkit.conf (+reload nginx),"
  echo "             /etc/xkit (состояние, SSH-ключи нод, expiry, алерты),"
  echo "             /var/lib/xkit (подписки, дашборд), htpasswd дашборда,"
  echo "             deny-правило UFW для порта панели, /usr/local/bin/xkit"
  [ "$full" = "1" ] && echo "             + --full: 3X-UI (сервис, /etc/x-ui, /usr/local/x-ui, CLI), /etc/nginx/ssl"
  echo "Сохраняется: бэкапы $BACKUP_DIR (включая свежий, 14 дней), /etc/letsencrypt,"
  echo "             nginx и другие сайты, UFW-правила SSH/80/443"
  echo "Ноды продолжат работать автономно — xray на них не трогаем."

  log "Сначала бэкап — без него удаление не состоится..."
  backup_now || { err "Бэкап не удался — удаление отменено (безопасность)"; return 1; }

  if [ "${XKIT_YES:-0}" != "1" ]; then
    local a
    read -r -p "Удалить xkit? Введите YES: " a || { echo; log "Отменено"; return 1; }
    [ "$a" = "YES" ] || { log "Отменено"; return 1; }
  fi

  xkit_log_begin uninstall
  xkit_install_traps_on

  rm -f "$XKIT_CRON_MAIN" "$XKIT_CRON_DASH" "$XKIT_CRON_NOTIFY" 2>/dev/null
  ok "Cron-задачи xkit удалены"

  if [ -e "$XKIT_CONF" ] || [ -L "$XKIT_CONF_LINK" ]; then
    rm -f "$XKIT_CONF" "$XKIT_CONF_LINK" "$XKIT_DASH_HTPASSWD" 2>/dev/null
    if command -v nginx >/dev/null 2>&1; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
        ok "nginx-сайт xkit.conf удалён, nginx перезагружен"
      else
        err "После удаления xkit.conf nginx -t не проходит — проверьте /etc/nginx вручную"
      fi
    else
      ok "nginx-сайт xkit.conf удалён"
    fi
  else
    log "nginx-сайт xkit.conf не найден — пропускаю"
  fi

  # deny порта панели — xkit-специфичное правило; allow 22/80/443 не трогаем:
  # удалить allow 22 = потерять SSH, allow 80/443 безвредны и стандартны
  if [ -n "${PANEL_PORT:-}" ] && command -v ufw >/dev/null 2>&1; then
    ufw delete deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  # v5.2: отдельные службы протоколов. Чужой awg0 без метки XKIT не трогаем.
  systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xkit-hysteria2.service /usr/local/bin/xkit-hysteria2
  if [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then
    systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f /etc/amnezia/amneziawg/awg0.conf /etc/sysctl.d/99-xkit-awg.conf
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # файлы состояния: /etc/xkit, подписки, дашборд и стандартная база /var/lib/xkit
  # (SUBS_DIR/XKIT_DASH_DIR — переменные, удаляем явно; /var/lib/xkit — база по
  # умолчанию, сносит остатки старых версий, если пути переопределены)
  rm -rf "$XKIT_DIR" "$SUBS_DIR" "$XKIT_DASH_DIR" /var/lib/xkit 2>/dev/null
  rm -f "$XKIT_INFO_FILE" 2>/dev/null
  ok "Файлы xkit удалены ($XKIT_DIR, $SUBS_DIR, $XKIT_DASH_DIR)"

  if [ "$full" = "1" ]; then
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/x-ui.service /usr/local/bin/x-ui 2>/dev/null
    rm -rf /etc/systemd/system/x-ui.service.d /etc/x-ui /usr/local/x-ui /etc/nginx/ssl 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed x-ui >/dev/null 2>&1 || true   # не оставляем failed-огрызок в systemctl
    ok "3X-UI и /etc/nginx/ssl удалены (--full)"
  fi

  if [ "${KEEP_BIN:-0}" != "1" ]; then
    [ -f "$XKIT_BIN" ] && rm -f "$XKIT_BIN" && ok "Команда xkit удалена"
    [ -d "$XKIT_MENU_DIR" ] && rm -rf "$XKIT_MENU_DIR" && ok "Модуль меню удалён ($XKIT_MENU_DIR)"
  fi

  xkit_install_traps_off
  ok "ГОТОВО. Свежий бэкап лежит в $BACKUP_DIR (хранится 14 дней)"
  log "Вернуть данные: install.sh -> xkit restore (инбаунды/клиенты панели, маршруты)"
  return 0
}

# Чистая переустановка: бэкап -> uninstall --full -> one_step_install.
# Бинарник сохраняем (KEEP_BIN=1): one_step_install сам обновит его в конце
# (bash держит fd открытого скрипта, но $0 после rm недоступен для cp)
xkit_reinstall() {
  require_root
  echo ""
  warn "ЧИСТАЯ ПЕРЕУСТАНОВКА: бэкап -> полное удаление (включая панель 3X-UI) -> установка с нуля."
  warn "Инбаунды/клиенты панели будут потеряны (останутся в бэкапе), подписки пересоздадутся."
  confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
  # имя лога — строго по reinstall, даже если нас вызвали из процесса,
  # где XKIT_LOG уже открыт (напр. preflight-меню поверх one_step_install)
  XKIT_LOG=""
  xkit_log_begin reinstall
  KEEP_BIN=1 xkit_uninstall --full || { err "Переустановка прервана: удаление не удалось"; return 1; }
  # Вложенный one_step_install — намеренно: preflight увидит, что $XKIT_ENV
  # уже удалён, меню не покажет; вложенный xkit_log_begin переиспользует
  # общий лог без очистки (внешний вызов после `return 1` не выполняется).
  one_step_install   # $XKIT_ENV уже удалён — preflight пропустит меню, лог общий
}

one_step_install() {
  require_root
  check_os
  preflight || return 1
  # ветка «поверх» (или XKIT_FORCE): подхватываем текущее состояние — прежний
  # адрес, SUB_TOKEN (ссылки подписок у клиентов НЕ меняются), TG/dash-токены.
  # При чистой установке/reinstall env отсутствует — load вернёт 1, не страшно
  load_xkit_env 2>/dev/null || true
  xkit_log_begin install
  xkit_install_traps_on
  STEP=0

  step "Пакеты (nginx, certbot, jq, sqlite3, openssl, ufw, python3)"
  with_spinner "apt-get update..." apt-get update -qq || warn "apt-get update вернул ошибку — продолжаю"
  with_spinner "Установка пакетов..." env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq nginx curl certbot openssl jq sqlite3 ufw cron python3 \
    python3-venv python3-pip \
    || die "Не удалось установить пакеты — подробности в $XKIT_LOG"
  # ревью v4.9.0 (живая установка): в репо Ubuntu 24.04 certbot 2.9 без --ip-address.
  # Раньше это всплывало вопросом посреди установки и могло её оборвать — теперь
  # обновляем СРАЗУ (pip/venv), до вопросов про адрес/серт; не вышло — не фатально,
  # issue_cert_le_ip повторит попытку и меню серта предложит пункт 4
  if ! certbot_supports_ip; then
    log "certbot $(certbot_version) старый — обновляю до актуального (нужен >= ${CERTBOT_MIN_IP} для IP-сертификатов)..."
    if with_spinner "Обновление certbot (pip/venv, 1-2 мин)..." certbot_upgrade; then
      ok "certbot обновлён: $(certbot_version)"
    else
      warn "certbot обновить не удалось — IP-сертификаты будут недоступны (возьмите самоподписанный)"
    fi
  fi

  step "Домен/IP и SSL-сертификат"
  if [ -n "${XKIT_HOST:-}" ]; then
    read -r -p "Использовать прежний адрес ${XKIT_HOST}? [Y/n]: " a
    if [[ "$a" =~ ^[Nn] ]]; then XKIT_HOST=""; fi
  fi
  if [ -z "${XKIT_HOST:-}" ]; then
    choose_host "Адрес этого сервера (для сертификата и ссылок)"
    XKIT_HOST="$CHOSEN_HOST"
  fi
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  [ "$HOST_KIND" != "bad" ] || die "Адрес не распознан"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"

  step "Установка панели 3X-UI (официальный инсталлятор, неинтерактивно)"
  install_3xui_auto || return 1
  read_panel_settings || return 1
  # №17 (аудит): XUI_NONINTERACTIVE зависит от версии инсталлятора 3X-UI — если
  # пароль в install-result.env не попал, пункт 3 (логин в панель) не пройдёт
  if [ -z "$PANEL_PASS" ]; then
    warn "Пароль панели не извлечён из install-result.env (версия установщика 3X-UI?)"
    warn "Задайте вручную:  x-ui setting -username admin -password ВАШ_ПАРОЛЬ  — затем продолжайте"
  fi
  PANEL_SCHEME="$(with_spinner -o "Определяю схему панели (http/https)..." detect_panel_scheme "$PANEL_PORT")" || PANEL_SCHEME="http"
  ok "Панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP} (upstream ${PANEL_SCHEME})"

  log "Прибиваю панель к 127.0.0.1 (webListen), чтобы порт не светился..."
  if with_spinner "webListen -> 127.0.0.1..." force_panel_localhost "$PANEL_PORT"; then
    ok "Панель слушает только 127.0.0.1:${PANEL_PORT}"
  else
    warn "Не удалось включить webListen через БД (postgres или другая схема)"
    warn "Порт панели закрою фаерволом (ufw deny) — см. шаг фаервола"
  fi
  read_panel_settings >/dev/null 2>&1 || true

  step "Секретный путь подписок + состояние xkit"
  if [ -z "${XKIT_SUB_TOKEN:-}" ]; then XKIT_SUB_TOKEN="$(rand_str 16)"; fi
  touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"
  save_xkit_env

  step "Конфиг nginx (панель + подписки), перезапуск"
  regen_conf_and_apply || return 1
  systemctl enable nginx >/dev/null 2>&1 || true

  step "Фаервол"
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели ${PANEL_PORT} закрыт снаружи (страховка)"
  fi
  save_xkit_env

  step "Бэкапы по cron + команда xkit"
  backup_cron_install
  if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$XKIT_BIN" ]; then
    cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN" \
      && ok "Меню установлено: введите в SSH команду xkit"
  fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  ok "ГОТОВО. Наружу смотрит только nginx: 80 (redirect) + 443 (TLS)."
  ok "Панель:  https://${XKIT_HOST}${PANEL_WBP}"
  [ -n "$PANEL_USER" ] && ok "Логин:   ${PANEL_USER}   Пароль: ${PANEL_PASS}"
  ok "Креды также в ${XUI_RESULT} (chmod 600)"
  echo ""
  log "Дальше:"
  log "  1) Зайдите в панель, создайте инбаунд: Listen IP = 127.0.0.1, порт любой"
  log "  2) Введите xkit -> пункт 2 — он сам всё пробросит за nginx и сделает подписки"
  log "  3) Проверка: xkit -> пункт 7 (жизнеспособность и «что светится»)"
  [ "$CERT_MODE" = "3" ] && warn "IP-серт живёт 6 дней — продление настроено (certbot.timer)"
  [ "$CERT_MODE" = "4" ] && warn "Самоподписанный серт: на клиентах allowInsecure=true"
  echo -e "${GREEN}============================================================${NC}"

  # v4.5: развилка «что дальше» вместо одного вопроса про автопроброс.
  # Вариант «мастер» = автопроброс + добавление нод (node_add требует
  # живой nginx и панель, поэтому автопроброс всегда идёт первым).
  # XKIT_YES=1 (CI/cloud-init): без вопросов — «сделаю позже сам»
  echo ""
  log "Что дальше?"
  echo "  1) Одиночный сервер — автопроброс инбаундов за nginx (по умолчанию)"
  echo "  2) Мастер с нодами — автопроброс, затем добавить зарубежные ноды"
  echo "  3) Ничего — сделаю позже сам (xkit route / xkit nodes)"
  if [ "${XKIT_YES:-0}" = "1" ]; then
    a="3"
  else
    read -r -p "Выбор [1]: " a || a=""
  fi
  case "${a:-1}" in
    1|"") auto_route ;;
    2) auto_route || warn "Автопроброс не прошёл — ноды можно добавить позже (xkit nodes)"
       echo ""
       log "Добавление нод (мастер-режим)..."
       nodes_menu ;;
    3) : ;;
    *) warn "Нет такого пункта — позже: xkit route (проброс) или xkit nodes (ноды)" ;;
  esac

  echo ""
  xkit_info   # вся сводка в терминал + /root/xkit-info.txt (chmod 600)
  xkit_install_traps_off
  [ -n "${XKIT_LOG:-}" ] && log "Полный лог установки: ${XKIT_LOG}"
  return 0
}

# спрятать УЖЕ установленную панель (без переустановки всего)
hide_existing_panel() {
  require_root
  command -v x-ui >/dev/null 2>&1 || die "3X-UI не установлен (команда x-ui не найдена)"
  read_panel_settings || return 1
  ok "Найдена панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP}"

  echo ""
  choose_host "Адрес этого сервера (для nginx)"
  XKIT_HOST="$CHOSEN_HOST"
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"
  [ -z "${XKIT_SUB_TOKEN:-}" ] && XKIT_SUB_TOKEN="$(rand_str 16)"
  touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"

  if force_panel_localhost "$PANEL_PORT"; then
    ok "Панель прибита к 127.0.0.1"
    read_panel_settings >/dev/null 2>&1 || true
  fi
  save_xkit_env
  regen_conf_and_apply || return 1
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели закрыт снаружи"
  fi
  save_xkit_env
  if [ -f "$0" ]; then cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN"; fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  ok "Панель доступна ТОЛЬКО через: https://${XKIT_HOST}${PANEL_WBP}"
  log "Дальше: инбаунды с Listen IP = 127.0.0.1, затем пункт 2 (автопроброс)"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

#=========================== v4.1: API-РАСШИРЕНИЯ =============================
api_get_raw() {
  local url; url="$(api_url)$1"
  local -a a=(-s --max-time 10 -b "$COOKIE_JAR")
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  curl "${a[@]}" "$url"
}

api_post_raw() { # $1 путь, остальные — аргументы curl (--data-urlencode k=v ...)
  local p="$1"; shift
  local url; url="$(api_url)${p#/}"
  local -a a=(-s --max-time 20 -b "$COOKIE_JAR" -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  [ -n "$CSRF_TOKEN" ] && a+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  curl "${a[@]}" "$url" "$@"
}

# v4.9.1: в 3X-UI v3 externalProxy у инбаунда ВЫВЕДЕН — вместо него host-группы
# /panel/api/hosts ( remark "xkit", адрес+порт+security). Апдейт по groupId, если
# группа уже есть — без дублей при повторном запуске.
v3_host_upsert() { # $1 id инбаунда, $2 адрес, $3 порт, $4 security (tls|same|reality)
  local id="$1" addr="$2" eport="$3" sec="$4" resp gid body
  body="$(jq -nc --argjson ids "[${id}]" --arg a "$addr" --argjson p "$eport" --arg s "$sec" \
    '{inboundIds:$ids, remark:"xkit", hosts:[$a], port:$p, security:$s}')"
  resp="$(api_get_raw "panel/api/hosts/list" 2>/dev/null || true)"
  # №18 (аудит №1): нестандартный ответ (строка/массив вместо объекта) —
  # поиск groupId молча не найдёт группу => hosts/add создаст ДУБЛЬ. Честно предупредить
  if [ -n "$resp" ] && ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then
    warn "hosts/list: нестандартный ответ панели — возможен дубль host-группы (проверьте панель)"
  fi
  gid="$(jq -r --argjson id "$id" \
    '[.obj[]? | select(((.inboundIds // []) | index($id)) and ((.remark // "") == "xkit"))][0].groupId // empty' \
    <<<"$resp" 2>/dev/null || true)"
  if [ -n "$gid" ]; then
    resp="$(api_post_json "panel/api/hosts/update/${gid}" "$body")"
  else
    resp="$(api_post_json "panel/api/hosts/add" "$body")"
  fi
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1
}

panel_settings_get() {
  local out
  if [ "$API_V3" = "1" ]; then
    # v3: /panel/api/setting/all только POST (и возвращает browser-safe view:
    # секреты скрыты, но sub*/xray-поля на месте)
    out="$(api_post_json "panel/api/setting/all" "{}")"
  else
    out="$(api_get_raw "panel/setting/all")"
    if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      out="$(api_post_raw "panel/setting/all")"
    fi
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "panel settings: $(jq -r '.msg // "нет ответа"' <<<"$out" 2>/dev/null | head -c 200)"
    return 1
  fi
  printf '%s' "$out"
}

panel_settings_set() { # пары key=value (form-urlencoded, панель обновит только их)
  local -a args=()
  local kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  local resp p
  if [ "$API_V3" = "1" ]; then p="panel/api/setting/update"; else p="panel/setting/update"; fi
  resp="$(api_post_raw "$p" "${args[@]}")"
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "${p}: $(jq -r '.msg // "нет ответа"' <<<"$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

panel_restart() {
  local p out
  # v3: /panel/api/setting/restartPanel; v2: panel/setting/restartPanel, server/restartPanel
  for p in "panel/api/setting/restartPanel" "panel/setting/restartPanel" "server/restartPanel"; do
    out="$(api_post_raw "$p")" || true
    if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      ok "Панель перезапускается..."
      sleep 3
      kit_login >/dev/null 2>&1 || true
      return 0
    fi
  done
  warn "Перезапуск панели через API не удался (можно вручную: x-ui restart panel)"
  return 1
}

xray_restart() {
  if api_post_raw "panel/api/server/restartXrayService" >/dev/null 2>&1; then
    ok "Xray перезапущен"
  else
    warn "Не удалось перезапустить xray через API"
  fi
  return 0
}

api_add_inbound() { # $1 полный JSON инбаунда
  local resp
  resp="$(api_post add "$1")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "add inbound: $(jq -r '.msg // "ошибка"' <<<"$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# пара ключей x25519 "private public" (API панели, фолбэк — локальный xray)
api_get_new_x25519() {
  local out priv pub xr pair
  out="$(api_get_raw "panel/api/server/getNewX25519Cert")"
  priv="$(jq -r '.obj.privateKey // .obj.private_key // empty' <<<"$out" 2>/dev/null)"
  pub="$(jq -r '.obj.publicKey // .obj.public_key // empty' <<<"$out" 2>/dev/null)"
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    xr="$(ls -1 /usr/local/x-ui/bin/xray-* 2>/dev/null | head -n1)"
    [ -n "$xr" ] || { err "Не могу сгенерировать x25519 (нет API и нет бинарника xray)"; return 1; }
    pair="$("$xr" x25519 2>/dev/null)" || { err "xray x25519 не сработал"; return 1; }
    priv="$(awk '/Private/{print $NF}' <<<"$pair")"
    pub="$(awk '/Public/{print $NF}' <<<"$pair")"
  fi
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  printf '%s %s\n' "$priv" "$pub"
}

#=========================== v4.1: ПОДПИСКИ САМОЙ ПАНЕЛИ ======================
# Нативный sub-сервис 3X-UI вешаем на 127.0.0.1:ПОРТ и проксируем через nginx.
# В панели при этом корректный URL: https://ДОМЕН/sub-<token>/<subId>
ensure_panel_sub_settings() {
  local all cur_port cur_path
  all="$(panel_settings_get)" || return 1
  cur_port="$(jq -r '.obj.subPort // ""' <<<"$all")"
  cur_path="$(jq -r '.obj.subPath // ""' <<<"$all")"

  if [ -z "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "$cur_port" ] && is_port "$cur_port" && [ "$cur_port" != "0" ]; then
    XKIT_PANEL_SUB_PORT="$cur_port"
  fi
  [ -n "${XKIT_PANEL_SUB_PORT:-}" ] || XKIT_PANEL_SUB_PORT="$(rand_free_port 30000 50000)" \
    || { err "Нет свободного порта для подписок"; return 1; }
  if [ -z "${XKIT_PANEL_SUB_PATH:-}" ]; then
    if [ -n "$cur_path" ] && is_nginx_path "$(normalize_panel_path "$cur_path")"; then
      XKIT_PANEL_SUB_PATH="$(normalize_panel_path "$cur_path")"
    else
      [ -n "$cur_path" ] && warn "subPath панели «${cur_path:0:40}» нестандартный — генерирую свой (K-01)"
      XKIT_PANEL_SUB_PATH="/sub-${XKIT_SUB_TOKEN:-$(rand_str 8)}/"
    fi
  fi

  log "Подписки панели: 127.0.0.1:${XKIT_PANEL_SUB_PORT}${XKIT_PANEL_SUB_PATH} -> https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}"
  panel_settings_set \
    "subEnable=true" \
    "subPort=${XKIT_PANEL_SUB_PORT}" \
    "subPath=${XKIT_PANEL_SUB_PATH}" \
    "subListen=127.0.0.1" \
    "subDomain=${XKIT_HOST}" \
    "subURI=https://${XKIT_HOST}" || return 1
  ok "Настройки подписок панели применены"
  panel_restart || true
  save_xkit_env
  return 0
}

#=========================== v4.1: КОРРЕКТНЫЕ ССЫЛКИ В ПАНЕЛИ =================
# externalProxy каждому инбаунду: панель генерирует ссылки и QR с
# https://ДОМЕН:443/путь (за nginx) либо ДОМЕН:ПОРТ (direct: Reality и т.п.)
external_proxy_fix() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  kit_session || return 1
  routes_load

  echo ""
  log "Шаг 1/2: нативные подписки 3X-UI через nginx..."
  ensure_panel_sub_settings || return 1

  echo ""
  log "Шаг 2/2: externalProxy на инбаундах (панель покажет ДОМЕН, а не 127.0.0.1)..."
  if [ -t 0 ] && [ "${XKIT_YES:-0}" != "1" ]; then
    read -r -p "Проставить externalProxy ws/grpc/xhttp-инбаундам? (Reality/прямые НЕ трогаем) [Y/n]: " a
    [[ "$a" =~ ^[Nn] ]] && { log "Отменено"; return 0; }
  fi
  local fixed=0 same=0 ib id port mode eport cur new patched sec
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    IFS='|' read -r mode _ _ <<<"$(route_info "$id")"
    if [ "$sec" = "reality" ] || [ "$mode" = "direct" ]; then
      same=$((same+1)); continue   # прямым инбаундам (Reality/relay) externalProxy не нужен
    fi
    if [ "$mode" = "local" ]; then eport=443; else eport="$port"; fi
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; апдейт идемпотентен (по groupId)
      if v3_host_upsert "$id" "$XKIT_HOST" "$eport" "tls"; then
        ok "#$id: внешний адрес ${XKIT_HOST}:${eport} (hosts)"
        fixed=$((fixed+1))
      else
        err "#$id: host-группа не применилась"
      fi
      continue
    fi
    cur="$(jq -c '.externalProxy // []' <<<"$ib")"
    new="$(jq -nc --arg d "$XKIT_HOST" --argjson p "$eport" '[{"dest":$d,"port":$p,"remark":"xkit"}]')"
    if [ "$cur" = "$new" ]; then same=$((same+1)); continue; fi
    patched="$(jq -c --argjson ep "$new" '.externalProxy = $ep' <<<"$ib")"
    if api_update_inbound "$id" "$patched"; then
      ok "#$id: внешний адрес ${XKIT_HOST}:${eport}"
      fixed=$((fixed+1))
    else
      err "#$id: externalProxy не применился"
    fi
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  ok "Обновлено: $fixed; уже было корректно: $same"
  xray_restart
  sub_regen_quiet || true
  echo ""
  ok "Теперь ссылки/QR/sub URL в самой панели корректные:"
  ok "  подписка пользователя: https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}<subId>"
  ok "  файловые подписки xkit: https://${XKIT_HOST}$(sub_path)<subId>"
  return 0
}

#=========================== v4.1: REALITY ====================================
CAMO_DIR="/var/www/camo"

camo_site_install() {
  mkdir -p "$CAMO_DIR"
  cat > "${CAMO_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coming soon</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f7f8fa;color:#333}
  .card{max-width:560px;text-align:center;padding:48px 32px}
  h1{font-weight:600;font-size:28px;margin:0 0 12px}
  p{line-height:1.6;color:#666;margin:0}
  .dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#4a90d9;margin-right:8px}
</style>
</head>
<body>
  <div class="card">
    <h1><span class="dot"></span>Coming soon</h1>
    <p>Something new is on the way. This domain is reserved and will be
       launched shortly. Please check back later.</p>
  </div>
</body>
</html>
HTML
  chmod 644 "${CAMO_DIR}/index.html"
  ok "Сайт-прикрытие установлен: ${CAMO_DIR}/index.html"
}

reality_expand_targets() { # CIDR (/24 и меньше) или список -> по IP в строке
  command -v python3 >/dev/null 2>&1 || { err "python3 не найден — выполните: apt-get install -y python3"; echo "ERR:python3 не найден"; return 1; }
  python3 - "$1" <<'PY'
import sys, ipaddress, re
arg = sys.argv[1]
if "/" in arg:
    try:
        net = ipaddress.ip_network(arg, strict=False)
    except ValueError:
        print("ERR:bad-cidr"); sys.exit(0)
    if net.num_addresses > 256:
        print("ERR:too-big"); sys.exit(0)
    for ip in net.hosts():
        print(str(ip))
else:
    for h in arg.split():
        # V-01 (аудит №2): токен уходит в SSH-сессию — валидируем charset,
        # кавычка/;/$ не имеют права доехать до bash ноды
        if not re.fullmatch(r"[A-Za-z0-9._:/-]+", h):
            print("ERR:bad-target"); sys.exit(0)
        print(h)
PY
}

reality_scan_run() { # $1 targets (построчно), $2 out.tsv
  local out="$2"
  local tmp; tmp="$(mktemp /tmp/.xkit-scan.XXXXXX)"
  grep -v '^$' <<<"$1" > "$tmp" || true
  local total open_cnt
  total="$(wc -l < "$tmp")"
  log "Шаг 1/2: TCP-проба :443 на ${total} адресах (50 параллельно)..."
  cat > "${tmp}.probe" <<'EOF'
#!/bin/bash
timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$1" 2>/dev/null && echo "$1"
EOF
  chmod +x "${tmp}.probe"
  local openf="${tmp}.open"; : > "$openf"
  xargs -a "$tmp" -P 50 -n 1 "${tmp}.probe" >> "$openf" 2>/dev/null || true
  open_cnt="$(grep -c . "$openf" 2>/dev/null || echo 0)"
  log "Шаг 2/2: TLS-детали на ${open_cnt} открытых адресах..."
  : > "$out"
  local ip brief cert cn san issuer end tls13 h2 x25519 selfsig verdict
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    brief="$(echo | timeout 6 openssl s_client -brief -connect "${ip}:443" -servername "${ip}" 2>&1)"
    tls13=no;  grep -q "TLSv1.3" <<<"$brief" && tls13=yes
    h2=no;     grep -qi "ALPN protocol: *h2" <<<"$brief" && h2=yes
    x25519=no; grep -q "X25519" <<<"$brief" && x25519=yes
    cert="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>/dev/null \
            | openssl x509 -noout -subject -issuer -ext subjectAltName -enddate 2>/dev/null)"
    cn="$(sed -n 's/^subject=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    # первый SAN без wildcard (в качестве SNI wildcard не годится), фолбэк — CN
    san="$(awk '/^X509v3 Subject Alternative Name:/{getline; sub(/^ +/,""); print; exit}' <<<"$cert" \
           | sed 's/DNS://g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^\*' | head -n1)"
    [ -n "$san" ] || san="$cn"
    issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    end="$(sed -n 's/^notAfter=//p' <<<"$cert" | head -n1)"
    # self-signed = ЛЮБОЙ провал проверки цепочки (истёк, кривой CN/SAN, unknown CA,
    # incomplete chain). «Verify return code: 0 (ok)» — единственный признак «годен».
    # Раньше отсутствие строки verify трактовалось как успех — плохой dest получал «ДА».
    vrf_out="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>&1)"
    selfsig=yes
    if grep -q 'Verify return code: 0 (ok)' <<<"$vrf_out" \
       || grep -qE 'Verify return code: 0[[:space:]]*$' <<<"$vrf_out"; then
      selfsig=no
    fi
    verdict="НЕТ"
    if [ "$tls13" = "yes" ] && [ "$selfsig" = "no" ] && { [ -n "$san" ] || [ -n "$cn" ]; }; then
      verdict="ДА"
      [ "$h2" = "yes" ] && [ "$x25519" = "yes" ] && verdict="ДА+"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ip" "$tls13" "$h2" "$x25519" "$selfsig" "${cn:--}" "${san:--}" "${end:--}" "$verdict" >> "$out"
  done < "$openf"
  rm -f "$tmp" "${tmp}.probe" "$openf"
  return 0
}

reality_scan_print() { # $1 tsv
  echo ""
  printf '%-16s %-5s %-3s %-7s %-6s %-28s %-30s %s\n' "IP" "TLS13" "H2" "X25519" "SELF" "CN" "SNI(SAN)" "ГОДЕН"
  echo "----------------------------------------------------------------------------------------------------------"
  sort -t$'\t' -k9,9r -k1,1V "$1" | while IFS=$'\t' read -r ip t13 h2 x2 ss cn san end v; do
    printf '%-16s %-5s %-3s %-7s %-6s %-28s %-30s %s\n' "$ip" "$t13" "$h2" "$x2" "$ss" "${cn:0:28}" "${san:0:30}" "$v"
  done
  echo ""
  ok "Годен = TLS1.3 + публичный сертификат (не self-signed). «ДА+» = ещё и H2/X25519 (лучший камуфляж)."
}

# выбор из готового списка; результат в RDEST / RSNI
reality_known_pick() {
  echo "1) 1.1.1.1:443                SNI: cloudflare-dns.com  (быстрый, надёжный)"
  echo "2) www.tesla.com:443          SNI: www.tesla.com"
  echo "3) www.samsung.com:443        SNI: www.samsung.com"
  echo "4) www.lovelive-anime.jp:443  SNI: www.lovelive-anime.jp"
  echo "5) www.icloud.com:443         SNI: www.icloud.com"
  read -r -p "Выбор [1-5]: " k
  case "$k" in
    1) RDEST="1.1.1.1:443";              RSNI="cloudflare-dns.com" ;;
    2) RDEST="www.tesla.com:443";        RSNI="www.tesla.com" ;;
    3) RDEST="www.samsung.com:443";      RSNI="www.samsung.com" ;;
    4) RDEST="www.lovelive-anime.jp:443"; RSNI="www.lovelive-anime.jp" ;;
    5) RDEST="www.icloud.com:443";       RSNI="www.icloud.com" ;;
    *) return 1 ;;
  esac
  return 0
}

# скан подсети + выбор кандидата; результат в RDEST / RSNI
reality_scan_pick() {
  local myip def t targets n row
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24 — подсеть этого сервера)"
  read -r -p "Что сканируем? CIDR или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  local out="${XKIT_DIR}/reality-scan.tsv"
  mkdir -p "$XKIT_DIR"
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Ни один адрес не ответил на :443"; return 1; }
  reality_scan_print "$out"
  ok "Результат сохранён: $out"
  read -r -p "Номер dest из таблицы (Enter — отмена): " n
  [ -n "$n" ] || return 1
  row="$(sort -t$'\t' -k9,9r -k1,1V "$out" | sed -n "${n}p")"
  [ -n "$row" ] || { err "Нет такого номера"; return 1; }
  RDEST="$(awk -F'\t' '{print $1":443"}' <<<"$row")"
  RSNI="$(awk -F'\t' '{print ($7!="-" && $7!="") ? $7 : $6}' <<<"$row")"
  [ -n "$RSNI" ] && [ "$RSNI" != "-" ] || { err "У кандидата нет домена в сертификате — SNI не определить"; return 1; }
  return 0
}

# $1 dest (host:port | ip:port | 127.0.0.1:8444), $2 sni
reality_create_inbound() {
  local dest="$1" sni="$2" p
  p="$(rand_free_port 10000 60000)" || { err "Нет свободного порта"; return 1; }
  read -r -p "Публичный порт Reality inbound [${p}]: " pin
  p="${pin:-$p}"
  is_port "$p" || { err "Некорректный порт"; return 1; }
  port_busy "$p" && { err "Порт $p уже занят"; return 1; }

  log "Генерирую ключи x25519 через API панели..."
  local priv pub
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; return 1; }
  local uuid subid email sid
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="reality-$(rand_hex 2)"; sid="$(rand_hex 4)"

  local settings stream ib
  settings="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" '
    {clients:[{id:$id, flow:"xtls-rprx-vision", email:$email, limitIp:0, totalGB:0,
               expiryTime:0, enable:true, tgId:"", subId:$sub, reset:0}],
     decryption:"none", fallbacks:[]}')"
  stream="$(jq -nc --arg dest "$dest" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni],
                      privateKey:$priv, minClient:"", maxClient:"", maxTimeDiff:0,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}')"
  ib="$(jq -nc --arg port "$p" --arg tag "inbound-${p}" --arg remark "reality-${sni}" \
        --arg s "$settings" --arg st "$stream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
     listen:"", port:($port|tonumber), protocol:"vless",
     settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"

  log "Создаю Reality inbound: порт ${p}, dest ${dest}, SNI ${sni}..."
  api_add_inbound "$ib" || return 1

  # id созданного + externalProxy (чтобы панель показывала ДОМЕН:порт)
  local newlist ibid fresh cl link
  newlist="$(api_list)" || true
  ibid="$(jq -r --arg t "inbound-${p}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$newlist")"
  if [ -n "$ibid" ]; then
    fresh="$(api_get_inbound "$ibid")" || true
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; Reality наследует security (same)
      v3_host_upsert "$ibid" "$XKIT_HOST" "$p" "same" \
        && ok "Внешний адрес в панели (hosts): ${XKIT_HOST}:${p}" \
        || warn "Не удалось создать host-группу для Reality-инбаунда (ссылки в панели — вручную)"
    elif [ -n "$fresh" ]; then
      fresh="$(jq -c --arg d "$XKIT_HOST" --argjson p "$p" \
        '.externalProxy = [{"dest":$d,"port":$p,"remark":"xkit"}]' <<<"$fresh")"
      api_update_inbound "$ibid" "$fresh" >/dev/null 2>&1 || true
      fresh="$(api_get_inbound "$ibid")" || true
    fi
  else
    fresh="$ib"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 && ok "UFW: открыт ${p}/tcp"
  fi

  cl="$(jq -c '.settings|fromjson?|.clients[0]' <<<"${fresh:-$ib}")"
  echo ""
  ok "Reality inbound создан: порт ${p}, dest ${dest}, SNI ${sni}"
  [ -n "$ibid" ] && ok "Внешний адрес в панели: ${XKIT_HOST}:${p}"
  link="$(link_for_client "${fresh:-$ib}" "$cl")"
  [ -n "$link" ] && { echo ""; ok "Ссылка клиента:"; printf '  %s\n' "$link"; }
  sub_regen_quiet || true
  ok "Подписка: https://${XKIT_HOST}$(sub_path)${subid}"
  return 0
}

reality_wizard() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  echo "Какой dest (сайт-прикрытие) используем для Reality?"
  echo "1) Свой сайт на этом сервере (${XKIT_HOST:-домен} + наш сертификат) — лучший камуфляж"
  echo "2) Скан подсети — найти подходящие сайты рядом"
  echo "3) Готовый список проверенных dest"
  echo "4) Вручную: dest + SNI"
  read -r -p "Выбор [1-4]: " c
  local dest="" sni=""
  case "$c" in
    1)
      if [ "$(host_kind "${XKIT_HOST:-}")" != "domain" ] || [ ! -f "${XKIT_CRT:-}" ]; then
        err "Нужен ДОМЕН с валидным сертификатом (у вас IP-режим или серта нет)."
        warn "Варианты: пункт 10 (перевыпустить серт) либо режимы 2/3/4 ниже."
        return 1
      fi
      camo_site_install
      XKIT_REALITY_INTERNAL=1
      save_xkit_env
      regen_conf_and_apply || return 1
      dest="127.0.0.1:8444"; sni="$XKIT_HOST" ;;
    2) reality_scan_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    3) reality_known_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    4)
      local dh dp
      dh="$(read_host "dest (IP или домен) -> ")"
      read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
      sni="$(read_host "SNI (домен из сертификата dest) -> ")"
      dest="${dh}:${dp}" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  [ -n "$dest" ] && [ -n "$sni" ] || { err "dest/SNI не определены"; return 1; }
  reality_create_inbound "$dest" "$sni"
}

reality_scan_menu() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  mkdir -p "$XKIT_DIR"
  local myip def t targets out="${XKIT_DIR}/reality-scan.tsv"
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24)"
  echo ""
  read -r -p "CIDR (например 5.6.7.0/24) или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Никто не ответил на :443"; return 0; }
  reality_scan_print "$out"
  ok "Результат сохранён: $out"
  return 0
}

reality_show_keys() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  local found=0 ib sec st tag port dest
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    [ "$sec" = "reality" ] || continue
    found=$((found+1))
    st="$(jq -r '.streamSettings' <<<"$ib")"
    tag="$(jq -r '.tag' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    dest="$(jq -r '.realitySettings.dest // ""' <<<"$st")"
    echo -e "${GREEN}── ${tag} (порт ${port})${NC}"
    echo "   dest: ${dest}   SNI: $(reality_sni "$st")"
    echo "   publicKey: $(reality_pbk "$st")"
    echo "   shortId:   $(reality_sid "$st")"
    local cl link
    while IFS= read -r cl; do
      [ -z "$cl" ] && continue
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] && printf '   %s\n' "$link"
    done < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$found" -eq 0 ] && warn "Reality-инбаундов нет — создайте (пункт 14)"
  return 0
}

#=========================== v4.1: НОДЫ =======================================
# Схема: клиенты -> мастер (nginx:443, pool-inbound) -> xray balancer -> ноды
# (VLESS+Reality на каждой ноде). Переключение при сбоях — observatory.

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
    nodes = json.load(open(src))
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
  local rec="$1" t tlist n row
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
  reality_scan_print "$out"
  ok "Результат сохранён: $out"
  read -r -p "Номер dest из таблицы (Enter — отмена): " n
  [ -n "$n" ] || return 1
  row="$(sort -t$'\t' -k9,9r -k1,1V "$out" | sed -n "${n}p")"
  [ -n "$row" ] || { err "Нет такого номера"; return 1; }
  RDEST="$(awk -F'\t' '{print $1":443"}' <<<"$row")"
  RSNI="$(awk -F'\t' '{print ($7!="-" && $7!="") ? $7 : $6}' <<<"$row")"
  [ -n "$RSNI" ] && [ "$RSNI" != "-" ] || { err "У кандидата нет домена в сертификате — SNI не определить"; return 1; }
  return 0
}

node_add() {
  require_root
  command -v ssh >/dev/null 2>&1 || apt-get install -y -qq openssh-client >/dev/null 2>&1
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1

  echo ""
  echo -e "${YELLOW}=== Добавление ноды (зарубежный сервер) ===${NC}"
  local nname nhost nport nuser
  # EOF (Ctrl-D) на любом вводе — отмена, а не молчаливое продолжение
  # (симметрия с v3.2.1, ревью v4.7.0: на порту/юзере EOF давал дефолты
  # 22/root и попытку коннекта к ноде)
  read -r -p "Имя ноды (латиница, например de1): " nname || { echo; return 1; }
  [[ "$nname" =~ ^[a-zA-Z0-9_-]{1,20}$ ]] || { err "Имя: латиница/цифры/-/_ до 20 символов"; return 1; }
  jq -e --arg n "$nname" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
    && { err "Нода '$nname' уже есть"; return 1; }
  nhost="$(read_host "IP/домен ноды -> ")"
  read -r -p "SSH порт [22]: " nport || { echo; return 1; }
  nport="${nport:-22}"; is_port "$nport" || { err "Порт"; return 1; }
  read -r -p "SSH пользователь [root]: " nuser || { echo; return 1; }
  nuser="${nuser:-root}"
  # аудит №4: без валидации «a"b» уезжало в ssh/jq-реестр; допускаем то, что
  # легитимно для useradd: латиница/цифры/._-, не с цифры, до 32 символов
  [[ "$nuser" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || { err "SSH-пользователь: только латиница/цифры/._- (до 32 симв., не с цифры)"; return 1; }

  echo "Доступ: 1) пароль (один раз — поставим наш SSH-ключ, пароль не сохраняется)  2) путь к ключу"
  read -r -p "Выбор [1]: " am || { echo; return 1; }
  am="${am:-1}"
  local NODE_SSH_PASS="" nkey=""
  local rec_auth="key"
  if [ "$am" = "1" ]; then
    read -r -s -p "SSH пароль ${nuser}@${nhost}: " NODE_SSH_PASS || { echo; return 1; }
    echo ""
    [ -n "$NODE_SSH_PASS" ] || { err "Пустой пароль"; return 1; }
    rec_auth="password"
    nkey="$(node_own_key)"
  else
    nkey="$(node_own_key)"
    read -r -p "Путь к приватному ключу [${nkey}]: " nkey_in || { echo; return 1; }
    [ -n "$nkey_in" ] && nkey="$nkey_in"
    [ -f "$nkey" ] || { err "Ключ не найден: $nkey"; return 1; }
  fi

  local rec
  rec="$(jq -nc --arg n "$nname" --arg h "$nhost" --argjson p "$nport" --arg u "$nuser" \
         --arg a "$rec_auth" --arg k "$nkey" \
    '{name:$n, host:$h, ssh_port:$p, ssh_user:$u, auth:$a, key_path:$k}')"

  log "Проверяю SSH-доступ..."
  if [ "$rec_auth" = "password" ]; then
    node_ssh "$rec" "echo ok" 2>/dev/null | grep -q ok || { err "SSH по паролю не прошёл"; return 1; }
    local pub; pub="$(cat "${nkey}.pub")"
    node_ssh "$rec" "mkdir -p ~/.ssh && chmod 700 ~/.ssh; grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
      || { err "Не удалось установить ключ на ноде"; return 1; }
    rec="$(jq -c --arg k "$nkey" '.auth="key" | .key_path=$k' <<<"$rec")"
    ok "Наш ключ установлен на ноде — пароль больше не нужен (и не сохранён)"
  fi
  node_ssh "$rec" "echo ok" 2>/dev/null | grep -q ok || { err "SSH по ключу не прошёл"; return 1; }
  local kh; kh="${XKIT_DIR}/known_hosts"
  local fp; fp="$(awk -v h="[$nhost]:$nport" -v h2="$nhost" '$3==h || $3==h2 {print}' "$kh" 2>/dev/null \
    | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  [ -n "$fp" ] && ok "Ключ хоста ноды зафиксирован (TOFU; можно сверить с консолью провайдера): ${fp}"

  log "Устанавливаю 3X-UI на ноду (если его нет)..."
  # K-02: тот же тег-релиз, что и на мастере; URL валидирован в xui_install_url
  local xuiu; xuiu="$(xui_install_url)"
  node_ssh "$rec" "XUI_URL='${xuiu}' bash -s" <<'EOS' || { err "Установка 3X-UI на ноде не удалась"; return 1; }
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq curl sqlite3 >/dev/null 2>&1; }
if ! command -v x-ui >/dev/null 2>&1; then
  DL="$(mktemp)"
  curl -fsSL "${XUI_URL:?}" -o "$DL" \
    || { echo "ERR: не удалось скачать установщик 3X-UI"; rm -f "$DL"; exit 1; }
  bash -n "$DL" || { echo "ERR: установщик 3X-UI не проходит bash -n (K-02)"; rm -f "$DL"; exit 1; }
  XUI_NONINTERACTIVE=1 bash "$DL" </dev/null
  rm -f "$DL"
fi
systemctl enable --now x-ui >/dev/null 2>&1 || true
EOS

  local np_user np_pass np_port
  np_user="kit$(rand_hex 2)"
  np_pass="$(rand_str 16)"
  np_port="$(shuf -i 20000-50000 -n 1)"
  log "Настраиваю панель ноды (случайный логин/пароль/порт)..."
  node_ssh "$rec" "/usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' -port '${np_port}' >/dev/null 2>&1 || /usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' >/dev/null 2>&1 || true"
  node_ssh "$rec" "systemctl restart x-ui" || true
  log "Включаю HTTPS (самоподписанный сертификат) для панели ноды — креды не пойдут по HTTP..."
  node_ssh "$rec" 'bash -s' <<'EOS' || warn "HTTPS панели ноды не включился — останется HTTP"
C=/etc/x-ui/panel-cert.pem; K=/etc/x-ui/panel-key.pem
if [ ! -s "$C" ] || [ ! -s "$K" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$K" 2>/dev/null \
    && openssl req -new -x509 -key "$K" -out "$C" -days 3650 \
       -subj "/CN=node-panel" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
  chmod 600 "$K" 2>/dev/null; chmod 644 "$C" 2>/dev/null
fi
if [ -s "$C" ] && [ -s "$K" ] && command -v sqlite3 >/dev/null 2>&1; then
  for kv in "webCertFile|$C" "webCertKey|$K"; do
    key="${kv%%|*}"; val="${kv#*|}"
    sqlite3 /etc/x-ui/x-ui.db \
      "INSERT INTO settings (key,value) VALUES('$key','$val') ON CONFLICT(key) DO UPDATE SET value=excluded.value;" 2>/dev/null \
      || sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key,value) VALUES('$key','$val');" 2>/dev/null || true
  done
  systemctl restart x-ui
fi
EOS
  sleep 3
  local nbase
  nbase="$(node_ssh "$rec" "/usr/local/x-ui/x-ui setting -show true 2>/dev/null" \
           | awk -F': ' '/webBasePath/{print $2; exit}' | tr -d '[:space:]')"
  nbase="$(normalize_panel_path "${nbase:-/}")"
  rec="$(jq -c --argjson pp "$np_port" --arg u "$np_user" --arg p "$np_pass" --arg b "$nbase" \
        '.panel = {port:$pp, user:$u, pass:$p, base:$b, tls:true}' <<<"$rec")"
  local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
  if ! node_login "$rec" "$ck"; then
    warn "Логин по HTTPS не прошёл — пробую HTTP (сертификат панели не применился?)"
    rec="$(jq -c '.panel.tls = false' <<<"$rec")"
    node_login "$rec" "$ck" || { err "Логин в панель ноды (порт ${np_port}${nbase}) не прошёл"; rm -f "$ck"; return 1; }
  fi
  local psch="http"; jq -e '.panel.tls == true' <<<"$rec" >/dev/null 2>&1 && psch="https"
  ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (снаружи доступ ограничен IP мастера)"
  if [ "$psch" = "https" ]; then
    local npin
    npin="$(cert_pin "$nhost" "$np_port")"
    if [ -n "$npin" ]; then
      rec="$(jq -c --arg p "$npin" '.panel.pincert = $p' <<<"$rec")"
      ok "Сертификат панели ноды запинен (sha256//$(printf '%s' "$npin" | head -c 16)...) — MITM на API не пройдёт"
    else
      warn "Не удалось снять пин сертификата панели — node_api будет без пина (перепинить: xkit nodes repin ${nname})"
    fi
  fi

  local tport tp
  if node_ssh "$rec" "ss -ltn 2>/dev/null | grep -q ':443 '" 2>/dev/null; then
    warn "На ноде порт 443 занят — предлагаю 8443"
    tport=8443
  else
    tport=443
  fi
  read -r -p "Порт туннеля на ноде [${tport}]: " tp; tp="${tp:-$tport}"; is_port "$tp" || { err "Порт"; return 1; }

  echo "Dest (прикрытие) для Reality на ноде:"
  echo "  1) 1.1.1.1 (быстро и надёжно)   2) известный список   3) СКАН С САМОЙ НОДЫ"
  local mdest msni
  mdest="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.dest // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  msni="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.serverNames[0] // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  if [ -n "$mdest" ] && [ -n "$msni" ]; then
    echo "  4) как на мастере (${mdest}, SNI ${msni})"
  else
    echo "  4) как на мастере (на мастере Reality-инбаунд не найден — недоступно)"
  fi
  echo "  5) вручную"
  read -r -p "Выбор [1]: " dc; dc="${dc:-1}"
  local ndest="" nsni="" RDEST="" RSNI=""
  case "$dc" in
    2) reality_known_pick || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
    3) node_reality_scan_pick "$rec" || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
    4) [ -n "$mdest" ] && [ -n "$msni" ] || { err "На мастере нет Reality — выберите другой вариант"; return 1; }
       ndest="$mdest"; nsni="$msni" ;;
    5)
      local dh dp
      dh="$(read_host "dest -> ")"
      read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
      nsni="$(read_host "SNI -> ")"
      ndest="${dh}:${dp}" ;;
    *) ndest="1.1.1.1:443"; nsni="cloudflare-dns.com" ;;
  esac

  log "Генерирую ключи Reality для ноды..."
  local priv pub tuuid tsid
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; rm -f "$ck"; return 1; }
  tuuid="$(new_uuid)"; tsid="$(rand_hex 4)"

  local nsettings nstream nib
  nsettings="$(jq -nc --arg id "$tuuid" --arg sn "$nname" --arg sub "$(rand_str 16)" '
    {clients:[{id:$id, flow:"xtls-rprx-vision", email:("tunnel-"+$sn), limitIp:0, totalGB:0,
               expiryTime:0, enable:true, tgId:"", subId:$sub, reset:0}],
     decryption:"none", fallbacks:[]}')"
  nstream="$(jq -nc --arg dest "$ndest" --arg sni "$nsni" --arg priv "$priv" --arg sid "$tsid" --arg pub "$pub" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni], privateKey:$priv,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}')"
  nib="$(jq -nc --arg port "$tp" --arg tag "inbound-${tp}" --arg remark "xkit-tunnel-${nname}" \
        --arg s "$nsettings" --arg st "$nstream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0, listen:"",
     port:($port|tonumber), protocol:"vless", settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"
  log "Создаю туннельный inbound на ноде (VLESS+Reality, порт ${tp})..."
  local out
  out="$(node_api "$rec" "panel/api/inbounds/add" POST "$nib" "$ck")"
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "Нода: создание inbound не прошло: $(jq -r '.msg // "?"' <<<"$out" | head -c 200)"
    rm -f "$ck"; return 1
  fi
  ok "Туннельный inbound на ноде создан"

  local myip
  myip="$(pubip)"   # только валидный IP; иначе ufw настрою без правила для панели
  is_ip "$myip" || myip=""   # страховка: в env уходит либо валидный IP, либо пусто
  log "Настраиваю ufw на ноде (SSH ${nport} + туннель ${tp}/tcp; панель — только с IP мастера)..."
  # ВАЖНО: все переменные — через env (heredoc quoted, локальные ${...} туда не попадают).
  # set -u + :? гарантируют: при потере переменной скрипт упадёт ДО ufw --force enable,
  # иначе нода уходит в lockout (SSH/туннель отрезаны). Вывод ufw allow НЕ глушится.
  node_ssh "$rec" "env MYIP='${myip}' NPORT='${nport}' TP='${tp}' NPP='${np_port}' bash -s" <<'EOS' \
  || warn "UFW на ноде НЕ настроен — проверьте firewall вручную (правила могли не примениться)"
set -u
export DEBIAN_FRONTEND=noninteractive
: "${NPORT:?нет NPORT}"; : "${TP:?нет TP}"; : "${NPP:?нет NPP}"
command -v ufw >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq ufw >/dev/null 2>&1; }
command -v ufw >/dev/null 2>&1 || { echo "ERR: ufw не установился"; exit 1; }
ufw allow "${NPORT}/tcp" || { echo "ERR: правило SSH (${NPORT}/tcp) не применилось"; exit 1; }
ufw allow "${TP}/tcp"    || { echo "ERR: правило туннеля (${TP}/tcp) не применилось"; exit 1; }
if [ -n "${MYIP:-}" ]; then
  ufw allow from "${MYIP}" to any port "${NPP}" proto tcp || { echo "ERR: правило панели (${NPP})"; exit 1; }
else
  # IP мастера не определён (pubip/DNS/РКН) — НЕ оставляем панель ноды в интернете:
  # иначе ufw enable с default DROP, но панель слушает 0.0.0.0 и остаётся доступной
  ufw deny "${NPP}/tcp" || { echo "ERR: не удалось закрыть панель (${NPP}) в ufw"; exit 1; }
  echo "WARN: IP мастера неизвестен — панель ноды закрыта в ufw (доступ только через SSH-туннель)"
fi
ufw --force enable || { echo "ERR: ufw enable не прошёл"; exit 1; }
echo "UFW на ноде: правила применены, firewall активен"
EOS
  if [ -z "$myip" ]; then
    warn "Публичный IP мастера не определён — панель ноды (${np_port}/tcp) ЗАКРЫТА в ufw."
    warn "Доступ к панели ноды — через SSH-туннель: ssh -p ${nport} -L ${np_port}:127.0.0.1:${np_port} ${nuser}@${nhost}"
  fi

  rec="$(jq -c --argjson tport "$tp" --arg uuid "$tuuid" --arg pbk "$pub" --arg sid "$tsid" \
         --arg sni "$nsni" --arg dest "$ndest" --arg tag "node-${nname}" --arg created "$(date -Is)" \
    '.tunnel = {port:$tport, proto:"vless", net:"tcp", sec:"reality", uuid:$uuid, pbk:$pbk,
                sid:$sid, sni:$sni, dest:$dest, flow:"xtls-rprx-vision"}
      | .outbound_tag = $tag | .created = $created' <<<"$rec")"
  nodes_load | jq -c --argjson r "$rec" 'map(select(.name != $r.name)) + [$r]' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  chmod 600 "$XKIT_NODES"
  rm -f "$ck"

  local apply_failed=0
  log "Готовлю pool-инбаунд на мастере (вход для клиентов с балансировкой)..."
  nodes_ensure_pool || apply_failed=1
  log "Применяю аутбаунды нод + balancer к xray на мастере..."
  nodes_apply_template || apply_failed=1
  if [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    local pool_ib pool_cl plink
    pool_ib="$(api_get_inbound "$XKIT_POOL_INBOUND")" || true
    pool_cl="$(jq -c '.settings|fromjson?|.clients[0] // empty' <<<"${pool_ib:-}")"
    if [ -n "$pool_cl" ]; then
      plink="$(link_for_client "${pool_ib:-}" "$pool_cl")"
      [ -n "$plink" ] && { echo ""; ok "Ссылка ПОЛА (трафик балансируется по нодам):"; printf '  %s\n' "$plink"; }
    fi
  fi
  read -r -p "Срок аренды ноды '${nname}' (YYYY-MM-DD, Enter — пропустить): " dex
  if [ -n "$dex" ]; then
    if expiry_set node "$nname" "$dex" ""; then
      ok "Срок аренды сохранён: ${dex} (виден в веб-дашборде и xkit expiry list)"
    else
      warn "Дата не распознана — задайте позже: xkit expiry set ${nname} YYYY-MM-DD"
    fi
  fi
  echo ""
  if [ "${apply_failed:-0}" = "0" ]; then
    echo -e "${GREEN}=== Нода '${nname}' подключена ===${NC}"
  else
    err "=== Нода '${nname}' в реестре, но конфиг НЕ применён — трафик на неё не пойдёт ==="
    warn "Выполните: xkit (меню) -> пункт 2 (автопроброс), затем НОДЫ -> health"
  fi
  ok "Туннель: мастер -> ${nhost}:${tp} (VLESS+Reality, SNI ${nsni})"
  ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (ufw: доступ только с IP мастера)"
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-roundRobin} (сменить: Ноды -> стратегия)"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

# повторное применение конфигурации после сбоя apply: нода могла остаться
# «в реестре, но без маршрута». Проверяет туннельные инбаунды на нодах,
# pool на мастере и аутбаунды/balancer в шаблоне xray
nodes_repair() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  local bad=0 cnt
  cnt="$(nodes_load 2>/dev/null | jq -r 'length' 2>/dev/null)"
  cnt="${cnt:-0}"
  if [ "$cnt" -eq 0 ]; then
    warn "Нод в реестре нет — repair просто пересоберёт конфиг мастера (pool + маршруты)"
  else
    log "Проверяю туннельные инбаунды на нодах..."
    local rec nm tport ttag inb_id ck
    while IFS= read -r rec; do
      [ -z "$rec" ] && continue
      nm="$(jq -r '.name' <<<"$rec")"
      tport="$(jq -r '.tunnel.port // empty' <<<"$rec")"
      if [ -z "$tport" ]; then
        warn "${nm}: в записи нет tunnel.port — пропускаю"
        continue
      fi
      ttag="inbound-${tport}"
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck" >/dev/null 2>&1; then
        inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
          | jq -r --arg t "$ttag" '[.obj[]?|select(.tag==$t)][0].id // empty' 2>/dev/null)"
        if [ -n "$inb_id" ]; then
          ok "${nm}: туннельный inbound на месте (#${inb_id})"
        else
          err "${nm}: туннельного inbound (${ttag}) НЕТ на ноде — переподключите ноду (удалить + добавить)"
          bad=1
        fi
      else
        warn "${nm}: панель ноды недоступна — inbound проверить не смог"
        bad=1
      fi
      rm -f "$ck"
    done < <(jq -c '.[]' <(nodes_load))
  fi
  log "Pool-инбаунд на мастере (пересоздам, если маршрута нет)..."
  nodes_ensure_pool || bad=1
  log "Аутбаунды нод + balancer в шаблоне xray..."
  nodes_apply_template || bad=1
  if [ "$bad" -eq 0 ]; then
    ok "Repair завершён: конфигурация применена"
    xkit_summary_save >/dev/null 2>&1 || true
  else
    err "Repair: остались проблемы (см. выше) — проверьте nginx -t и панели нод"
    return 1
  fi
  return 0
}

# перепинить отпечаток сертификата панели ноды (после перевыпуска серта на ноде)
node_repin() { # $1 имя ноды или all
  load_xkit_env || die "Сначала установка (пункт 1)"
  local want="${1:-all}" arr n pin any=0 old_pin yn
  arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n="$(jq -r '.name' <<<"$rec")"
    [ "$want" = "all" ] || [ "$want" = "$n" ] || continue
    any=1
    if [ "$(jq -r '.panel.tls // "false"' <<<"$rec")" != "true" ]; then
      warn "${n}: панель ноды по HTTP — пиновать нечего"
      continue
    fi
    pin="$(cert_pin "$(jq -r '.host' <<<"$rec")" "$(jq -r '.panel.port' <<<"$rec")")"
    if [ -n "$pin" ]; then
      # TOFU (аудит №4): молча принять ИЗМЕНИВШИЙСЯ пин = легитимизировать
      # возможный MITM. Первый пин (пустой старый) принимается без вопросов
      old_pin="$(jq -r --arg n "$n" 'map(select(.name==$n))[0].panel.pincert // ""' <<<"$arr" 2>/dev/null)"
      if [ -n "$old_pin" ] && [ "$old_pin" != "$pin" ]; then
        warn "${n}: пин ИЗМЕНИЛСЯ (старый: $(printf '%s' "$old_pin" | head -c 16)..., новый: $(printf '%s' "$pin" | head -c 16)...)"
        yn="n"
        if [ -t 0 ]; then
          read -r -p "Принять новый пин? [y/N]: " yn
        else
          warn "${n}: stdin не tty — пин НЕ обновляется (запустите интерактивно)"
        fi
        if ! [[ "$yn" =~ ^[Yy] ]]; then
          warn "${n}: пин не обновлён (если серт не перевыпускали — возможно, MITM'ится)"
          continue
        fi
      fi
      nodes_load | jq -c --arg n "$n" --arg p "$pin" \
        'map(if .name==$n then .panel.pincert=$p else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      ok "${n}: пин обновлён (sha256//$(printf '%s' "$pin" | head -c 16)... )"
    else
      err "${n}: не удалось снять отпечаток сертификата (нода доступна?)"
    fi
  done < <(jq -c '.[]' <<<"$arr")
  [ "$any" = "1" ] || { err "Нода '${want}' не найдена (xkit nodes repin <имя|all>)"; return 1; }
  return 0
}

nodes_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет — добавьте (Ноды -> добавить)"; return 0; }
  echo ""
  printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "ИМЯ" "ХОСТ" "SSH" "ТУННЕЛЬ" "SNI" "ПАНЕЛЬ"
  echo "-------------------------------------------------------------------------------"
  local n h sp tp sni pp
  while IFS=$'\t' read -r n h sp tp sni pp; do
    printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "$n" "$h" "$sp" "$tp" "$sni" "$pp"
  done < <(jq -r '.[] | [.name, .host, (.ssh_port|tostring), (.tunnel.port|tostring), .tunnel.sni, (.panel.port|tostring)] | @tsv' <<<"$arr")
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-roundRobin}"
  return 0
}

nodes_health() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  # fails = туннель/панель, ssh_fails = SSH недоступен (аудит №2: раньше SSH-провал
  # не считался, и при живом туннеле печатались [ВНИМ], а финал был «Все ноды живы»)
  local arr cnt fails=0 ssh_fails=0
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  echo ""
  local rec name host tport ck
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if ! timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
      echo "  [СБОЙ] ${name}: туннель ${host}:${tport} недоступен"
      fails=$((fails+1))
      continue
    fi
    if node_ssh "$rec" "systemctl is-active x-ui" >/dev/null 2>&1; then
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck"; then
        echo "  [OK]   ${name}: туннель :${tport}, x-ui работает, панель отвечает"
      else
        echo "  [ВНИМ] ${name}: туннель жив, но панель ноды не логинится"
        fails=$((fails+1))
      fi
      rm -f "$ck"
    else
      echo "  [ВНИМ] ${name}: туннель жив, SSH до ноды не прошёл (x-ui проверьте руками)"
      ssh_fails=$((ssh_fails+1))
    fi
  done < <(jq -c '.[]' <<<"$arr")
  if [ "$fails" -gt 0 ]; then
    err "Проблемы на ${fails} нодах"
  elif [ "$ssh_fails" -gt 0 ]; then
    warn "Туннели живы, но SSH недоступен на ${ssh_fails} нод(ах) — x-ui/конфиг там проверьте руками"
  else
    ok "Все ноды живы"
  fi
  return 0
}

nodes_strategy() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo "Стратегия балансировки (xray balancer):"
  echo "1) roundRobin — по кругу (по умолчанию)"
  echo "2) random     — случайно"
  echo "3) leastPing  — УМНАЯ: observatory пингует ноды, трафик идёт на самую быструю"
  echo "4) leastLoad  — УМНАЯ: burst-замеры, выбор наименее загруженной/быстрой"
  read -r -p "Выбор [1-4]: " s
  case "$s" in
    1) XKIT_BAL_STRATEGY="roundRobin" ;;
    2) XKIT_BAL_STRATEGY="random" ;;
    3) XKIT_BAL_STRATEGY="leastPing" ;;
    4) XKIT_BAL_STRATEGY="leastLoad" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  save_xkit_env
  log "Применяю стратегию ${XKIT_BAL_STRATEGY} к конфигу xray..."
  nodes_apply_template || return 1
  ok "Готово. При leastPing/leastLoad xray сам переключает трафик на живые ноды (observatory)."
  return 0
}

nodes_del() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  nodes_list
  local n rec
  read -r -p "Имя ноды для удаления (Enter — отмена): " n
  [ -z "$n" ] && return 0
  rec="$(nodes_load | jq -c --arg n "$n" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || { err "Нода '$n' не найдена"; return 1; }
  read -r -p "Удалить ноду '$n' из конфигурации? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  read -r -p "Удалить туннельный inbound на самой ноде (через её API)? [Y/n]: " b
  if ! [[ "$b" =~ ^[Nn] ]]; then
    local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" 2>/dev/null; then
      local inb_id
      inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
        | jq -r --arg t "inbound-$(jq -r '.tunnel.port' <<<"$rec")" '[.obj[]?|select(.tag==$t)][0].id // empty')"
      if [ -n "$inb_id" ] && node_api "$rec" "panel/api/inbounds/del/${inb_id}" POST "" "$ck" >/dev/null 2>&1; then
        ok "Инбаунд на ноде удалён"
      else
        warn "Инбаунд ноды не удалён (не критично)"
      fi
    else
      warn "Панель ноды недоступна — inbound не удалял"
    fi
    rm -f "$ck"
  fi
  read -r -p "Остановить x-ui на ноде? [y/N]: " c2
  if [[ "$c2" =~ ^[Yy] ]]; then
    node_ssh "$rec" "systemctl stop x-ui; systemctl disable x-ui" >/dev/null 2>&1 \
      && ok "x-ui на ноде остановлен" || warn "Не удалось остановить (проверьте доступ)"
  fi
  nodes_load | jq -c --arg n "$n" 'map(select(.name != $n))' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  kit_session >/dev/null 2>&1 || true
  nodes_apply_template || warn "Шаблон xray не обновился"
  # v4.5: последняя нода удалена — убираем pool-инбаунд целиком. Иначе pool
  # остаётся в панели/маршрутах, а правило balancer уже исчезло (nodes.json
  # пуст): ссылки пула продолжали бы работать, молча меняя выход на IP мастера
  local cnt0; cnt0="$(nodes_load | jq 'length' 2>/dev/null || echo 0)"
  if [ "$cnt0" -eq 0 ] && [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    warn "Это была последняя нода — убираю pool-инбаунд (переход в одиночный режим)"
    pool_remove_force || warn "Pool не убрался полностью: НОДЫ -> пункт 8 (убрать pool)"
  fi
  ok "Нода '$n' удалена; аутбаунд убран, балансировка пересчитана"
  return 0
}

# v4.5: полностью убрать pool-инбаунд — переход мастер -> одиночный.
# ВАЖНО: nodes_merge_template при пустом nodes.json уже убрал правило
# balancer, поэтому трафик pool-инбаунда пошёл бы напрямую с мастера —
# ссылки пула в подписках молча меняли бы exit-IP. Убираем всё: инбаунд
# в панели + маршрут nginx + env, затем ОБЯЗАТЕЛЬНО перегенерация подписок.
pool_remove_force() { # без вопросов — для nodes_del и меню
  local id="${XKIT_POOL_INBOUND:-}"
  [ -n "$id" ] || { warn "Pool не настроен — сервер уже в одиночном режиме"; return 0; }
  # 1) инбаунд в панели (если панель жива)
  if kit_session >/dev/null 2>&1; then
    if api_del_inbound "$id" 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Pool-инбаунд #${id} удалён из панели"
    else
      warn "Панель не удалила pool-инбаунд #${id} — проверьте вручную"
    fi
  else
    warn "Панель недоступна: pool-инбаунд #${id} остался в панели (удалите вручную), маршрут уберу"
  fi
  # 2) маршрут nginx + переменные
  routes_del "$id"
  XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  save_xkit_env
  # 3) пересобрать nginx и подписки: ссылки пула исчезают — клиенты должны
  # обновить подписку (она обновится сама при следующем запросе клиента)
  regen_conf_and_apply || { err "Конфиг nginx не применился — выполните: xkit nodes repair"; return 1; }
  sub_regen_quiet || true
  warn "Ссылки пула исчезли из подписок — клиентам нужно обновить подписку (происходит автоматически)"
  ok "Сервер переведён в одиночный режим"
  return 0
}

pool_remove() { # интерактивно (пункт меню НОДЫ -> 8)
  load_xkit_env || die "Сначала установка (пункт 1)"
  local id="${XKIT_POOL_INBOUND:-}"
  if [ -z "$id" ]; then
    warn "Pool не настроен — сервер в одиночном режиме"
    return 0
  fi
  echo ""
  warn "Будет удалён pool-инбаунд #${id}: клиенты перестанут ходить через ноды"
  read -r -p "Перевести сервер в одиночный режим? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  pool_remove_force
}

nodes_menu() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== НОДЫ: главный сервер -> туннель до нод, балансировка ===${NC}"
    echo " 1) Добавить ноду по SSH (3X-UI + Reality-туннель + балансировка)"
    echo " 2) Список нод"
    echo " 3) Health-check нод"
    echo " 4) Стратегия балансировки (roundRobin/random/leastPing/leastLoad)"
    echo " 5) Удалить ноду"
    echo " 6) Repair: переприменить конфигурацию нод (после сбоя apply)"
    echo " 7) Перепинить сертификат панели ноды (MITM-защита API)"
    echo " 8) Убрать pool — вернуть сервер в одиночный режим (v4.5)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) node_add; pause_enter ;;
      2) nodes_list; pause_enter ;;
      3) nodes_health; pause_enter ;;
      4) nodes_strategy; pause_enter ;;
      5) nodes_del; pause_enter ;;
      6) nodes_repair; pause_enter ;;
      7) local _rw; read -r -p "Имя ноды (Enter — все): " _rw; node_repin "${_rw:-all}"; pause_enter ;;
      8) pool_remove; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

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

dash_path() { printf '/d-%s/' "${XKIT_DASH_TOKEN:-CHANGE_ME}"; }

dash_user_gen() { printf 'dash%s' "$(rand_hex 2)"; }

# htpasswd для Basic Auth дашборда (apr1-хэш — понимается nginx'ом)
dash_htpasswd_write() { # из XKIT_DASH_USER / XKIT_DASH_PASS
  local u="${XKIT_DASH_USER:-}" p="${XKIT_DASH_PASS:-}" h
  [ -n "$u" ] && [ -n "$p" ] || return 1
  h="$(printf '%s\n' "$p" | openssl passwd -apr1 -stdin 2>/dev/null)" || return 1   # V-03: не в argv
  [ -n "$h" ] || return 1
  printf '%s:%s\n' "$u" "$h" > "${XKIT_DASH_HTPASSWD}"
  chown root:www-data "${XKIT_DASH_HTPASSWD}" 2>/dev/null || true
  chmod 640 "${XKIT_DASH_HTPASSWD}"
  return 0
}

dash_cron_install() {
  cat > "$XKIT_CRON_DASH" <<EOF
# XKIT: обновление веб-дашборда каждые 5 минут
*/5 * * * * root ${XKIT_BIN} dash gen >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_DASH"
  ok "Cron: дашборд обновляется каждые 5 минут ($XKIT_CRON_DASH)"
}

# состояние мастер-сервера -> JSON-объект
dash_master_json() {
  local nginx_st="inactive" xui_st="inactive" load1="" up_days=""
  local mem_total="" mem_avail="" mem_pct=0 disk_pct=0 cert_end=""
  nginx_st="$(systemctl is-active nginx 2>/dev/null || echo inactive)"
  xui_st="$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
  up_days="$(awk '{printf "%.1f", $1/86400}' /proc/uptime 2>/dev/null)"
  mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [[ "${mem_total:-}" =~ ^[0-9]+$ ]] && [[ "${mem_avail:-}" =~ ^[0-9]+$ ]] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  fi
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  [ -n "${XKIT_CRT:-}" ] && [ -r "$XKIT_CRT" ] \
    && cert_end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
  jq -nc --arg nginx "$nginx_st" --arg xui "$xui_st" --arg load "${load1:-}" \
     --argjson mem "${mem_pct:-0}" --argjson disk "${disk_pct:-0}" \
     --arg cert "$cert_end" --arg up "${up_days:-}" '
    {nginx:$nginx, xui:$xui, load1:(if $load=="" then null else $load end),
     mem_pct:$mem, disk_pct:$disk,
     cert_end:(if $cert=="" then null else $cert end),
     uptime_days:(if $up=="" then null else ($up|tonumber) end)}'
}

# статистика одной ноды (туннель + панель + трафик) -> JSON-объект в одну строку
dash_node_stats() { # $1 rec-ноды, $2 expiry-дата (или пусто), $3 заметка
  local rec="$1" exp="${2:-}" note="${3:-}"
  local name host tport status="down" lat="" panel="n/a" up=0 down=0 total=0 clients=0
  local t0 t1
  name="$(jq -r '.name' <<<"$rec")"
  host="$(jq -r '.host' <<<"$rec")"
  tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
  t0="$(date +%s%N)"
  if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
    t1="$(date +%s%N)"
    lat=$(( (t1 - t0) / 1000000 ))
    status="ok"
  fi
  if [ "$status" = "ok" ]; then
    local ck out stats
    # ВАЖНО: timeout нельзя вешать на bash-функции (только на бинарники) —
    # ограничение времени даёт сам curl (--max-time 20 внутри node_api)
    ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" >/dev/null 2>&1; then
      panel="ok"
      out="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" 2>/dev/null)"
      if jq -e '.success == true' <<<"${out:-}" >/dev/null 2>&1; then
        # total = up+down (ПОТРАЧЕННЫЙ трафик). .total инбаунда — это КВОТА
        # (у большинства 0 = безлимит) — та же формула, что в sanitize_inbounds
        stats="$(jq -r '( .obj // [] ) as $a |
          [ ([ $a[] | (.up // 0) ] | add // 0),
            ([ $a[] | (.down // 0) ] | add // 0),
            ([ $a[] | ((.up // 0) + (.down // 0)) ] | add // 0),
            ($a | length) ] | @tsv' <<<"$out" 2>/dev/null)"
        [[ "${stats:-}" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] \
          && read -r up down total clients <<<"$stats"
      else
        panel="fail"
      fi
    else
      panel="fail"
    fi
    rm -f "$ck"
  fi
  local dl
  dl="$(days_left "$exp")"
  jq -nc --arg n "$name" --arg h "$host" --arg st "$status" \
     --argjson tp "$tport" --argjson lat "${lat:-null}" --arg p "$panel" \
     --argjson up "${up:-0}" --argjson down "${down:-0}" \
     --argjson tot "${total:-0}" --argjson cl "${clients:-0}" \
     --arg exp "$exp" --argjson dl "${dl:-null}" --arg note "$note" '
    {name:$n, host:$h, tunnel_port:$tp, status:$st, latency_ms:$lat, panel:$p,
     up:$up, down:$down, total:$tot, clients:$cl,
     expiry:(if $exp=="" then null else $exp end),
     days_left:$dl,
     note:(if $note=="" then null else $note end)}'
}

# санитизированные данные для data.json: БЕЗ privateKey Reality, UUID/subId
# клиентов и прочих внутренностей — только агрегаты, которые ждёт JS
# (поля совпадают с тем, что рендерит index.html: tag/port/proto/enable/...)
dash_sanitize_inbounds() { # $1 = массив инбаундов (JSON) -> stdout
  # ИДЕМПОТЕНТНО: raw из API (.protocol, .settings-строка) -> sanitized;
  # уже sanitized (.proto, .clients-число) проходит без изменений —
  # на этом построены stale-ветка и финальный барьер перед записью.
  # Порядок веток clients КРИТИЧЕН: у raw из API поля .clients НЕТ вообще
  # (клиенты лежат внутри settings-строки), поэтому raw-детект через .settings
  # должен идти ДО прочих веток; .clients-массив (полу-sanitized) считаем длиной,
  # null/битое/пусто -> 0. Всегда возвращаем валидный JSON-массив (даже на
  # пустом входе jq молчит с кодом 0 — потому явная проверка на непустой вывод).
  local out
  out="$(jq -c '[ .[] | {
      tag: (.tag // "inbound"),
      port: .port,
      proto: (.protocol // .proto // ""),
      enable: (if (.enable == null) then true else .enable end),   # // true съел бы явный false
      up: (.up // 0),
      down: (.down // 0),
      total: ((.up // 0) + (.down // 0)),
      clients: (if (.clients|type) == "number" then .clients
                elif (.settings? // null) != null and (.settings? // "") != "" then
                  ([ ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | (.clients // []))[]) ] | length)
                elif (.clients|type) == "array" then ([ .clients[] ] | length)
                else 0 end)
    } ]' <<<"$1" 2>/dev/null)" || out=""
  [ -n "$out" ] && echo "$out" || echo '[]'
}

# топ-10 пользователей по ПОТРАЧЕННОМУ трафику (up+down из clientStats,
# а не квота .total клиента, как было раньше; clientStats бывает строкой)
dash_sanitize_users() { # $1 = массив инбаундов (JSON) -> stdout
  jq -c '[ .[] | . as $ib |
      ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | .clients // [])[]) | . as $c |
      (($ib.clientStats // [] | if type=="string" then (fromjson? // []) else . end)
        | map(select(.email == $c.email)) | .[0] // {}) as $s |
      {email:($c.email // "?"), ib:($ib.tag // "?"),
       up:($s.up // 0), down:($s.down // 0),
       total:(($s.up // 0) + ($s.down // 0)),
       enable:(if ($c.enable == null) then true else $c.enable end), expiryTime:($c.expiryTime // 0)} ]
    | sort_by(-(.total // 0)) | .[0:10]' <<<"$1" 2>/dev/null || echo '[]'
}

# whitelist полей пользователя (для users из прошлого data.json): пропускаем
# только safe-поля — дрейф формата или мусор в старом файле не попадёт в запись
dash_users_whitelist() { # $1 = массив users (JSON) -> stdout
  jq -c '[ .[] | {
      email:(.email // "?"), ib:(.ib // "?"),
      up:(.up // 0), down:(.down // 0), total:(.total // 0),
      enable:(if (.enable == null) then true else .enable end), expiryTime:(.expiryTime // 0)} ]' <<<"$1" 2>/dev/null || echo '[]'
}

# права на файлы дашборда: читать должен только nginx, не все локальные юзеры
dash_fix_perms() {
  local ngu="www-data" nguser=""
  if ! getent group www-data >/dev/null 2>&1; then
    # не-Ubuntu (CentOS и т.п.): находим юзера процесса nginx и берём ЕГО
    # ПЕРВИЧНУЮ ГРУППУ (id -gn) — юзер ≠ группа, раньше подставляли юзера в chgrp
    nguser="$(ps -eo user=,comm= 2>/dev/null | awk '$2=="nginx" && $1!="root"{print $1; exit}')"
    [ -n "$nguser" ] && ngu="$(id -gn "$nguser" 2>/dev/null || true)"
  fi
  if [ -z "$ngu" ] || ! getent group "$ngu" >/dev/null 2>&1; then
    warn "dash_fix_perms: группа nginx не найдена — файлы дашборда могут быть world-readable"
    return 0
  fi
  chgrp "$ngu" /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  local f
  for f in "${XKIT_DASH_DIR}/index.html" "${XKIT_DASH_DIR}/data.json"; do
    [ -f "$f" ] || continue
    chown root:"$ngu" "$f" 2>/dev/null || true
    chmod 640 "$f" 2>/dev/null || true
  done
  return 0
}

# построить data.json (+ восстановить index.html, если удалён)
dash_gen() {
  load_xkit_env 2>/dev/null || { err "Сначала установка (пункт 1)"; return 1; }
  [ -n "${XKIT_HOST:-}" ] || { err "Сначала установка (пункт 1)"; return 1; }
  [ "${XKIT_DASH:-0}" = "1" ] || { err "Дашборд не установлен — меню: «Веб-дашборд» (или xkit dash install)"; return 1; }
  mkdir -p -m 750 "$XKIT_DASH_DIR" 2>/dev/null || { err "Не удалось создать $XKIT_DASH_DIR"; return 1; }

  # Блокировка В SUBSHELL: fd 9 живёт только внутри ( ... ) 9>lock и закрывается
  # при его выходе. Раньше `exec 9>` держал lock в интерактивной сессии —
  # cron (xkit dash gen) не мог обновить дашборд, пока админ сидел в меню.
  (
    flock -n 9 || { warn "Предыдущее построение ещё не закончилось — пропускаю"; exit 0; }
    dash_gen_locked
  ) 9>"${XKIT_DASH_DIR}/.lock"
  return $?
}

# вся работа dash_gen под lock (вызывается в subshell из dash_gen)
dash_gen_locked() {
  # 750 СРАЗУ (без окна 755): раньше каждый запуск ставил 755, и между ним
  # и dash_fix_perms каталог был проходим для всех локальных юзеров
  # ВАЖНО: umask действует только в ЭТОМ subshell (dash_gen зовёт нас в ( ... ) 9>lock).
  # НЕ выносить umask в dash_gen вне subshell — иначе он утечёт в интерактивную
  # сессию админа и все последующие файлы кита будут создаваться с маской 640.
  umask 027   # новые файлы (data.json/index.html/.tmp) создаются сразу 640
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true

  # HTML-каркас: самовосстановление, если кто-то удалил
  if [ ! -s "${XKIT_DASH_DIR}/index.html" ]; then
    dash_write_html > "${XKIT_DASH_DIR}/index.html" 2>/dev/null || true
  fi

  local panel_st="down" inbounds="[]" users="[]" totals='{"up":0,"down":0,"total":0}'
  local stale=0
  if kit_session >/dev/null 2>&1; then
    panel_st="ok"
    # ВАЖНО: в data.json уходит САНИТИЗИРОВАННЫЙ список (см. dash_sanitize_*)
    inbounds="$(dash_sanitize_inbounds "$INBOUNDS")"
    local sums tu td
    # total = up+down (потрачено): .total инбаунда — квота, а не трафик
    sums="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$INBOUNDS" 2>/dev/null)"
    if [[ "${sums:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
      read -r tu td <<<"$sums"
      totals="$(jq -nc --argjson u "$tu" --argjson d "$td" '{up:$u,down:$d,total:($u+$d)}')"
    fi
    users="$(dash_sanitize_users "$INBOUNDS")"
    rm -f "${COOKIE_JAR:-}" 2>/dev/null || true
  else
    # Панель недоступна: НЕ затираем прошлый трафик пустотой —
    # берём инбаунды/пользователей из прошлого data.json (stale лучше пустого).
    # ВАЖНО (аудит №4): прошлый data.json мог быть записан v4.3 с СЫРЫМИ
    # инбаундами (privateKey Reality, UUID/subId). Апгрейд + падение панели
    # до первого успешного gen = stale-ветка вернула бы утечку. Поэтому
    # sanitize при ЧТЕНИИ — идемпотентно (sanitized проходит без изменений),
    # сырые данные не доходят до записи ни при каком сценарии.
    if [ -r "${XKIT_DASH_DIR}/data.json" ]; then
      local old old_inb old_users
      old="$(cat "${XKIT_DASH_DIR}/data.json" 2>/dev/null || true)"
      if jq -e '(.inbounds|type) == "array"' <<<"$old" >/dev/null 2>&1; then
        old_inb="$(jq -c '.inbounds // []' <<<"$old")"
        inbounds="$(dash_sanitize_inbounds "$old_inb")"
        if [ "$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)" -eq 0 ]; then
          # формат не распознан — пусто безопаснее, чем raw
          inbounds="[]"; users="[]"
        elif jq -e '[ .[] | has("settings") or has("streamSettings") ] | any' <<<"$old_inb" >/dev/null 2>&1; then
          # raw v4.3 ИЛИ смешанный формат (№1, аудит №1): users считаем из СЫРЫХ
          # элементов и ОБЪЕДИНЯЕМ с users sanitized-элементов прошлого data.json
          # (раньше смешанный дамп молча терял клиентов sanitized-инбаундов)
          local raw_inb
          raw_inb="$(jq -c '[ .[] | select(has("settings") or has("streamSettings")) ]' <<<"$old_inb" 2>/dev/null || echo '[]')"
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1 || old_users="[]"
          users="$( { dash_sanitize_users "$raw_inb"; printf '%s\n' "$old_users"; } \
            | jq -c -s 'add | unique_by((.email // "?")+"\u0000"+(.ib // "?")) | sort_by(-(.total // 0)) | .[0:10]' 2>/dev/null || echo '[]')"
          users="$(dash_users_whitelist "$users")"
        else
          # уже sanitized (v4.4+): оставляем users, пропустив через whitelist
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          if jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1; then
            users="$(dash_users_whitelist "$old_users")"
          else
            users="[]"
          fi
        fi
        # totals пересчитываем из уже sanitized-инбаундов (up+down)
        local s2 tu2 td2
        s2="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$inbounds" 2>/dev/null)"
        if [[ "${s2:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
          read -r tu2 td2 <<<"$s2"
          totals="$(jq -nc --argjson u "$tu2" --argjson d "$td2" '{up:$u,down:$d,total:($u+$d)}')"
        else
          totals='{"up":0,"down":0,"total":0}'
        fi
        stale=1
      fi
    fi
  fi

  local master_json
  master_json="$(dash_master_json)"

  # --- ноды: статус туннеля, латентность, панель ноды, трафик, срок аренды ---
  local nodes_json="[]" arr rec nname
  local -a recs=()
  arr="$(nodes_load)"
  if [ "$(jq 'length' <<<"${arr:-[]}" 2>/dev/null || echo 0)" -gt 0 ]; then
    while IFS= read -r rec; do
      [ -z "$rec" ] && continue
      nname="$(jq -r '.name' <<<"$rec")"
      recs+=( "$(dash_node_stats "$rec" "$(expiry_get node "$nname")" "$(expiry_note node "$nname")")" )
    done < <(jq -c '.[]' <<<"$arr")
    [ "${#recs[@]}" -gt 0 ] && nodes_json="$(printf '%s\n' "${recs[@]}" | jq -s '.' 2>/dev/null || echo '[]')"
  fi

  # --- аренда мастер-сервера ---
  local mexp expiry_json="null" mdl
  mexp="$(expiry_get master -)"
  if [ -n "$mexp" ]; then
    mdl="$(days_left "$mexp")"
    expiry_json="$(jq -nc --arg d "$mexp" --argjson dl "${mdl:-null}" \
      --arg n "$(expiry_note master -)" \
      '{date:$d, days_left:$dl, note:(if $n=="" then null else $n end)}')"
  fi

  # Последний барьер (аудит №4): идемпотентная санитизация ПЕРЕД записью —
  # закрывает любые будущие пути попадания сырых данных. users здесь НЕ
  # пересчитываем: у sanitized-инбаундов нет settings/clientStats (стал бы пуст)
  inbounds="$(dash_sanitize_inbounds "$inbounds")"

  # v4.5: явный режим на дашборде — снимает вопрос «почему таблица нод пустая»
  local mode="solo"
  [ "$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)" -gt 0 ] && mode="master"

  local data
  data="$(jq -n \
      --arg v "$XKIT_VERSION" --arg host "$XKIT_HOST" \
      --arg panel "$panel_st" --arg strat "${XKIT_BAL_STRATEGY:-roundRobin}" \
      --arg mode "$mode" \
      --arg gen_str "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
      --argjson gen "$(date +%s)" \
      --argjson master "$master_json" --argjson inb "$inbounds" \
      --argjson users "$users" --argjson nodes "$nodes_json" \
      --argjson totals "$totals" --argjson exp "$expiry_json" \
      --argjson stale "$( [ "$stale" = "1" ] && echo true || echo false )" \
      '{version:$v, host:$host, generated:$gen, generated_str:$gen_str, mode:$mode,
        panel:$panel, strategy:$strat, master:$master, totals:$totals,
        inbounds:$inb, users:$users, nodes:$nodes, expiry_master:$exp, stale:$stale}')" \
    || { err "Не удалось собрать data.json"; return 1; }

  printf '%s\n' "$data" > "${XKIT_DASH_DIR}/.data.json.tmp" \
    && mv -f "${XKIT_DASH_DIR}/.data.json.tmp" "${XKIT_DASH_DIR}/data.json" \
    || { err "Не удалось записать ${XKIT_DASH_DIR}/data.json"; return 1; }
  dash_fix_perms

  local ncnt ecnt stale_note=""
  ncnt="$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)"
  ecnt="$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)"
  [ "$stale" = "1" ] && stale_note=" (панель была недоступна — показаны данные прошлого построения)"
  ok "Дашборд построен: панель=${panel_st}, нод=${ncnt}, инбаундов=${ecnt}${stale_note}"
  log "Файлы: ${XKIT_DASH_DIR}/data.json; URL: https://${XKIT_HOST}$(dash_path)"
  return 0
}

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
  if [ -n "$htbk" ]; then cp -f "$XKIT_DASH_HTPASSWD" "$htbk" 2>/dev/null || htbk=""; fi
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

#=========================== v4.5: TELEGRAM-АЛЕРТЫ =============================
# Принцип: шлём ТОЛЬКО то, чего 3X-UI не знает (ноды/аренда/сертификат/
# дашборд). Бот-команды и уведомления о клиентах НЕ дублируем — это умеет
# сам 3X-UI (один бот, один чат, сообщения xkit помечены [XKIT]).
#
# Доставка: (1) напрямую с мастера; (2) если api.telegram.org недоступен
# (типично для РФ) — через ноды по SSH: curl крутится НА ноде, выход с её
# зарубежного IP. Живой выбор балансировщика здесь не нужен: сообщение
# одно и то же, идём по реестру до первой успешной доставки. Токен не
# попадает в argv (ps на ноде чист): curl читает URL из stdin-конфига -K -.
xkit_tg_send() { # $1 текст; 0 = доставлено или TG не настроен
  local msg="$1" token="${XKIT_TG_TOKEN:-}" chat="${XKIT_TG_CHAT:-}"
  [ -n "$token" ] && [ -n "$chat" ] || return 0   # TG не настроен — тихо
  # №9 (аудит №1): токен из env уходит в curl-конфиг — убеждаемся в формате,
  # иначе мусор/инъекция из xkit.env доедет до curl
  [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] \
    || { warn "TG-токен в env невалиден — уведомление пропущено (xkit 6 → 2 — перенастройте)"; return 1; }
  [ -n "$msg" ] || return 0
  # urlencoded POST-body (chat_id и text кодируются @uri: переводы строк -> %0A,
  # кавычек/бэкслэшей не остаётся — строка безопасна для curl-конфига)
  local data
  data="$(jq -rn --arg c "$chat" --arg t "$msg" '"chat_id=\($c|@uri)&text=\($t|@uri)"' 2>/dev/null)" || return 1
  local -a px=()
  [ -n "${XKIT_TG_PROXY:-}" ] && px=(--proxy "$XKIT_TG_PROXY")
  # (1) напрямую с мастера
  { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
    | curl -sf --max-time 8 ${px[@]+"${px[@]}"} -K - -o /dev/null 2>/dev/null && return 0
  # (2) через ноды по SSH: curl на ноде, выход с её IP
  local rec
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
      | node_ssh "$rec" 'curl -sf --max-time 10 -K - -o /dev/null' >/dev/null 2>&1 && return 0
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)
  return 1
}

# --- состояние алертов (гистерезис/дедуп): key=val построчно, chmod 600 ---
notify_state_get() { # $1 key -> value (пусто если нет)
  [ -r "$XKIT_NOTIFY_STATE" ] || return 0
  awk -F= -v k="$1" '$1==k{print substr($0, length(k)+2); exit}' "$XKIT_NOTIFY_STATE" 2>/dev/null
}

notify_state_set() { # $1 key, $2 value (пустое значение = удалить ключ)
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  # запись целиком в subshell (симметрично dash_gen_locked): umask 077 не
  # утекает в вызывающую оболочку, даже если mktemp/awk/mv провалятся
  # посередине (ревью v4.6.0 — раньше umask 022 ставился в конце основной
  # оболочки и не выполнялся при любом сбое выше)
  (
    umask 077
    tmp="$(mktemp)" || exit 0
    # удаление ключа — awk с точным сравнением $1==k (аудит №14): grep -v
    # трактовал «.» в ключе как regex и мог зацепить чужие ключи; симметрично get
    { [ -r "$XKIT_NOTIFY_STATE" ] && awk -F= -v k="$1" '$1!=k' "$XKIT_NOTIFY_STATE" 2>/dev/null
      [ -n "$2" ] && printf '%s=%s\n' "$1" "$2"; } > "$tmp"
    mv -f "$tmp" "$XKIT_NOTIFY_STATE" 2>/dev/null
  )
  chmod 600 "$XKIT_NOTIFY_STATE" 2>/dev/null
  return 0
}

# чистая функция гистерезиса ноды (тестируемая):
#   $1 прошлое состояние (up|fail1|down|пусто), $2 текущая проба (ok|fail)
#   stdout: "новое_состояние<TAB>текст_алерта" (пустой текст = не алертить).
# Логика: алерт о падении — только со 2-й проверки подряд (одиночный таймаут
# не алертим), о восстановлении — всегда один раз.
notify_node_trans() {
  local st="${1:-}" probe="$2"
  if [ "$probe" = "ok" ]; then
    case "$st" in
      down) printf 'up\tнедоступна была — восстановлена\n' ;;
      *)    printf 'up\t' ;;
    esac
  else
    case "$st" in
      down)  printf 'down\t' ;;
      fail1) printf 'down\tнедоступна (2 проверки подряд)\n' ;;
      *)     printf 'fail1\t' ;;
    esac
  fi
}

# периодическая проверка (cron каждые 10 мин): ноды (TCP-проба туннеля),
# аренда, сертификат мастера, свежесть дашборда. Алерты — только при
# ИЗМЕНЕНИИ состояния (дедуп: аренда/серт — при смене числа дней, т.е.
# максимум раз в сутки). Один прогон = максимум одно сообщение со всеми
# событиями (не поток сообщений).
# --- чистые функции алертов (тестируемые, как notify_node_trans) ---

# А1 диск: $1 = занято % -> уровень "95"|"85"|"" (пусто = всё ок)
notify_disk_verdict() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac   # не число — не алертим
  [ "$p" -ge 95 ] && { printf '95'; return 0; }
  [ "$p" -ge 85 ] && printf '85'
  return 0
}

# А2 сервис мастера: переходы. $1 old(""|up|down), $2 new(up|down) -> "state\tmsg"
# (msg пуст — ничего не слать; стиль notify_node_trans)
notify_svc_trans() {
  local old="$1" new="$2"
  if [ "$new" = "down" ]; then
    [ "$old" = "down" ] && { printf 'down\t'; return 0; }   # уже алертили — молчим
    printf 'down\tНЕ работает — проверьте systemctl status'
    return 0
  fi
  [ "$old" = "down" ] && printf 'up\tснова работает' || printf 'up\t'
  return 0
}

notify_check() {
  load_xkit_env 2>/dev/null || return 0
  [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ] || return 0   # не настроено
  local -a L=()

  # --- А2 сервисы мастера: nginx/x-ui молча умереть не должны (раньше мастер
  #     сообщал только о нодах, а о себе — через stale-дашборд, и то через 25 мин) ---
  local sv svc_st sold snew snst snmsg
  for sv in nginx x-ui; do
    svc_st="$(systemctl is-active "$sv" 2>/dev/null || true)"
    [ "$svc_st" = "active" ] && svc_st="up" || svc_st="down"
    sold="$(notify_state_get "svc:${sv}")"
    snew="$(notify_svc_trans "${sold:-}" "$svc_st")"
    snst="${snew%%$'\t'*}"; snmsg="${snew#*$'\t'}"
    [ "${sold:-}" != "$snst" ] && notify_state_set "svc:${sv}" "$snst"
    [ -n "$snmsg" ] && L+=("Сервис ${sv}: ${snmsg}")
  done

  # --- А1 диск: переполнение молча валит sqlite панели/certbot/бэкапы ---
  local dpct dlv dold
  dpct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  dlv="$(notify_disk_verdict "$dpct")"
  dold="$(notify_state_get "disk")"
  if [ -n "$dpct" ]; then
    if [ -n "$dlv" ] && [ "$dlv" != "$dold" ]; then
      if [ "$dlv" = "95" ]; then
        L+=("ДИСК: занято ${dpct}% — панель/сертификаты/бэкапы скоро начнут падать")
      else
        L+=("Диск: занято ${dpct}% (порог 85%) — почистите место")
      fi
      notify_state_set "disk" "$dlv"
    elif [ -z "$dlv" ] && [ -n "$dold" ]; then
      L+=("Диск: место освободилось (занято ${dpct}%)")
      notify_state_set "disk" ""
    fi
  fi

  # --- ноды: TCP-проба туннеля (быстро, без SSH) ---
  local rec name host tport old new nst nmsg probe
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then probe="ok"; else probe="fail"; fi
    old="$(notify_state_get "node:${name}")"
    new="$(notify_node_trans "${old:-}" "$probe")"
    nst="${new%%$'\t'*}"; nmsg="${new#*$'\t'}"
    [ "${old:-}" != "$nst" ] && notify_state_set "node:${name}" "$nst"
    [ -n "$nmsg" ] && L+=("Нода ${name}: ${nmsg}")
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)

  # --- аренда: алерт при <=7 дн. и при истечении; дедуп по числу дней ---
  local s i d note dl last
  if [ -s "$XKIT_EXPIRY" ]; then
    while IFS=$'\t' read -r s i d note; do
      [ -z "$s" ] && continue
      dl="$(days_left "$d")"
      [ -n "$dl" ] || continue
      if [ "$dl" -le 7 ]; then
        last="$(notify_state_get "exp:${s}/${i}")"
        if [ "${last:-x}" != "$dl" ]; then
          if [ "$dl" -lt 0 ]; then
            L+=("Аренда ИСТЕКЛА: ${s}/${i} (${d})${note:+ — ${note}}")
          else
            L+=("Осталось ${dl} дн. аренды: ${s}/${i} (${d})${note:+ — ${note}}")
          fi
          notify_state_set "exp:${s}/${i}" "$dl"
        fi
      fi
    done < "$XKIT_EXPIRY"
  fi

  # --- сертификат мастера: <=14 дн., дедуп по числу дней ---
  if [ -n "${XKIT_CRT:-}" ] && [ -f "$XKIT_CRT" ]; then
    local cend cdl
    cend="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$cend" ]; then
      cdl=$(( ( $(date -d "$cend" +%s) - $(date +%s) ) / 86400 ))
      if [ "$cdl" -le 14 ]; then
        last="$(notify_state_get "cert:master")"
        if [ "${last:-x}" != "$cdl" ]; then
          L+=("Сертификат ${XKIT_HOST} истекает через ${cdl} дн. (${cend})")
          notify_state_set "cert:master" "$cdl"
        fi
      fi
    fi
  fi

  # --- дашборд: data.json не обновлялся >25 мин (5 пропусков cron) ---
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    local gen age
    gen="$(jq -r '.generated // 0' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
    case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
    if [ "$gen" -gt 0 ]; then
      age=$(( $(date +%s) - gen ))
      if [ "$age" -gt 1500 ]; then
        if [ "$(notify_state_get "dash")" != "stale" ]; then
          L+=("Дашборд не обновляется: данные от $(date -d "@$gen" '+%d.%m %H:%M' 2>/dev/null || echo '?')")
          notify_state_set "dash" "stale"
        fi
      else
        if [ "$(notify_state_get "dash")" = "stale" ]; then
          notify_state_set "dash" ""
          L+=("Дашборд снова обновляется")
        fi
      fi
    fi
  fi

  [ "${#L[@]}" -eq 0 ] && return 0
  local msg="[XKIT] ${XKIT_HOST:-сервер}" ln
  for ln in "${L[@]}"; do msg+=$'\n'"${ln}"; done
  if xkit_tg_send "$msg"; then
    ok "Telegram: отправлено (событий: ${#L[@]})"
    return 0
  fi
  warn "Telegram: доставить не удалось (${#L[@]} событий) — ни напрямую, ни через ноды"
  return 1
}

notify_cron_install() {
  cat > "$XKIT_CRON_NOTIFY" <<EOF
# XKIT: Telegram-алерты (ноды/аренда/сертификат/дашборд) каждые 10 минут
*/10 * * * * root ${XKIT_BIN} telegram check >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_NOTIFY"
  ok "Cron: алерты проверяются каждые 10 минут ($XKIT_CRON_NOTIFY)"
}

notify_cron_remove() { rm -f "$XKIT_CRON_NOTIFY" 2>/dev/null; return 0; }

telegram_setup() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo -e "${YELLOW}=== Telegram-уведомления ===${NC}"
  if [ -n "${XKIT_TG_TOKEN:-}" ]; then
    ok "Уже настроено (чат ${XKIT_TG_CHAT}) — повторный запуск заменит реквизиты"
  fi
  echo "Приходит только то, чего 3X-UI НЕ знает: нода упала/восстановилась,"
  echo "аренда <=7 дн. или истекла, сертификат <=14 дн., дашборд stale."
  echo "Бот-команды и уведомления о клиентах остаются у 3X-UI (не дублируем)."
  echo "Доставка: с мастера напрямую; если не проходит — через ноды (их IP)."
  local tok chat px
  read -r -p "Bot token (от @BotFather, вид 123456:ABC-...): " tok
  [[ "$tok" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] || { err "Токен не похож на валидный"; return 1; }
  read -r -p "Chat ID (число от @userinfobot, или @имя_канала): " chat
  [[ "$chat" =~ ^-?[0-9]+$|^@[A-Za-z0-9_]{4,64}$ ]] || { err "Chat ID: число (личка/группа) или @имя_канала"; return 1; }
  read -r -p "Прокси для api.telegram.org (http://... или socks5://...; Enter — без прокси): " px
  XKIT_TG_TOKEN="$tok"; XKIT_TG_CHAT="$chat"; XKIT_TG_PROXY="$px"
  save_xkit_env
  notify_cron_install
  log "Отправляю тестовое сообщение..."
  if xkit_tg_send "[XKIT] ${XKIT_HOST:-сервер}: Telegram настроен. Алерты: ноды, аренда, сертификат, дашборд."; then
    ok "Тестовое сообщение доставлено"
  else
    warn "Прямая отправка не прошла. Если api.telegram.org недоступен с этого"
    warn "сервера — сообщения пойдут через ноды (после их добавления)."
    warn "Проверка вручную: xkit telegram check"
  fi
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_off() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "${XKIT_TG_TOKEN:-}" ] || { warn "Telegram не настроен"; return 0; }
  local a
  read -r -p "Выключить Telegram-уведомления (токен удалится)? [y/N]: " a
  [[ "$a" =~ ^[Yy] ]] || return 0
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""
  save_xkit_env
  notify_cron_remove
  ok "Telegram-уведомления выключены (история состояний: ${XKIT_NOTIFY_STATE})"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_menu() {
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== TELEGRAM-АЛЕРТЫ (ноды/аренда/сертификат/дашборд) ===${NC}"
    if [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ]; then
      ok "Настроено: чат ${XKIT_TG_CHAT}${XKIT_TG_PROXY:+, прокси ${XKIT_TG_PROXY}}"
    else
      warn "Не настроено (xkit telegram setup)"
    fi
    echo " 1) Настроить / заменить (токен + chat_id + тестовое сообщение)"
    echo " 2) Проверить сейчас (то же, что cron каждые 10 минут)"
    echo " 3) Отправить тестовое сообщение"
    echo " 4) Выключить (токен удаляется, cron убирается)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) telegram_setup; pause_enter ;;
      2) load_xkit_env >/dev/null 2>&1 || true; notify_check; pause_enter ;;
      3) load_xkit_env >/dev/null 2>&1 || true
         if xkit_tg_send "[XKIT] тест: канал доставки работает"; then ok "Доставлено"; else err "Не доставлено (напрямую и через ноды)"; fi
         pause_enter ;;
      4) telegram_off; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

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

#=========================== ОБНОВЛЕНИЕ =======================================
# v5.0.0: обновляются ОБА файла — xkit.sh (ядро) и xkit_menu.sh (модуль меню).
# Пломба xkit.sh.sha256 — формат sha256sum, 2 строки; строка 1 = xkit.sh,
# строка 2 = xkit_menu.sh (старые версии читают строку 1 — совместимость)
xkit_self_update() { # $1 base-url (необязательно; иначе XKIT_REPO_URL из xkit.env)
  require_root
  load_xkit_env 2>/dev/null || true   # свежая SSH-сессия: XKIT_REPO_URL живёт в xkit.env
  local base="${1:-${XKIT_REPO_URL:-}}"
  if [ -z "$base" ]; then
    err "Не знаю, откуда обновляться. Укажите URL репозитория:"
    err "  xkit update https://raw.githubusercontent.com/НИК/xkit/main"
    err "  (или переустановите через install.sh — он запомнит источник)"
    return 1
  fi
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  # K-02: http:// наружу запрещён (локальные зеркала для тестов — можно)
  case "$base" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
    http://*) err "K-02: обновление по http:// запрещено — укажите https://-источник"; return 1 ;;
  esac
  local tmp tmpm sumf
  tmp="$(mktemp /tmp/.xkit-update.XXXXXX)" || return 1
  log "Скачиваю ${base}/xkit.sh ..."
  curl -fsSL "${base}/xkit.sh" -o "$tmp" || { err "Скачать не удалось: ${base}/xkit.sh"; rm -f "$tmp"; return 1; }
  # модуль меню — обязателен с v5.0.0 (UI-слой вынесен в отдельный файл)
  tmpm="$(mktemp /tmp/.xkit-menu.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if ! curl -fsSL "${base}/xkit_menu.sh" -o "$tmpm"; then
    if [ -r "${XKIT_MENU_DIR}/xkit_menu.sh" ]; then
      warn "xkit_menu.sh в репо не найден — оставляю установленный (${XKIT_MENU_DIR})"
      tmpm=""
    else
      err "Скачать не удалось: ${base}/xkit_menu.sh (файл меню)"
      err "Залейте xkit_menu.sh в репозиторий (см. GITHUB_SETUP.md) или обновите снова позже"
      rm -f "$tmp" "$tmpm"; return 1
    fi
  fi
  local sumf="${tmp}.sha256" want got
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk 'NR==1{print $1}' "$sumf")"; got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      ok "SHA-256 проверен: xkit.sh $got"
    else
      err "SHA-256 НЕ совпал — обновление отменено (файл битый или изменён)"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    if [ -n "$tmpm" ]; then
      want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
      got="$(sha256sum "$tmpm" | awk '{print $1}')"
      if [ -z "$want" ]; then
        # K-02: меню без суммы не ставим — оставляем установленное
        warn "В пломбе нет строки xkit_menu.sh — меню НЕ обновляю (оставляю установленное)"
        rm -f "$tmpm"; tmpm=""
      elif [ "$want" != "$got" ]; then
        err "SHA-256 xkit_menu.sh НЕ совпал — обновление отменено"
        rm -f "$tmp" "$sumf" "$tmpm"; return 1
      else
        ok "SHA-256 проверен: xkit_menu.sh $got"
      fi
    fi
  else
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      # K-02: fail-closed — без пломбы код не ставится
      err "xkit.sh.sha256 недоступен — обновление ОТМЕНЕНО (K-02: без суммы код не ставится)"
      err "Осознанный обход: XKIT_ALLOW_UNVERIFIED=1 xkit update"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    warn "xkit.sh.sha256 недоступен, но задан XKIT_ALLOW_UNVERIFIED=1 — ставлю без проверки"
  fi
  bash -n "$tmp" || { err "Новый файл не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1; }
  if [ -n "$tmpm" ]; then
    bash -n "$tmpm" || { err "Новый xkit_menu.sh не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf" "$tmpm"; return 1; }
  fi
  local nv; nv="$(grep -m1 '^XKIT_VERSION=' "$tmp" | cut -d'"' -f2)"; nv="${nv:-?}"
  if [ "$nv" = "$XKIT_VERSION" ] && [ "${XKIT_FORCE:-0}" != "1" ]; then
    ok "Уже установлена версия $nv (принудительно: XKIT_FORCE=1 xkit update)"
    rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
    return 0
  fi
  [ -f "$XKIT_BIN" ] && cp -f "$XKIT_BIN" "${XKIT_BIN}.bak"
  if ! install -m 700 "$tmp" "${XKIT_BIN}.new" || ! mv -f "${XKIT_BIN}.new" "$XKIT_BIN"; then
    err "Не удалось заменить $XKIT_BIN"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1
  fi
  if [ -n "$tmpm" ]; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || true
    [ -f "${XKIT_MENU_DIR}/xkit_menu.sh" ] && cp -f "${XKIT_MENU_DIR}/xkit_menu.sh" "${XKIT_MENU_DIR}/xkit_menu.sh.bak"
    if install -m 700 "$tmpm" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
       && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню обновлён: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось обновить ${XKIT_MENU_DIR}/xkit_menu.sh — меню докачается при первом запуске xkit"
    fi
  fi
  rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
  # v5.2: после ядра/меню атомарно обновляем модуль протоколов и TUI.
  xkit_extras_install || warn "Дополнительные компоненты обновятся при следующем запуске"
  ok "Обновлено: v${XKIT_VERSION} -> v${nv} ($XKIT_BIN); резервная копия: ${XKIT_BIN}.bak"
  ok "Конфиг nginx, состояние и подписки не тронуты"
  return 0
}

#=========================== МЕНЮ: МОДУЛЬНЫЙ UI (v5.0.0) ======================
# Меню живёт в отдельном файле xkit_menu.sh (UI-слой), чтобы xkit.sh не
# раздувался: правки меню не трогают ядро. Порядок поиска:
#   1) рядом с самим xkit.sh   2) $XKIT_MENU_DIR (/usr/local/lib/xkit)
#   3) каталог команды xkit    4) /etc/xkit
# Не нашли — докачиваем с XKIT_REPO_URL со сверкой SHA-256 (строка 2 пломбы).

# V-02 (аудит №2): код под root грузится ТОЛЬКО из доверенных мест — владелец
# root, без group/world-write, каталоги /tmp, /var/tmp, /dev/shm запрещены
xkit_dir_trusted() { # $1 каталог, $2 файл -> 0 = доверенный
  local d="$1" f="$2" st myuid
  case "$d" in /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run/shm*) return 1 ;; esac
  myuid="$(id -u 2>/dev/null || echo 0)"
  st="$(stat -Lc '%u %a' "$d" 2>/dev/null)" || return 1
  # владелец = root ИЛИ текущий пользователь (dev-каталог в своей домашке —
  # доверенно; ЧУЖОЙ владелец при запуске под root — нет)
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  st="$(stat -Lc '%u %a' "$f" 2>/dev/null)" || return 1
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  return 0
}

xkit_menu_src() { # -> печатает путь к найденному xkit_menu.sh; 1 = не нашли
  local d f self
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  # №19 (аудит №1): dirname вместо ${XKIT_BIN%/*} (без слэша давал мусорный путь)
  for d in "$(dirname "$self")" "${XKIT_MENU_DIR}" "$(dirname -- "${XKIT_BIN:-/usr/local/bin/xkit}" 2>/dev/null)" "/etc/xkit"; do
    [ -n "$d" ] || continue
    f="$d/xkit_menu.sh"
    [ -r "$f" ] || continue
    # V-02: подозрительное расположение (например, /tmp) — пропускаем кандидата
    if ! xkit_dir_trusted "$d" "$f"; then
      warn "Пропускаю $f: каталог/файл не доверенные (owner/mode, V-02)"
      continue
    fi
    printf '%s\n' "$f"; return 0
  done
  return 1
}

xkit_menu_fetch() { # авто-докачка меню (потеря файла / обновление со старой версии)
  local base="${XKIT_REPO_URL:-}"
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
  local tmp sumf want got
  tmp="$(mktemp /tmp/.xkit-menu.XXXXXX)" || return 1
  curl -fsSL "${base}/xkit_menu.sh" -o "$tmp" || { rm -f "$tmp"; return 1; }
  sumf="$(mktemp /tmp/.xkit-menu-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      err "SHA-256 xkit_menu.sh НЕ совпал — докачка отменена"
      rm -f "$tmp" "$sumf"; return 1
    fi
    if [ -z "$want" ]; then
      # K-02: без суммы докачка fail-open'ом больше не проходит
      err "В пломбе нет строки xkit_menu.sh — докачка отменена (K-02)"
      rm -f "$tmp" "$sumf"; return 1
    fi
  else
    err "Сумма xkit_menu.sh недоступна — докачка отменена (K-02; осознанный обход: XKIT_ALLOW_UNVERIFIED=1)"
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      rm -f "$tmp"; return 1
    fi
    warn "XKIT_ALLOW_UNVERIFIED=1 — ставлю меню без проверки"
  fi
  bash -n "$tmp" 2>/dev/null || { err "xkit_menu.sh не проходит bash -n — докачка отменена"; rm -f "$tmp" "$sumf"; return 1; }
  local rc=0
  # F-1 (аудит №2): раньше local rc=$? стоял после if и всегда был 0 —
  # неудачная установка меню маскировалась «ок»
  if install -m 700 "$tmp" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
     && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
    ok "Модуль меню докачан: ${XKIT_MENU_DIR}/xkit_menu.sh"
  else
    err "Не удалось установить xkit_menu.sh в ${XKIT_MENU_DIR}"
    rc=1
  fi
  rm -f "$tmp" "$sumf"
  return $rc
}

xkit_menu_install() { # положить модуль меню в $XKIT_MENU_DIR (вызывается установщиком)
  local self src
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")/xkit_menu.sh"
  if [ -r "$src" ] && xkit_dir_trusted "$(dirname "$src")" "$src"; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
    # F-2 (аудит №2): раньше cp без ветки неудачи — функция возвращала 0 даже при сбое
    if cp -f "$src" "${XKIT_MENU_DIR}/xkit_menu.sh" && chmod 700 "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось скопировать модуль меню в ${XKIT_MENU_DIR}"
      return 1
    fi
    return 0
  fi
  [ -r "$src" ] && warn "Локальный $src не доверенный (V-02) — меню будет докачано из репо"
  # рядом со скриптом нет (установка из пайпа) — докачаем с репо
  xkit_menu_fetch \
    || warn "xkit_menu.sh не найден рядом и не докачан — меню скачается при первом запуске xkit"
  return 0
}

xkit_load_menu() { # подключить модуль меню (source); 1 = не нашли (ошибка уже напечатана)
  local f
  if f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  # load_xkit_env при ОТСУТСТВИИ env-файла (свежая машина) затирает
  # XKIT_REPO_URL и выходит раньше восстановления — репо-адрес из внешнего
  # env (install.sh пробрасывает его явно) терялся, авто-докачка молчала
  local _repo="${XKIT_REPO_URL:-}"
  load_xkit_env >/dev/null 2>&1 || true
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  if xkit_menu_fetch && f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  err "Не найден файл меню xkit_menu.sh (ищу рядом со скриптом, в ${XKIT_MENU_DIR} и /etc/xkit)"
  err "Обновите установку:  sudo xkit update   либо переустановите через install.sh"
  return 1
}

#=========================== V5.2: TUI И ПРОТОКОЛЫ ============================
xkit_component_fetch() { # $1 имя в репо, $2 конечный файл; SHA-256 обязателен
  local base="${XKIT_REPO_URL:-}" name="$1" dst="$2" tmp sumf want got
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  case "$base" in http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;; http://*) return 1 ;; esac
  tmp="$(mktemp /tmp/.xkit-component.XXXXXX)" || return 1
  sumf="$(mktemp /tmp/.xkit-component-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  curl -fsSL "${base}/${name}" -o "$tmp" && curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" || { rm -f "$tmp" "$sumf"; return 1; }
  want="$(awk -v n="$name" '$2==n{print $1;exit}' "$sumf")"
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { err "SHA-256 ${name} не совпал или отсутствует"; rm -f "$tmp" "$sumf"; return 1; }
  case "$name" in *.sh) bash -n "$tmp" || { rm -f "$tmp" "$sumf"; return 1; } ;; esac
  mkdir -p "$(dirname "$dst")" && install -m 700 "$tmp" "${dst}.new" && mv -f "${dst}.new" "$dst" || { rm -f "$tmp" "$sumf"; return 1; }
  rm -f "$tmp" "$sumf"
  ok "Компонент установлен: $dst"
}

xkit_extras_install() { # протоколы + TUI текущей архитектуры
  local self src arch name rc=0
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")"
  mkdir -p "$XKIT_MENU_DIR" || return 1
  if [ -r "$src/xkit_protocols.sh" ] && xkit_dir_trusted "$src" "$src/xkit_protocols.sh"; then
    [ ! -f "$XKIT_PROTOCOLS_FILE" ] || cp -f "$XKIT_PROTOCOLS_FILE" "${XKIT_PROTOCOLS_FILE}.bak"
    install -m 700 "$src/xkit_protocols.sh" "$XKIT_PROTOCOLS_FILE" || rc=1
  else
    xkit_component_fetch xkit_protocols.sh "$XKIT_PROTOCOLS_FILE" || rc=1
  fi
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) warn "TUI: архитектура $(uname -m) не поддерживается"; return "$rc" ;; esac
  name="xkit-tui-linux-${arch}"
  if [ -r "$src/$name" ] && xkit_dir_trusted "$src" "$src/$name"; then
    [ ! -f "$XKIT_TUI_FILE" ] || cp -f "$XKIT_TUI_FILE" "${XKIT_TUI_FILE}.bak"
    install -m 700 "$src/$name" "$XKIT_TUI_FILE" || rc=1
  else
    xkit_component_fetch "$name" "$XKIT_TUI_FILE" || rc=1
  fi
  return "$rc"
}

xkit_protocols_load() {
  local f="$XKIT_PROTOCOLS_FILE" self
  if [ ! -r "$f" ]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    [ -r "$(dirname "$self")/xkit_protocols.sh" ] && f="$(dirname "$self")/xkit_protocols.sh"
  fi
  if [ -r "$f" ] && xkit_dir_trusted "$(dirname "$f")" "$f"; then
    XKIT_PROTOCOLS_FILE="$f"; . "$f"; return 0
  fi
  err "Модуль протоколов не найден или не доверен: $f (выполните xkit update)"
  return 1
}

xkit_tui_run() {
  [ "${XKIT_TUI:-1}" = 1 ] && [ "${FORCE_CLASSIC:-0}" != 1 ] || return 1
  [ -t 0 ] && [ -t 1 ] || return 1
  if [ ! -x "$XKIT_TUI_FILE" ]; then
    local self0 arch0
    self0="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    case "$(uname -m)" in x86_64) arch0=amd64 ;; aarch64|arm64) arch0=arm64 ;; *) arch0=unknown ;; esac
    [ -r "$(dirname "$self0")/xkit-tui-linux-${arch0}" ] && XKIT_TUI_FILE="$(dirname "$self0")/xkit-tui-linux-${arch0}"
  fi
  if [ ! -x "$XKIT_TUI_FILE" ] && [ "$(id -u)" = 0 ]; then
    load_xkit_env >/dev/null 2>&1 || true
    xkit_extras_install >/dev/null 2>&1 || true
  fi
  [ -x "$XKIT_TUI_FILE" ] && xkit_dir_trusted "$(dirname "$XKIT_TUI_FILE")" "$XKIT_TUI_FILE" || return 1
  local self; self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  "$XKIT_TUI_FILE" --xkit "$self"
}

xkit_snapshot() { # только агрегаты; без UUID, privateKey, паролей и токенов
  load_xkit_env >/dev/null 2>&1 || true
  local host="${XKIT_HOST:-}" mode=solo nodes=0 nodes_ok=0 clients=0 cert_days=-1 backup_hours=-1
  local nginx=false xui=false xray=false protocols='[]' inbounds=''
  systemctl is-active --quiet nginx 2>/dev/null && nginx=true
  systemctl is-active --quiet x-ui 2>/dev/null && xui=true
  pgrep -x xray >/dev/null 2>&1 && xray=true
  if [ -r "$XKIT_NODES" ]; then nodes="$(jq 'length' "$XKIT_NODES" 2>/dev/null || echo 0)"; fi
  [[ "$nodes" =~ ^[0-9]+$ ]] || nodes=0
  [ "$nodes" -gt 0 ] && mode=master
  if [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
  fi
  [[ "$nodes_ok" =~ ^[0-9]+$ ]] || nodes_ok=0
  if [ -r "${XKIT_CRT:-}" ]; then
    local end_epoch now_epoch
    end_epoch="$(date -d "$(openssl x509 -in "$XKIT_CRT" -noout -enddate 2>/dev/null | cut -d= -f2-)" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"; [ "$end_epoch" -gt 0 ] && cert_days=$(( (end_epoch-now_epoch)/86400 ))
  fi
  local latest; latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'xkit-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [ -n "$latest" ]; then backup_hours=$(( ($(date +%s)-$(stat -c %Y "$latest" 2>/dev/null || date +%s))/3600 )); fi
  if kit_session >/dev/null 2>&1; then
    inbounds="$(api_list 2>/dev/null || true)"
    clients="$(jq '[.[]?|(.settings|fromjson?|.clients[]?)|.email]|unique|length' <<<"$inbounds" 2>/dev/null || echo 0)"
  fi
  [[ "$clients" =~ ^[0-9]+$ ]] || clients=0
  if xkit_protocols_load >/dev/null 2>&1; then
    protocols="$(protocols_snapshot_json 2>/dev/null || echo '[]')"
  fi
  jq -nc --arg host "$host" --arg mode "$mode" --arg generated "$(date -Iseconds)" \
    --argjson nodes "$nodes" --argjson nodes_ok "$nodes_ok" --argjson clients "$clients" \
    --argjson nginx "$nginx" --argjson xui "$xui" --argjson xray "$xray" \
    --argjson cert_days "$cert_days" --argjson backup_hours "$backup_hours" --argjson protocols "$protocols" \
    '{host:$host,mode:$mode,nodes:$nodes,nodes_ok:$nodes_ok,clients:$clients,nginx:$nginx,xui:$xui,xray:$xray,cert_days:$cert_days,backup_hours:$backup_hours,protocols:$protocols,generated:$generated}'
}

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
