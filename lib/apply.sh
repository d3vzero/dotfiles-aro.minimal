# lib/apply.sh -- fungsi bersama, di-source oleh bootstrap/install-chroot.sh
# dan update.sh. Semua jalan sebagai ROOT (tidak ada AUR, jadi tidak perlu
# makepkg sebagai user biasa). Home PUBLIC_USER ditulis root lalu di-chown.
#
# Catatan set -e: pakai "if ...; then" -- JANGAN "[ x ] && cmd" sebagai
# baris terakhir fungsi (kalau x salah, fungsi return 1 -> script berhenti).

ARO_GIT="https://github.com/simeulinuxkaliaiwr/aro"
ONLYOFFICE_URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/latest/download/DesktopEditors-x86_64.AppImage"
STATE_DIR="/usr/local/share/dotfiles-aro.minimal"

step() { echo; echo "==> $*"; }
warn() { echo "!! $*" >&2; }
die()  { echo "!! $*" >&2; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then die "Harus root (pakai sudo)."; fi
}

load_conf() {
    [ -f "$1" ] || die "Config $1 tidak ada."
    # shellcheck disable=SC1090
    . "$1"
    PUBLIC_HOME="/home/$PUBLIC_USER"
    SUNG_REV="${SUNG_REV:-4918f76}"
    export REPO_DIR PUBLIC_USER PUBLIC_HOME ADMIN_USER IS_VM SUNG_REV
}

has_profile() { [[ " $PROFILES " == *" $1 "* ]]; }

detect_vm() {
    if [ "$IS_VM" = "auto" ]; then
        local v
        v="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null || true)"
        if grep -qiE 'qemu|kvm|virtualbox|vmware|bochs' <<<"$v"; then IS_VM=yes; else IS_VM=no; fi
    fi
    echo "    IS_VM=$IS_VM  PROFILES=\"$PROFILES\""
}

# Baca daftar paket: satu paket per baris, '#' = komentar, baris kosong diabaikan
pkg_list() { awk '{ sub(/#.*/, ""); gsub(/[[:space:]]+/, "") } NF' "$@"; }

enable_repos() {
    pacman -S --needed --noconfirm artix-archlinux-support
    # [extra] wajib: freecad & ttf-caladea hanya ada di sana
    if ! grep -q '^\[extra\]' /etc/pacman.conf; then
        printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /etc/pacman.conf
    fi
    # Profil daily (Steam) butuh [multilib] + [core] Arch: lib32-expat pin ke
    # versi expat [core] Arch PERSIS, expat Artix bisa beda revisi.
    if has_profile daily; then
        if ! grep -q '^\[core\]' /etc/pacman.conf; then
            printf '\n[core]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /etc/pacman.conf
        fi
        if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /etc/pacman.conf
        fi
    fi
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Syu --noconfirm
    if has_profile daily; then
        pacman -S --needed --noconfirm core/expat
    fi
}

install_packages() {
    local files=("$REPO_DIR/core/packages.txt") p
    for p in $PROFILES; do
        if [ -f "$REPO_DIR/profiles/$p/packages.txt" ]; then
            files+=("$REPO_DIR/profiles/$p/packages.txt")
        fi
    done
    local pkgs
    mapfile -t pkgs < <(pkg_list "${files[@]}")
    if [ "$IS_VM" != "yes" ]; then pkgs+=(amd-ucode); fi
    if [ "$ENABLE_SSH" = "yes" ]; then pkgs+=(openssh openssh-dinit); fi
    pacman -S --needed --noconfirm "${pkgs[@]}"
}

