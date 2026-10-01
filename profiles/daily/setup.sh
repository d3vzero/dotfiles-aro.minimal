#!/bin/bash
# profil daily: Proton-GE system-wide (berlaku untuk semua user Steam)
set -euo pipefail
DEST=/usr/share/steam/compatibilitytools.d
mkdir -p "$DEST"

if ls -d "$DEST"/GE-Proton* >/dev/null 2>&1 && [ "${UPDATE_PROTONGE:-0}" != "1" ]; then
    echo "    Proton-GE sudah ada -- skip (UPDATE_PROTONGE=1 untuk versi terbaru)"
    exit 0
fi
# Filter eksplisit x86_64: sejak GE-Proton11 ada juga tarball aarch64
URL="$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
      | jq -r '.assets[].browser_download_url | select(endswith("x86_64.tar.gz"))' | head -n1)"
[ -n "$URL" ] || { echo "!! URL Proton-GE tidak ditemukan"; exit 1; }
tmp="$(mktemp -d)"
curl -fL -o "$tmp/ge.tar.gz" "$URL"
tar -xzf "$tmp/ge.tar.gz" -C "$DEST"
rm -rf "$tmp"
echo "    Proton-GE terpasang di $DEST (restart Steam supaya terdeteksi)"
