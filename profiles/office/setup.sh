#!/bin/bash
# profil office: OnlyOffice AppImage resmi (~600 MB, butuh fuse2)
set -euo pipefail
OO=/opt/onlyoffice/OnlyOffice.AppImage
URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/latest/download/DesktopEditors-x86_64.AppImage"

if [ ! -x "$OO" ] || [ "${UPDATE_ONLYOFFICE:-0}" = "1" ]; then
    mkdir -p /opt/onlyoffice
    # Ambil tag dulu, unduh dari tag itu, lalu catat di VERSION: versi yang
    # tercatat pasti cocok dengan file (dipakai menu update Super+U).
    TAG="$(curl -fsSL https://api.github.com/repos/ONLYOFFICE/DesktopEditors/releases/latest | jq -r .tag_name)"
    [ -n "$TAG" ] && [ "$TAG" != "null" ] || { echo "!! tag rilis OnlyOffice tidak terbaca"; exit 1; }
    URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/download/$TAG/DesktopEditors-x86_64.AppImage"
    curl -fL -o "$OO.part" "$URL"
    mv "$OO.part" "$OO"
    chmod 755 "$OO"
    echo "$TAG" > /opt/onlyoffice/VERSION
    echo "    OnlyOffice $TAG terpasang"
else
    echo "    OnlyOffice sudah ada -- skip (UPDATE_ONLYOFFICE=1 untuk download ulang)"
fi
install -Dm644 "$PDIR/applications/onlyoffice.desktop" /usr/local/share/applications/onlyoffice.desktop
