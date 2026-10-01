#!/bin/bash
# profil work: OnlyOffice AppImage resmi (~600 MB, butuh fuse2 dari core)
set -euo pipefail
OO=/opt/onlyoffice/OnlyOffice.AppImage
URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/latest/download/DesktopEditors-x86_64.AppImage"

if [ ! -x "$OO" ] || [ "${UPDATE_ONLYOFFICE:-0}" = "1" ]; then
    mkdir -p /opt/onlyoffice
    curl -fL -o "$OO.part" "$URL"
    mv "$OO.part" "$OO"
    chmod 755 "$OO"
    echo "    OnlyOffice AppImage terpasang"
else
    echo "    OnlyOffice sudah ada -- skip (UPDATE_ONLYOFFICE=1 untuk download ulang)"
fi
install -Dm644 "$PDIR/applications/onlyoffice.desktop" /usr/local/share/applications/onlyoffice.desktop
