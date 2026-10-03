#!/bin/bash
# profil daily: Proton-GE (system-wide) + Sung (per-user, di home PUBLIC_USER)
set -euo pipefail
STATE_DIR=/usr/local/share/dotfiles-aro.minimal
mkdir -p "$STATE_DIR"

install_proton_ge() {
    local dest=/usr/share/steam/compatibilitytools.d url tmp
    mkdir -p "$dest"
    if ls -d "$dest"/GE-Proton* >/dev/null 2>&1 && [ "${UPDATE_PROTONGE:-0}" != "1" ]; then
        echo "    Proton-GE sudah ada -- skip (UPDATE_PROTONGE=1 untuk versi terbaru)"
        return 0
    fi
    # Filter eksplisit x86_64: sejak GE-Proton11 ada juga tarball aarch64
    url="$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
          | jq -r '.assets[].browser_download_url | select(endswith("x86_64.tar.gz"))' | head -n1)"
    if [ -z "$url" ]; then echo "!! URL Proton-GE tidak ditemukan"; return 1; fi
    tmp="$(mktemp -d)"
    curl -fL -o "$tmp/ge.tar.gz" "$url"
    tar -xzf "$tmp/ge.tar.gz" -C "$dest"
    rm -rf "$tmp"
    echo "    Proton-GE terpasang di $dest (restart Steam supaya terdeteksi)"
}

install_sung() {
    # sung-yt ke /usr/local/bin (root-owned); default prefix-nya $HOME/.local,
    # jadi tetap mengurus venv Sung milik user yang menjalankannya.
    install -m755 "$PDIR/bin/sung-yt" /usr/local/bin/sung-yt

    local have=""
    if [ -f "$STATE_DIR/sung.rev" ]; then have="$(cat "$STATE_DIR/sung.rev")"; fi
    if [ -x "$PUBLIC_HOME/.local/bin/sung" ] && [ "$have" = "$SUNG_REV" ] \
       && [ "${UPDATE_SUNG:-0}" != "1" ]; then
        echo "    Sung $SUNG_REV sudah ada -- skip (UPDATE_SUNG=1 untuk build ulang)"
        return 0
    fi

    # install.sh Sung DILARANG jalan sebagai root -> runuser sebagai PUBLIC_USER.
    # Bukan "su -": itu memicu .bash_profile (exec aro / error ttyname).
    echo "    Build Sung $SUNG_REV sebagai $PUBLIC_USER (beberapa menit)"
    runuser -u "$PUBLIC_USER" -- env -i HOME="$PUBLIC_HOME" USER="$PUBLIC_USER" \
        PATH=/usr/local/bin:/usr/bin:/bin LANG=en_US.UTF-8 SUNG_REV="$SUNG_REV" \
        bash -c '
            set -euo pipefail
            src="$(mktemp -d)/sung"
            git clone https://github.com/yappologistic/Sung.git "$src"
            git -C "$src" checkout --quiet "$SUNG_REV"
            (cd "$src" && ./scripts/install.sh)
            # commit lengkap untuk status Sung di menu update (Super+U)
            mkdir -p "$HOME/.local/state/office-update"
            git -C "$src" rev-parse HEAD > "$HOME/.local/state/office-update/sung.rev"
            rm -rf "$(dirname "$src")"
        '
    echo "$SUNG_REV" > "$STATE_DIR/sung.rev"

    # install.sh selalu memasang yt-dlp versi terkunci -> naikkan ke terbaru.
    # Gagal di sini (offline, YouTube berubah) tidak menggagalkan instalasi.
    runuser -u "$PUBLIC_USER" -- env -i HOME="$PUBLIC_HOME" USER="$PUBLIC_USER" \
        PATH=/usr/local/bin:/usr/bin:/bin LANG=en_US.UTF-8 \
        sung-yt update || echo "!! sung-yt update gagal -- jalankan nanti: Super+U -> YouTube-Sung"
}

install_proton_ge
install_sung