build_aro() {
    if [ -x /usr/bin/aro ] && [ "${UPDATE_ARO:-0}" != "1" ]; then
        echo "    aro sudah ada -- skip (UPDATE_ARO=1 untuk rebuild)"
        return 0
    fi
    rm -rf /opt/aro-src
    git clone "$ARO_GIT" /opt/aro-src
    if [ -n "$ARO_REF" ]; then
        git -C /opt/aro-src checkout --quiet "$ARO_REF"
    fi
    # -Deffects=false: tanpa SceneFX (= tanpa AUR); -Dwallpaper=disabled: warna polos
    meson setup /opt/aro-src/build /opt/aro-src --prefix=/usr --buildtype=release \
        -Deffects=false -Dwallpaper=disabled
    ninja -C /opt/aro-src/build
    ninja -C /opt/aro-src/build install
    rm -rf /usr/share/backgrounds/aro
}

install_superfile() {
    mkdir -p "$STATE_DIR"
    local have=""
    if [ -f "$STATE_DIR/spf.version" ]; then have="$(cat "$STATE_DIR/spf.version")"; fi
    if [ -x /usr/local/bin/spf ] && [ "$have" = "$SPF_VERSION" ]; then
        echo "    superfile $SPF_VERSION sudah ada -- skip"
        return 0
    fi
    local tmp name
    tmp="$(mktemp -d)"
    name="superfile-linux-v${SPF_VERSION}-amd64"
    curl -fL -o "$tmp/spf.tar.gz" \
        "https://github.com/yorukot/superfile/releases/download/v${SPF_VERSION}/${name}.tar.gz"
    tar -xzf "$tmp/spf.tar.gz" -C "$tmp"
    install -m755 "$tmp/dist/$name/spf" /usr/local/bin/spf
    echo "$SPF_VERSION" > "$STATE_DIR/spf.version"
    rm -rf "$tmp"
}

