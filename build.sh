#!/bin/bash
# Воспроизводимая сборка release-файлов XKIT 5.3.1. Нужен Go 1.23+.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# (v5.3.1, §8.3 CHANGES.md): ядро собирается из src/-модулей — правки вносятся
# в src/[0-9][0-9]_*.sh, а не в xkit.sh. Порядок склейки задаётся именами.
if [ -d "$ROOT/src" ]; then
  cat "$ROOT"/src/[0-9][0-9]_*.sh > "$ROOT/xkit.sh"
  echo "xkit.sh собран из src/ ($(wc -l < "$ROOT/xkit.sh") строк)"
fi
cd "$ROOT/tui"
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$ROOT/xkit-tui-linux-amd64" .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$ROOT/xkit-tui-linux-arm64" .
# (v5.3.1): нормализуем права артефактов — сборка не должна зависеть от umask
# сборщика. V-02/install_trust не доверяет group/other-writable файлам:
# бинарник 775 (umask 002) отваливался от локальной установки и качался с GitHub.
chmod 755 "$ROOT/xkit-tui-linux-amd64" "$ROOT/xkit-tui-linux-arm64"
chmod 644 "$ROOT/xkit.sh" "$ROOT/xkit.sh.sha256"
cd "$ROOT"
sha256sum xkit.sh xkit_menu.sh xkit_protocols.sh xkit-tui-linux-amd64 xkit-tui-linux-arm64 > xkit.sh.sha256
ROOT="$ROOT" python3 - <<'PY'
import os, re, hashlib
from pathlib import Path
# (мелочь №1, аудит v5.2.1): путь к паку берём из окружения, а не из cwd —
# сборка не зависит от того, где и как её запустили
root = Path(os.environ['ROOT'])
text = (root/'install.sh').read_text()
for name, var in [('xkit.sh','XKIT_PIN_SHA256'),('xkit_menu.sh','XKIT_PIN_MENU_SHA256'),('xkit_protocols.sh','XKIT_PIN_PROTOCOLS_SHA256'),('xkit-tui-linux-amd64','XKIT_PIN_TUI_AMD64_SHA256'),('xkit-tui-linux-arm64','XKIT_PIN_TUI_ARM64_SHA256')]:
    digest = hashlib.sha256((root/name).read_bytes()).hexdigest()
    new_line = f'{var}="{digest}"'
    if re.search(r'^' + re.escape(var) + r'=', text, flags=re.M):
        text = re.sub(r'^' + re.escape(var) + r'=.*$', new_line, text, flags=re.M)
    else:
        # (баг №2, аудит v5.2.1): re.sub не добавляет ОТСУТСТВУЮЩИЕ строки — pin
        # удалённой/новой компоненты никогда бы не появился. Вставляем после
        # последнего XKIT_PIN_* (или после XKIT_BASE, если pin-блок пуст)
        pins = list(re.finditer(r'^XKIT_PIN_[A-Z0-9_]+=.*$', text, flags=re.M))
        if pins:
            ins = pins[-1].end()
        else:
            m = re.search(r'^XKIT_BASE=.*$', text, flags=re.M)
            ins = m.end() if m else 0
        text = text[:ins] + '\n' + new_line + text[ins:]
(root/'install.sh').write_text(text)
PY
bash -n xkit.sh xkit_menu.sh xkit_protocols.sh install.sh
sha256sum -c xkit.sh.sha256
printf 'Сборка XKIT 5.3.1 завершена.\n'
