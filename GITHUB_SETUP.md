# Хостинг на GitHub: установка одной строкой

Эта инструкция — как выложить `xkit` в репозиторий GitHub (для проекта уже
используется репо **kalsifar/xkit** — ник вписан в `install.sh`), чтобы на любом
чистом сервере установка работала одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/kalsifar/xkit/main/install.sh | sudo bash
```

`install.sh` сам скачает ядро, меню, модуль протоколов и TUI нужной архитектуры
из того же репозитория, проверит SHA-256 каждого компонента, отдаст установщику
настоящий терминал (пароль sudo и вопросы мастера установки работают даже при
«curl | bash») и запустит `xkit install`. Там же запомнится источник установки —
потом достаточно `sudo xkit update`.

---

## Шаг 1. Создайте репозиторий

1. Зайдите на github.com под своим аккаунтом → кнопка **New repository**.
2. Имя: `xkit` (можно любое — тогда оно появится во всех командах ниже вместо
   `xkit`). Видимость: **Public**.
3. Не добавляйте README/license при создании (файлы свои). **Create repository**.

> **Почему Public?** `raw.githubusercontent.com` отдаёт файлы приватных
> репозиториев только с токеном — установка одной строкой на приватном репо не
> заработает. В репо нет секретов: это те же открытые скрипты, что лежат у вас.
> Не хотите публиковать код — хостите на своём сервере (раздел «Альтернатива»).

## Шаг 2. Загрузите файлы

В корень репозитория (не в подпапку!) кладутся **обязательные** файлы:

| Файл | Зачем |
|---|---|
| `install.sh` | обёртка для установки одной строкой с pin-хэшами релиза |
| `xkit.sh` | ядро: API, установка, nginx, ноды, дашборд |
| `xkit_menu.sh` | классическое Bash-меню и fallback |
| `xkit_protocols.sh` | профили REALITY/XHTTP, AmneziaWG и Hysteria 2 |
| `xkit-tui-linux-amd64` | полноэкранный TUI для Linux x86_64 |
| `xkit-tui-linux-arm64` | полноэкранный TUI для Linux ARM64 |
| `xkit.sh.sha256` | пломба в формате `sha256sum`, **5 строк**: ядро, меню, протоколы и оба TUI |
| `README.md` | описание проекта (опционально, но удобно) |

Папки `tests/` и `tui/`, а также `build.sh` можно залить тоже — на работу
установки они не влияют, но нужны для воспроизводимой сборки и регресса.

**Через веб-интерфейс** (без git): на странице репо нажмите **Add file →
Upload files**, перетащите файлы, внизу **Commit changes**.

**Через git** (если удобнее командой, из папки с файлами):

```bash
git init -b main
git add install.sh xkit.sh xkit_menu.sh xkit_protocols.sh \
  xkit-tui-linux-amd64 xkit-tui-linux-arm64 xkit.sh.sha256 \
  src \
  README.md GITHUB_SETUP.md CHANGES.md build.sh tests tui
git commit -m "xkit v5.3.1"
git remote add origin https://github.com/kalsifar/xkit.git
git push -u origin main
```

> Ветка должна называться **main** — именно она зашита в команды ниже.
> Назвали иначе (например, `master`) — замените `main` во всех URL.

## Шаг 3. Ник репозитория в install.sh — уже вписан

В `install.sh` источник уже настроен на репо проекта:

```bash
XKIT_BASE="${XKIT_BASE:-https://raw.githubusercontent.com/kalsifar/xkit/main}"
```

Править его нужно ТОЛЬКО если вы выкладываете код под другим аккаунтом/именем
репо (форк): замените `kalsifar/xkit` на своё. Три способа:

- **На GitHub:** откройте `install.sh` в репо → карандаш (Edit) → поправьте
  строку → **Commit changes**.
- **Локально до пуша:** `sed -i 's|kalsifar/xkit|МОЙ_НИК/МОЕ_РЕПО|' install.sh` —
  и закоммитьте.
- **Не менять вообще:** тогда при каждом запуске задавайте источник вручную
  (`XKIT_BASE=https://raw.githubusercontent.com/МОЙ_НИК/МОЕ_РЕПО/main bash install.sh`
  или первым аргументом).