install_system_files() {
    # Script utilitas ke /usr/local/bin: milik root, tidak bisa diubah PUBLIC_USER
    install -m755 "$REPO_DIR"/core/bin/* /usr/local/bin/
    # Helper root menu update (Super+U). Sudoers WAJIB divalidasi dulu:
    # file sudoers rusak bisa mengunci sudo sepenuhnya.
    install -o root -g root -m755 "$REPO_DIR"/core/sbin/* /usr/local/sbin/
    local sd=/etc/sudoers.d/office-update tmp
    tmp="$(mktemp)"
    echo "$ADMIN_USER ALL=(root) NOPASSWD: /usr/local/sbin/office-update-root" > "$tmp"
    if visudo -cqf "$tmp"; then
        install -o root -g root -m440 "$tmp" "$sd"
    else
        warn "sudoers office-update tidak valid -- TIDAK dipasang"
    fi
    rm -f "$tmp"

    mkdir -p /etc/dinit.d/config
    if [ "$AUTOLOGIN" = "yes" ]; then
        cat > /etc/dinit.d/config/agetty-tty1.conf <<EOF
GETTY_BAUD=38400
GETTY_TERM=linux
GETTY_ARGS="--autologin $PUBLIC_USER --noclear"
EOF
    else
        rm -f /etc/dinit.d/config/agetty-tty1.conf
    fi
}

enable_services() {
    local svc
    for svc in NetworkManager elogind; do
        ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    done
    if [ "$ENABLE_SSH" = "yes" ]; then
        ln -sf /etc/dinit.d/sshd /etc/dinit.d/boot.d/
    else
        rm -f /etc/dinit.d/boot.d/sshd
    fi
}

run_profile_hooks() {
    local p
    for p in $PROFILES; do
        if [ ! -d "$REPO_DIR/profiles/$p" ]; then
            warn "Profil '$p' tidak ada, skip."
            continue
        fi
        if [ -f "$REPO_DIR/profiles/$p/setup.sh" ]; then
            echo "    -> setup profil: $p"
            PDIR="$REPO_DIR/profiles/$p" bash "$REPO_DIR/profiles/$p/setup.sh"
        fi
    done
}

# Home PUBLIC_USER: SEMUA file di sini DI-COPY (bukan symlink) dan DITIMPA
# tiap update.sh -- repo = sumber kebenaran, perubahan lokal user hilang.
setup_public_home() {
    local H="$PUBLIC_HOME" T="$REPO_DIR/core/home"
    install -d "$H/.config/aro" "$H/.config/fuzzel" "$H/.config/kitty" \
               "$H/.local/share/applications"

    # .bash_profile
    {
        echo '[ -f ~/.bashrc ] && . ~/.bashrc'
        # ~/.local/bin wajib di PATH SEBELUM aro start: app per-user (Sung) dibuka
        # fuzzel lewat Exec= tanpa path lengkap. Titik dua jangan sampai hilang.
        echo 'export PATH="$HOME/.local/bin:$PATH"'
        echo 'if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then'
        if [ "$IS_VM" = "yes" ]; then
            echo '  export WLR_NO_HARDWARE_CURSORS=1   # VM (virtio-gpu): kursor meleset tanpa ini'
            echo '  ulimit -c unlimited                # VM uji: simpan core dump'
        fi
        echo '  exec dbus-run-session aro'
        echo 'fi'
    } > "$H/.bash_profile"

    # Config aro = config.example (berisi SEMUA bind default) + sed + tambahan.
    # JANGAN tulis dari nol: satu baris "bind" saja menghapus semua bind default.
    local AC="$H/.config/aro/config"
    cp /usr/share/doc/aro/config.example "$AC"
    sed -i -e 's/^bar = true/bar = false/' \
           -e 's/^# wallpaper = auto$/wallpaper = none/' \
           -e 's/spawn, foot$/spawn, kitty/' \
           -e '/^bind = mod+w, wallpapers/d' "$AC"
    { echo; cat "$T/config/aro/overrides.conf"; } >> "$AC"
    # Tambahan aro per profil (profiles/<p>/aro.conf), hanya profil yang aktif
    local pr
    for pr in $PROFILES; do
        if [ -f "$REPO_DIR/profiles/$pr/aro.conf" ]; then
            { echo; cat "$REPO_DIR/profiles/$pr/aro.conf"; } >> "$AC"
        fi
    done
    # Keybind dobel = salah satu tidak jalan; tampilkan supaya ketahuan
    local dup
    dup="$(awk '/^[[:space:]]*bind[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); k = $0;
                sub(/[[:space:]]*,.*/, "", k); c[tolower(k)]++ }
                END { for (k in c) if (c[k] > 1) print k }' "$AC")"
    if [ -n "$dup" ]; then warn "aro: keybind dobel di config: $(echo $dup)"; fi
    if ! grep -q '^bar = false' "$AC";       then warn "aro: 'bar = false' tidak ter-set (config.example berubah?)"; fi
    if ! grep -q '^wallpaper = none' "$AC";  then warn "aro: 'wallpaper = none' tidak ter-set (config.example berubah?)"; fi
    if ! grep -q 'spawn, kitty$' "$AC";      then warn "aro: terminal default belum diganti ke kitty (config.example berubah?)"; fi

    cp "$T/config/fuzzel/fuzzel.ini" "$H/.config/fuzzel/fuzzel.ini"
    cp "$T/config/kitty/kitty.conf"  "$H/.config/kitty/kitty.conf"
    # mimeapps.list ditulis langsung (xdg-mime sebagai user gagal kalau ~/.config milik root)
    cp "$T/config/mimeapps.list"     "$H/.config/mimeapps.list"

    # Sembunyikan entry dari fuzzel
    local n src dst
    while read -r n; do
        # $n sengaja TANPA kutip: boleh pola glob (mis. qv4l*)
        for src in /usr/share/applications/$n.desktop; do
            if [ ! -f "$src" ]; then continue; fi
            dst="$H/.local/share/applications/$(basename "$src")"
            cp "$src" "$dst"
            sed -i '/^NoDisplay=/d; /^\[Desktop Entry\]/a NoDisplay=true' "$dst"
        done
    done < <(pkg_list "$REPO_DIR/core/hidden-apps.txt")

    chown -R "$PUBLIC_USER:$PUBLIC_USER" "$H"
}
