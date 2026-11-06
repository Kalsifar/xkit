#!/bin/bash
#==============================================================================
#  XKIT installer — установка xkit.sh одной командой
#
#  GitHub (рекомендуемый вариант, файлы install.sh + xkit.sh в одном репо):
#    curl -fsSL https://raw.githubusercontent.com/НИК/xkit/main/install.sh | sudo bash
#
#  Свой сервер (оба файла в одной папке за nginx):
#    curl -fsSL https://ВАШ_ДОМЕН/xkit/install.sh | sudo bash
#
#  Скачанный заранее файл:
#    sudo bash install.sh          # полная установка
#    bash install.sh status        # любая субкоманда xkit (help, status...)
#
#  Можно переопределить источник:  XKIT_BASE=https://... bash install.sh
#  или передать URL первым аргументом: bash install.sh https://.../xkit.sh
#
#  Неинтерактивно (CI/cloud-init): флаги после -- в пайпе (иначе bash
#  съест -y как СВОЙ аргумент и до скрипта он не дойдёт):
#    curl -fsSL https://.../install.sh | sudo bash -s -- -y
#==============================================================================


XKIT_BASE="${XKIT_BASE:-https://raw.githubusercontent.com/kalsifar/xkit/main}"

set -u
# TTY-детект (ревью v4.7): при не-терминале (curl|bash | tee log) цвета гаснут —
# в логах не остаётся сырых \033[ кодов
if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_N='\033[0m'; IS_TTY=1
else
  C_G=''; C_Y=''; C_R=''; C_N=''; IS_TTY=0
fi
log(){ echo -e "${C_G}[i]${C_N} $*"; }
# warn — в stderr (симметрия с xkit.sh, ревью v4.7.0): диагностика не должна
# попадать в пайпы/захват stdout, даже если сегодня тут никто не захватывает
warn(){ echo -e "${C_Y}[!]${C_N} $*" >&2; }
err(){ echo -e "${C_R}[x] $*${C_N}" >&2; }

# --- разбор аргументов: -y/--yes и --force пробрасываются в xkit (XKIT_YES/
# XKIT_FORCE — неинтерактивный режим/CI), первый http(s)-аргумент = источник,
# остальное = субкоманда xkit
URL_ARG=""; XKIT_ARGS=()
for a in "$@"; do
  case "$a" in
    -y|--yes)  export XKIT_YES=1 ;;
    --force)   export XKIT_FORCE=1 ;;
    *) if [ -z "$URL_ARG" ] && printf '%s' "$a" | grep -q '^https\?://'; then
         URL_ARG="$a"
       else
         XKIT_ARGS+=("$a")
       fi ;;
  esac
