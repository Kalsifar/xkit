#!/bin/bash
# Воспроизводимая сборка release-файлов XKIT 5.2. Нужен Go 1.23+.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/tui"
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$ROOT/xkit-tui-linux-amd64" .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$ROOT/xkit-tui-linux-arm64" .
cd "$ROOT"
sha256sum xkit.sh xkit_menu.sh xkit_protocols.sh xkit-tui-linux-amd64 xkit-tui-linux-arm64 > xkit.sh.sha256
python3 - <<'PY'
from pathlib import Path
import re
root=Path(__file__).resolve().parent if '__file__' in globals() else Path.cwd()
text=(root/'install.sh').read_text()
for name,var in [('xkit.sh','XKIT_PIN_SHA256'),('xkit_menu.sh','XKIT_PIN_MENU_SHA256'),('xkit_protocols.sh','XKIT_PIN_PROTOCOLS_SHA256'),('xkit-tui-linux-amd64','XKIT_PIN_TUI_AMD64_SHA256'),('xkit-tui-linux-arm64','XKIT_PIN_TUI_ARM64_SHA256')]:
    import hashlib
    digest=hashlib.sha256((root/name).read_bytes()).hexdigest()
    text=re.sub(r'^'+re.escape(var)+r'=.*$',f'{var}="{digest}"',text,flags=re.M)
(root/'install.sh').write_text(text)
PY
bash -n xkit.sh xkit_menu.sh xkit_protocols.sh install.sh
sha256sum -c xkit.sh.sha256
printf 'Сборка XKIT 5.2.0 завершена.\n'
