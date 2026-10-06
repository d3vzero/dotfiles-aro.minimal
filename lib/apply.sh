# lib/apply.sh -- fungsi bersama, di-source oleh bootstrap/install-chroot.sh
# dan update.sh. Semua jalan sebagai ROOT (tidak ada AUR, jadi tidak perlu
# makepkg sebagai user biasa). Home PUBLIC_USER ditulis root lalu di-chown.
# Hardware dipilih lewat config (CPU / GPU / GPU_GEN), divalidasi terhadap
# deteksi sysfs -- tidak pernah diganti diam-diam.
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

    # --- kompatibilitas config lama ---
    if has_profile work; then
        PROFILES="$(echo " $PROFILES " | sed 's/ work / office cad /; s/^ *//; s/ *$//')"
        warn "Profil 'work' sudah dipecah jadi 'office cad' -- ganti PROFILES di $1"
    fi
    CPU="${CPU:-amd}"
    if [ -z "${GPU:-}" ]; then
        case "${IS_VM:-auto}" in
            yes) GPU=vm ;;
            no)  GPU=amd ;;
            *)   if [[ " $(detect_gpus) " == *" vm "* ]]; then GPU=vm; else GPU=amd; fi ;;
        esac
        warn "GPU belum diisi di $1 -- sementara dipakai GPU=$GPU. Tambahkan GPU= (lihat machine.conf)."
    fi
    GPU_GEN="${GPU_GEN:-new}"
    AI_BACKEND="${AI_BACKEND:-auto}"

    case "$CPU" in amd|intel) ;; *) die "CPU='$CPU' tidak valid (amd | intel)" ;; esac
    case "$GPU" in amd|nvidia|intel|vm) ;; *) die "GPU='$GPU' tidak valid (amd | nvidia | intel | vm)" ;; esac
    case "$GPU_GEN" in new|old) ;; *) die "GPU_GEN='$GPU_GEN' tidak valid (new | old)" ;; esac
    # GPU lama hanya didukung untuk Intel. AMD GCN1/2 & NVIDIA Maxwell/Pascal
    # sengaja tidak didukung (butuh param kernel khusus / driver AUR).
    if [ "$GPU_GEN" = old ] && [ "$GPU" != intel ]; then
        die "GPU_GEN=old hanya untuk GPU=intel. GPU $GPU lama (AMD GCN1/2, NVIDIA GTX 9xx/10xx) tidak didukung."
    fi

    AI_BACKEND_RESOLVED="$(resolve_ai_backend)"
    export REPO_DIR PUBLIC_USER PUBLIC_HOME ADMIN_USER SUNG_REV CPU GPU GPU_GEN \
           AI_BACKEND_RESOLVED D2_REV TORCH_CUDA_ARCH
}

has_profile() { [[ " $PROFILES " == *" $1 "* ]]; }

# ---------- hardware ----------
detect_cpu() {   # amd | intel | unknown
    case "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" in
        AuthenticAMD) echo amd ;; GenuineIntel) echo intel ;; *) echo unknown ;;
    esac
}