done
[ ${#XKIT_ARGS[@]} -eq 0 ] && XKIT_ARGS=(install)

# база репозитория — запомним в xkit.env для `xkit update` (без /xkit.sh на конце)
REPO="${URL_ARG:-$XKIT_BASE}"
REPO="${REPO%/xkit.sh}"
export XKIT_REPO_URL="$REPO"

# --- источник xkit.sh: сначала ищем рядом с самим install.sh
# basename/readlink с «--» — GNU/BusyBox по-разному едят имена с ведущим «-»
SRC=""
SELF="$0"
if [ -f "$SELF" ] && [ "$(basename -- "$SELF")" != "bash" ] && [ "$(basename -- "$SELF")" != "-bash" ]; then
  D="$(cd "$(dirname -- "$(readlink -f -- "$SELF" 2>/dev/null)" 2>/dev/null)" 2>/dev/null && pwd)" || D=""
  [ -n "$D" ] && [ -f "$D/xkit.sh" ] && SRC="$D/xkit.sh"
fi

# ранняя подсказка (v4.7): xkit уже стоит — установка спросит, что делать
# (обновить/переустановить/починить поверх); скачиваем и отдаём сцену xkit'у
if [ "${XKIT_ARGS[0]}" = "install" ] && [ -f /etc/xkit/xkit.env ] \
   && [ "${XKIT_FORCE:-0}" != "1" ]; then
  warn "Обнаружен установленный xkit (/etc/xkit/xkit.env)."
  warn "Установка предложит: обновить / переустановить чисто / починить поверх."
  warn "Обновить без переустановки:  xkit update   |   Снести:  xkit uninstall"
fi

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; printf "Прервано.\n" >&2; exit 130' INT TERM

if [ -n "$SRC" ]; then
  log "Найден локальный xkit.sh рядом с install.sh: $SRC"
  cp -f "$SRC" "$WORK/xkit.sh" || exit 1
else
  BASE="${URL_ARG:-$XKIT_BASE}"
  if [[ "$BASE" == *YOUR_USERNAME* ]]; then
    err "install.sh не настроен: замените YOUR_USERNAME на свой ник в install.sh,"
    err "либо задайте XKIT_BASE=https://... или передайте URL первым аргументом:"
    err "  bash install.sh https://raw.githubusercontent.com/НИК/xkit/main/xkit.sh"
    exit 1
  fi
  case "$BASE" in
    */xkit.sh) RAW="$BASE" ;;
    *)         RAW="$BASE/xkit.sh" ;;
  esac
  log "Скачиваю: $RAW"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW" -o "$WORK/xkit.sh" || { err "Не удалось скачать $RAW"; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$WORK/xkit.sh" "$RAW" || { err "Не удалось скачать $RAW"; exit 1; }
  else
    err "Нужен curl или wget"; exit 1
  fi

  # контрольная сумма — если рядом опубликован xkit.sh.sha256
  SUMURL="${RAW%/*}/xkit.sh.sha256"
  if curl -fsSL "$SUMURL" -o "$WORK/xkit.sh.sha256" 2>/dev/null \
     || wget -qO "$WORK/xkit.sh.sha256" "$SUMURL" 2>/dev/null; then
    WANT="$(awk 'NR==1{print $1}' "$WORK/xkit.sh.sha256")"
    GOT="$(sha256sum "$WORK/xkit.sh" | awk '{print $1}')"
    if [ -n "$WANT" ] && [ "$WANT" = "$GOT" ]; then
      log "SHA-256 проверен: $GOT"
    else
      err "SHA-256 НЕ совпал — файл битый или изменён. Установка отменена."
      exit 1
    fi
  else
    warn "sha256 не проверен (xkit.sh.sha256 рядом с файлом не найден)"
  fi
fi

# --- санитарная проверка перед запуском от root
bash -n "$WORK/xkit.sh" || { err "Синтаксическая ошибка в xkit.sh — установка отменена"; exit 1; }
chmod 700 "$WORK/xkit.sh"

# --- команды, которым root не нужен (xkit сам проверит root там, где надо)
case "${XKIT_ARGS[0]}" in
  help|status|health) NEED_ROOT=0 ;;
  *)                  NEED_ROOT=1 ;;
esac

# --- запуск: даже при «curl | bash» отдаём установщику настоящий терминал.
# ЕДИНАЯ уборка $WORK — в EXIT-trap (строка выше), поэтому здесь НЕ exec и НЕ
# дублируем rm: с exec ловушка не сработала бы, а второй rm был бы мёртвым кодом
run_xkit() {
  if [ "$(id -u)" -eq 0 ] || [ "$NEED_ROOT" -eq 0 ]; then
    RUN=(bash "$WORK/xkit.sh")
  elif command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [ -r /dev/tty ]; }; then
    log "Нет root — запускаю через sudo"
    # sudo НЕ пробрасывает env (ревью v4.7.0): без этого -y/--force от не-root
    # доезжали до xkit.sh пустыми и установка шла интерактивно. Явный проброс
    # через `sudo env VAR=…` — не зависит от env_keep в sudoers
    RUN=(sudo env XKIT_YES="${XKIT_YES:-0}" XKIT_FORCE="${XKIT_FORCE:-0}" \
           XKIT_NO_COLOR="${XKIT_NO_COLOR:-}" XKIT_NO_ANIM="${XKIT_NO_ANIM:-}" \
           XKIT_REPO_URL="$XKIT_REPO_URL" bash "$WORK/xkit.sh")
  else
    RUN=(bash "$WORK/xkit.sh")
    warn "Нет ни root, ни sudo — xkit сам сообщит, что нужен root"
  fi
  if [ -t 0 ]; then
    "${RUN[@]}" "${XKIT_ARGS[@]}"
  elif ( exec true </dev/tty ) 2>/dev/null; then
    "${RUN[@]}" "${XKIT_ARGS[@]}" </dev/tty
  else
    "${RUN[@]}" "${XKIT_ARGS[@]}"   # stdin не терминал — пусть xkit сам скажет, чего не хватает
  fi
}
run_xkit; rc=$?
exit $rc