Если ник в install.sh случайно стёрт (там снова появится YOUR_USERNAME) — это
не тихая поломка: скрипт проверяет и печатает подсказку вместо попытки скачать
мусорный URL.

## Шаг 4. Проверьте ссылки

Откройте в браузере (или `curl -fsSL -o /dev/null -w '%{http_code}\n' URL`):

```
https://raw.githubusercontent.com/kalsifar/xkit/main/install.sh
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit.sh
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit_menu.sh
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit_protocols.sh
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit-tui-linux-amd64
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit-tui-linux-arm64
https://raw.githubusercontent.com/kalsifar/xkit/main/xkit.sh.sha256
```

Все семь должны отдавать содержимое (200). Если 404 — смотрите «Частые проблемы».

## Шаг 5. Установка на сервере

Чистый сервер (Ubuntu 24.04+), обычный пользователь с sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/kalsifar/xkit/main/install.sh | sudo bash
```

Пароль sudo спросит сразу — пайп не мешает: sudo читает его с терминала, а
`install.sh` передаёт установщику настоящий TTY, так что все вопросы мастера
установки (адрес сервера — реальный IP показывается пунктом 1, сценарий
«одиночный/мастер» и т.д.) работают как при обычном запуске.

**Неинтерактивно (CI / cloud-init / скрипт)** — флаги после `--`, иначе bash
съест `-y` как свой аргумент:

```bash
curl -fsSL https://raw.githubusercontent.com/kalsifar/xkit/main/install.sh | sudo bash -s -- -y
```

`-y` = согласие на вопросы (`XKIT_YES=1`), можно добавить `--force` — установка
поверх без меню «уже установлен». После установки зайдите по SSH — меню `xkit`
появится само (или наберите `xkit`).

**Зафиксировать конкретную версию** (репо уехал вперёд, серверы ставят ровно
то, что проверяли) — тег + URL до `xkit.sh` вторым аргументом:

```bash
# один раз в репо:
git tag v5.3.1 && git push origin v5.3.1

# установка ровно этой версии:
curl -fsSL https://raw.githubusercontent.com/kalsifar/xkit/v5.3.1/install.sh | \
  sudo bash -s -- https://raw.githubusercontent.com/kalsifar/xkit/v5.3.1/xkit.sh
```

Источник запоминается (`XKIT_REPO_URL`) — `xkit update` на таком сервере тоже
будет тянуть тег, а не main.

---

## Как это работает (и почему sha256 обязателен)

Цепочка установки:

```
curl | sudo bash  →  install.sh
                      1. ищет компоненты рядом с собой (локальный запуск)
                      2. иначе качает ядро, меню, протоколы и TUI архитектуры
                      3. качает $XKIT_BASE/xkit.sh.sha256 и сверяет суммы;
                         сверяет также pin-хэши, встроенные в install.sh
                         (сумма отсутствует/не совпала — установка отменяется)
                      4. bash -n для shell-файлов → запуск xkit install от root
                      5. REPO ($XKIT_BASE без /xkit.sh) пишется в
                         /etc/xkit/xkit.env как XKIT_REPO_URL
```

Пункт 3 — почему в репо должна лежать **актуальная** пломба: забыли пересчитать
суммы после правки любого компонента — новые установки будут падать с «SHA-256
НЕ совпал». Отсутствующая пломба или отсутствующая в ней строка тоже означают
отказ: непроверенный код молча не устанавливается.

`XKIT_REPO_URL` из пункта 5 — канал обновлений: `sudo xkit update` качает ядро и
меню, сверяет их с пломбой, сравнивает версии и атомарно заменяет
`/usr/local/bin/xkit` и `/usr/local/lib/xkit/xkit_menu.sh`, после чего устанавливает
`xkit_protocols.sh` и TUI текущей архитектуры. Бэкапы `.bak` остаются; конфиг nginx,
панель, подписки и cron не трогаются.

> Обновление со старой версии (v4.x): старый `xkit update` знает только об
> `xkit.sh` — это нормально. После такого обновления xkit при первом запуске
> сам докачает `xkit_menu.sh` со сверкой суммы (строка 2 пломбы).

## Обновление версии в репозитории

Поменяли любой компонент (или скачали новые из полного пакета) — выполните
воспроизводимую сборку: она прогонит Go-тесты, соберёт оба TUI, пересчитает пломбу
и обновит pin-хэши в `install.sh`. Запушьте изменённые файлы **одним коммитом**:

```bash
bash build.sh
sha256sum -c xkit.sh.sha256
git add install.sh xkit.sh xkit_menu.sh xkit_protocols.sh \
  xkit-tui-linux-amd64 xkit-tui-linux-arm64 xkit.sh.sha256 src