detect_gpus() {  # vendor semua GPU (kelas PCI 0x03xxxx), dari sysfs -- tanpa lspci
    local d v out=""
    for d in /sys/bus/pci/devices/*; do
        case "$(cat "$d/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
        v="$(cat "$d/vendor")"
        case "$v" in
            0x1002) out+=" amd" ;; 0x10de) out+=" nvidia" ;; 0x8086) out+=" intel" ;;
            0x1af4|0x1234|0x1b36|0x15ad|0x80ee) out+=" vm" ;;
            *) out+=" lain($v)" ;;
        esac
    done
    echo "$out" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Peringatan + konfirmasi kalau config tidak cocok dengan hardware.
validate_hw() {
    local dc dg problems=()
    dc="$(detect_cpu)"; dg="$(detect_gpus)"
    echo "    config   : CPU=$CPU  GPU=$GPU  GPU_GEN=$GPU_GEN  AI=$AI_BACKEND_RESOLVED"
    echo "    terdeteksi: CPU=$dc  GPU=[${dg:-tidak ada}]"
    echo "    PROFILES=\"$PROFILES\""
    if [ "$GPU" != "vm" ] && [ "$dc" != "$CPU" ]; then
        problems+=("CPU=$CPU, tapi CPU terdeteksi: $dc")
    fi
    if [[ " $dg " != *" $GPU "* ]]; then
        problems+=("GPU=$GPU, tapi GPU terdeteksi: ${dg:-tidak ada}")
    fi
    if [ "${#problems[@]}" -eq 0 ]; then return 0; fi
    local p; for p in "${problems[@]}"; do warn "$p"; done
    if [ ! -t 0 ]; then die "Config tidak cocok dengan hardware (non-interaktif, dibatalkan)."; fi
    local a; read -rp "Tetap lanjut dengan setting config? [y/N] " a
    case "$a" in y|Y) ;; *) die "Dibatalkan. Perbaiki CPU/GPU di config." ;; esac
}

resolve_ai_backend() {   # cuda | cpu
    case "$AI_BACKEND" in
        auto)
            if [ "$GPU" = nvidia ]; then echo cuda; else echo cpu; fi ;;
        cuda)
            if [ "$GPU" != nvidia ]; then
                warn "AI_BACKEND=cuda butuh GPU=nvidia -- dipakai cpu"; echo cpu
            else echo cuda; fi ;;
        rocm)
            warn "AI_BACKEND=rocm belum didukung skrip ini -- dipakai cpu"; echo cpu ;;
        cpu) echo cpu ;;
        *) die "AI_BACKEND='$AI_BACKEND' tidak valid (auto | cuda | rocm | cpu)" ;;
    esac
}

gpu_packages() {
    case "$GPU" in
        vm)  echo mesa ;;
        amd) echo mesa vulkan-radeon ;;
        intel)
            if [ "$GPU_GEN" = new ]; then echo mesa vulkan-intel intel-media-driver
            else echo mesa vulkan-intel libva-intel-driver; fi ;;
        nvidia)
            # Turing+ (GTX 16xx / RTX 20xx ke atas). Artix: WAJIB -dkms (kernel
            # Artix beda build dari Arch). RTX 50xx hanya didukung open module.
            echo nvidia-open-dkms nvidia-utils libva-nvidia-driver egl-wayland ;;
    esac
    # 32-bit untuk Steam (profil daily)
    if has_profile daily; then
        case "$GPU" in
            vm) echo lib32-mesa ;;
            amd) echo lib32-mesa lib32-vulkan-radeon ;;
            intel) echo lib32-mesa lib32-vulkan-intel ;;
            nvidia) echo lib32-nvidia-utils ;;
        esac
    fi
}

gpu_kernel_params() {
    case "$GPU" in
        nvidia) echo "nvidia_drm.modeset=1 nvidia_drm.fbdev=1" ;;
        *)      echo "" ;;
    esac
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
    if [ "$GPU" != "vm" ]; then pkgs+=("${CPU}-ucode"); fi
    # shellcheck disable=SC2207
    pkgs+=($(gpu_packages))
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
        # ~/.cache di tmpfs: cache yang mahal dibuat ulang disimpan di disk
        echo 'export MESA_SHADER_CACHE_DIR="$HOME/.local/state/shader-cache/mesa"'
        echo 'export __GL_SHADER_DISK_CACHE_PATH="$HOME/.local/state/shader-cache/nvidia"'
        echo 'export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1'
        echo 'export MPLCONFIGDIR="$HOME/.local/state/matplotlib"'
        echo 'if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then'
        if [ "$GPU" = "vm" ]; then
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

# EFISTUB: entry dibuat ulang hanya kalau cmdline berubah (CPU/GPU/root)
# atau entry hilang. Dipakai bootstrap DAN update.sh.
setup_efistub() {
    local esp_src esp_disk esp_part root_src root_uuid ucode params cmdline
    [ "$(findmnt -no FSTYPE /boot 2>/dev/null)" = "vfat" ] || die "/boot bukan partisi EFI (vfat)"
    esp_src="$(findmnt -no SOURCE /boot)"
    esp_disk="/dev/$(lsblk -no PKNAME "$esp_src")"
    esp_part="$(cat "/sys/class/block/$(basename "$esp_src")/partition")"
    root_src="$(findmnt -no SOURCE /)"; root_src="${root_src%%\[*}"
    root_uuid="$(blkid -s UUID -o value "$root_src")"
    [ -n "$root_uuid" ] || die "UUID root tidak terbaca dari $root_src"
    [ -f /boot/vmlinuz-linux ] || die "/boot/vmlinuz-linux tidak ada"

    ucode=""
    if [ "$GPU" != "vm" ]; then
        [ -f "/boot/${CPU}-ucode.img" ] || die "/boot/${CPU}-ucode.img tidak ada (paket ${CPU}-ucode?)"
        ucode="initrd=\\${CPU}-ucode.img "
    fi
    params="$(gpu_kernel_params)"
    cmdline="root=UUID=$root_uuid rw ${ucode}initrd=\\initramfs-linux.img ${params:+$params }quiet"
    echo "    disk=$esp_disk part=$esp_part"
    echo "    cmdline: $cmdline"

    local exists=no num
    if efibootmgr | grep -qE "^Boot[0-9A-Fa-f]{4}\*? ${EFI_LABEL}([[:space:]]|$)"; then exists=yes; fi
    if [ "$exists" = yes ] && [ "$(cat "$STATE_DIR/efistub.cmdline" 2>/dev/null)" = "$cmdline" ]; then
        echo "    entry '$EFI_LABEL' tidak berubah -- skip"
        return 0
    fi
    # Entry lama berlabel sama dihapus dulu: GUID partisi / cmdline bisa berubah.
    for num in $(efibootmgr | sed -nE "s/^Boot([0-9A-Fa-f]{4})\*? ${EFI_LABEL}([[:space:]].*)?$/\1/p"); do
        echo "    hapus entry lama Boot$num ($EFI_LABEL)"
        efibootmgr -q -b "$num" -B
    done
    efibootmgr --create --disk "$esp_disk" --part "$esp_part" --label "$EFI_LABEL" \
        --loader /vmlinuz-linux --unicode "$cmdline"
    mkdir -p "$STATE_DIR"
    echo "$cmdline" > "$STATE_DIR/efistub.cmdline"
}

# tmpfs /tmp + ~/.cache user umum + noatime (idempotent; berlaku setelah reboot).
# Catatan: ukuran baru di config TIDAK mengubah baris fstab yang sudah ada.
apply_tmpfs() {
    bash "$REPO_DIR/core/setup-tmpfs.sh" "$PUBLIC_USER" \
        "${TMPFS_TMP_SIZE:-50%}" "${TMPFS_CACHE_SIZE:-2G}" | sed -n '1,/^Tambahkan ke/p' | sed '$d'
}
