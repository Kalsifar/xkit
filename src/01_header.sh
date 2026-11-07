#!/bin/bash
#==============================================================================
#  XKIT v5.3.1 — TUI и CLI для nginx + 3X-UI (Ubuntu 24.04+)
#
#  Установка:  curl -fsSL https://raw.githubusercontent.com/kalsifar/xkit/main/install.sh | sudo bash
#  Запуск:     xkit (TUI) | xkit --classic | xkit help
#  Документация: README.md
#  История:      CHANGES.md
#
#  ВНИМАНИЕ (v5.3.1): этот файл СОБИРАЕТСЯ из src/ командой `bash build.sh` —
#  правки вносить в src/[0-9][0-9]_*.sh, а не сюда (§8.3 CHANGES.md).
#
#  Для тестов функций: source xkit.sh — main вызывается только при прямом запуске.
#==============================================================================

set -u -o pipefail
export LC_ALL=C

XKIT_VERSION="5.3.1"
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