git commit -m "xkit v5.3.1"
git push
```

На уже установленных серверах после этого достаточно:

```bash
sudo xkit update        # из запомненного репозитория
```

…или повторить установочную команду из Шага 5 (на установленном сервере она
предложит меню: обновить / переустановить чисто / починить поверх).

Порядок «сначала тег»:

```bash
git tag v5.3.1 && git push origin v5.3.1   # зафиксировать
git push                                    # и только потом main (по желанию)
```

## Альтернатива: свой сервер вместо GitHub

GitHub не обязателен. Любая папка за nginx с семью файлами (`install.sh`,
`xkit.sh`, `xkit_menu.sh`, `xkit_protocols.sh`, оба TUI-бинарника и
`xkit.sh.sha256`) работает так же:

```bash
curl -fsSL https://ВАШ_ДОМЕН/xkit/install.sh | sudo bash
```

Плюсы: полный контроль (логи доступа, свои правила firewall), не зависит от
доступности GitHub из сети сервера. `XKIT_REPO_URL` запомнит ваш домен —
`xkit update` будет ходить туда же.

Можно использовать и CDN (например
`https://cdn.jsdelivr.net/gh/kalsifar/xkit@main/install.sh`) — но jsDelivr кэширует
файлы до 12 часов, обновления доезжают с задержкой. Для канала обновлений
`raw.githubusercontent.com` или свой сервер надёжнее.

## Частые проблемы

| Симптом | Причина / лечение |
|---|---|
| `curl` отдаёт 404 | ветка не `main` (замените в URL), файл не в корне репо, репо приватное, или опечатка в нике. Проверьте Шаг 4 |
| «Не найден файл меню/протоколов/TUI» | в репо нет обязательного компонента — залейте все файлы из таблицы Шага 2, затем выполните `sudo xkit update` |
| «install.sh не настроен: …стёрт ник…» | в install.sh снова стоит YOUR_USERNAME — верните `kalsifar/xkit` (или ваш ник при форке) |
| «SHA-256 НЕ совпал» | в репо лежит старая пломба или устаревший pin в `install.sh`. Выполните `bash build.sh` и запушьте все изменённые компоненты вместе |
| «Не найдена SHA-256» / установка отменена | нет `xkit.sh.sha256` либо в нём нет строки нужного компонента — опубликуйте актуальную пятистрочную пломбу |
| Пароль sudo не спрашивается / «sudo: no tty» | запускаете не с консоли сервера (например, из CI без TTY). Для таких сценариев — `sudo bash -s -- -y` от root или настройте NOPASSWD |
| Установка прошла, `xkit: command not found` | перезайдите по SSH (прописывается в профиль) или запустите `/usr/local/bin/xkit` |
| `xkit update` берёт не оттуда | смотрят источник: `grep XKIT_REPO_URL /etc/xkit/xkit.env`; переопределить: `sudo xkit update https://raw.githubusercontent.com/kalsifar/xkit/main` |

## Чек-лист перед публикацией

- [ ] все семь файлов из Шага 4 — в **корне** репо, ветка `main`
- [ ] ник `kalsifar/xkit` в `install.sh` вписан (или ваш, если форк)
- [ ] `bash build.sh` завершён успешно; pin-хэши в `install.sh` не содержат placeholders
- [ ] пломба актуальна: `sha256sum -c xkit.sh.sha256` отвечает `OK` по всем пяти строкам
- [ ] все семь ссылок из Шага 4 открываются (200)
- [ ] на чистой VPS прошла установка одной строкой (Шаг 5)
- [ ] у аккаунта GitHub включена 2FA — репо теперь канал поставки для ваших серверов
