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
    # config per bagian (profil ai: ai-trainer.conf, ai-llm.conf) di <config>.d/,
    # dimuat setelah config mesin: nilainya menang atas baris lama di config mesin
    CONF_D="${1%.conf}.d"
    local f
    for f in "$CONF_D"/*.conf; do
        # shellcheck disable=SC1090
        [ -f "$f" ] && . "$f"
    done
    AI_PARTS="${AI_PARTS:-trainer}"           # profil ai: trainer | llm | "trainer llm"
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
    ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-no}"   # config lama belum punya baris ini
    PUBLIC_NETWORK_CONTROL="${PUBLIC_NETWORK_CONTROL:-no}"
    LOG_PERSIST="${LOG_PERSIST:-yes}"
    BLESH="${BLESH:-yes}"
    MIRROR_RANK="${MIRROR_RANK:-auto}"
    LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-30}"
    WHYD="${WHYD:-yes}"
    WHYD_REF="${WHYD_REF:-783e5c0}"
    LIVEPAPER="${LIVEPAPER:-no}"
    TAILSCALE="${TAILSCALE:-no}"
    MUSIC_MPD="${MUSIC_MPD:-no}"
    SHARED_DIR="${SHARED_DIR:-}"
    SHARED_SUBDIRS="${SHARED_SUBDIRS:-Documents Downloads Musics Movies Pictures Project}"
    LIVEPAPER_REF="${LIVEPAPER_REF:-3d583f5}"

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
           AI_BACKEND_RESOLVED D2_REV TORCH_CUDA_ARCH TORCH_INDEX CONF_D AI_PARTS AI_BACKEND
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

# Driver NVIDIA: Arch (extra/multilib) biasanya merilis versi baru beberapa hari
# sebelum Artix [world]. Selama jeda itu lib32-nvidia-utils (multilib, profil
# daily) meminta nvidia-utils baru dari extra, sementara nvidia-open-dkms tetap
# dari world -> versi driver bentrok dan pacman menolak upgrade. Selama versinya
# berbeda, seluruh paket driver ditahan di versi terpasang (hanya untuk run itu).
NVIDIA_STACK="nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-open-dkms"
nvidia_hold() {     # cetak paket yang ditahan (kosong = tidak ada); butuh db tersinkron
    [ "$GPU" = nvidia ] || return 0
    pacman -Q lib32-nvidia-utils >/dev/null 2>&1 || has_profile daily || return 0
    local multi dkms
    multi="$(pacman -Si lib32-nvidia-utils 2>/dev/null | awk '/^Version/ { print $3; exit }')"
    dkms="$(pacman -Si nvidia-open-dkms 2>/dev/null | awk '/^Version/ { print $3; exit }')"
    if [ -n "$multi" ] && [ -n "$dkms" ] && [ "$multi" != "$dkms" ]; then
        echo "$NVIDIA_STACK"
    fi
}
NVIDIA_HELD=""

# Mirror tercepat & up to date di urutan teratas (core/sbin/aro-mirrors).
# auto: hanya kalau mirror pertama lambat atau gagal -- biasanya 1-2 detik.
rank_mirrors() {
    case "$MIRROR_RANK" in
        no)  return 0 ;;
        yes) "$REPO_DIR/core/sbin/aro-mirrors" ;;
        *)   "$REPO_DIR/core/sbin/aro-mirrors" --auto ;;
    esac || warn "aro-mirrors gagal -- lanjut dengan mirrorlist yang ada"
}

# Paket lib32-* dari [multilib] mengunci library dasarnya ke versi Arch yang PERSIS
# (lib32-libelf -> libelf=0.197, lib32-expat -> expat=...). Kalau repo Artix
# (system/world) masih versi lama, pacman -Su menarik library itu dari [core]/[extra]
# Arch tapi paket saudaranya (elfutils, yang mengunci libelf=versi lama) tetap
# dari Artix -> "could not satisfy dependencies". Di sini: library dasar, saudara-
# saudaranya yang ikut terkunci, dan lib32-*-nya dinaikkan bersama dari repo Arch
# dalam satu transaksi, sebelum -Su. lib32-nvidia-utils diurus nvidia_hold.
_pac_field() {   # _pac_field <-Si|-Qi> <paket> <nama field> -> nilai (baris lanjutan digabung)
    pacman "$1" "$2" 2>/dev/null | awk -v f="$3" '
        index($0, f) == 1 { sub(/^[^:]*: */, ""); v = $0; on = 1; next }
        on && /^ / { v = v " " $0; next }
        on { exit }
        END { if (v != "None") print v }' || true     # paket tidak ada: kosong, bukan error
}

_ver_is() {      # _ver_is <versi pkg (x.y-rel)> <versi pin (x.y atau x.y-rel)>
    [ "$1" = "$2" ] || [ "${1%-*}" = "$2" ]
}

sync_lib32_pins() {
    grep -q '^\[multilib\]' /etc/pacman.conf || return 0
    local want=() p dep name pin cur repo v r rdep
    for p in $(pacman -Qq | grep '^lib32-'); do
        [ "$p" = lib32-nvidia-utils ] && continue
        for dep in $(_pac_field -Si "multilib/$p" "Depends On"); do
            case "$dep" in lib32-*|*'>'*|*'<'*) continue ;; *=*) ;; *) continue ;; esac
            name="${dep%%=*}"; pin="${dep#*=}"
            cur="$(pacman -Q "$name" 2>/dev/null | awk '{ print $2 }' || true)"
            [ -n "$cur" ] || continue
            _ver_is "$cur" "$pin" && continue
            for repo in core extra; do
                v="$(_pac_field -Si "$repo/$name" "Version")"
                _ver_is "$v" "$pin" || continue
                want+=("$repo/$name" "multilib/$p")
                # saudara yang mengunci library ini ke versi sekarang (elfutils -> libelf=0.196)
                for r in $(_pac_field -Qi "$name" "Required By"); do
                    case "$r" in lib32-*) continue ;; esac
                    for rdep in $(_pac_field -Qi "$r" "Depends On"); do
                        [ "$rdep" = "$name=${cur%-*}" ] || [ "$rdep" = "$name=$cur" ] || continue
                        if _ver_is "$(_pac_field -Si "$repo/$r" "Version")" "$pin"; then
                            want+=("$repo/$r")
                        fi
                    done
                done
                break
            done
        done
    done
    [ "${#want[@]}" -gt 0 ] || return 0
    mapfile -t want < <(printf '%s\n' "${want[@]}" | sort -u)
    echo "    lib32 mengunci versi Arch -- naik bersama dari repo Arch: ${want[*]}"
    pacman -S --needed --noconfirm "${want[@]}" || warn "sinkron lib32 gagal: ${want[*]}"
}

enable_repos() {
    rank_mirrors                      # mirrorlist Artix (mirrorlist-arch belum tentu ada)
    pacman -S --needed --noconfirm artix-archlinux-support
    rank_mirrors                      # sekarang juga mirrorlist-arch
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
    pacman -Sy --noconfirm
    sync_lib32_pins
    NVIDIA_HELD="$(nvidia_hold)"
    if [ -n "$NVIDIA_HELD" ]; then
        warn "driver NVIDIA ditahan: multilib $(pacman -Si lib32-nvidia-utils | awk '/^Version/ { print $3; exit }'), world $(pacman -Si nvidia-open-dkms | awk '/^Version/ { print $3; exit }') -- naik bersama setelah Artix menyusul"
        pacman -Su --noconfirm --ignore "${NVIDIA_HELD// /,}"
    else
        pacman -Su --noconfirm
    fi
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
    case "$ENABLE_SSH" in yes|tailscale) pkgs+=(openssh openssh-dinit) ;; esac
    if [ "$TAILSCALE" = "yes" ]; then pkgs+=(tailscale); fi
    if [ "$MUSIC_MPD" = "yes" ]; then pkgs+=(mpd mpc mpd-mpris); fi
    if [ "$ENABLE_BLUETOOTH" = "yes" ]; then pkgs+=(bluez bluez-utils bluez-dinit bluetui); fi
    if [ "$LOG_PERSIST" = "yes" ]; then pkgs+=(syslog-ng syslog-ng-dinit); fi
    if [ "$LOG_PERSIST" = "yes" ] && [ "$WHYD" = "yes" ]; then pkgs+=(go); fi   # build whyd-init
    if [ "$LIVEPAPER" = "yes" ]; then pkgs+=(gtk4 gtk4-layer-shell python-gobject python-cairo python-numpy); fi
    # driver NVIDIA yang sedang ditahan dan sudah terpasang tidak diminta lagi
    # (kalau diminta, pacman mencoba menaikkannya dan bentrok)
    if [ -n "${NVIDIA_HELD:-}" ]; then
        local keep=() q
        for q in "${pkgs[@]}"; do
            if [[ " $NVIDIA_HELD " == *" $q "* ]] && pacman -Q "$q" >/dev/null 2>&1; then
                continue
            fi
            keep+=("$q")
        done
        pkgs=("${keep[@]}")
    fi
    pacman -S --needed --noconfirm "${pkgs[@]}"
}

# Patch lokal untuk aro (core/patches/aro/*.patch), diterapkan setelah checkout.
# Gagal diterapkan (upstream berubah) -> build berhenti dengan pesan jelas.
apply_aro_patches() {
    local src="$1" pt
    for pt in "$REPO_DIR"/core/patches/aro/*.patch; do
        [ -e "$pt" ] || continue
        if git -C "$src" apply --check "$pt" 2>/dev/null; then
            git -C "$src" apply "$pt"
            echo "    patch aro: $(basename "$pt")"
        else
            die "patch $(basename "$pt") tidak cocok dengan source aro ($ARO_REF) -- perbarui patch-nya"
        fi
    done
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
    apply_aro_patches /opt/aro-src
    # -Deffects=false: tanpa SceneFX (= tanpa AUR); -Dwallpaper=disabled: warna polos
    meson setup /opt/aro-src/build /opt/aro-src --prefix=/usr --buildtype=release \
        -Deffects=false -Dwallpaper=disabled
    ninja -C /opt/aro-src/build
    ninja -C /opt/aro-src/build install
    rm -rf /usr/share/backgrounds/aro
}

# ble.sh: dibangun sekali untuk semua user ke /usr/local/share/blesh (bukan AUR;
# tidak ada di repo resmi). Dipakai ~/.bashrc akun umum (core/home/bashrc).
# UPDATE_BLESH=1 untuk build ulang dari versi terbaru.
install_blesh() {
    [ "$BLESH" = "yes" ] || return 0
    if [ -f /usr/local/share/blesh/ble.sh ] && [ "${UPDATE_BLESH:-0}" != "1" ]; then
        echo "    ble.sh sudah ada -- skip (UPDATE_BLESH=1 untuk build ulang)"
        return 0
    fi
    rm -rf /opt/blesh-src
    git clone --quiet --recursive --depth 1 --shallow-submodules \
        https://github.com/akinomyoga/ble.sh.git /opt/blesh-src
    make -s -C /opt/blesh-src install PREFIX=/usr/local
    echo "    ble.sh dipasang ke /usr/local/share/blesh ($(git -C /opt/blesh-src rev-parse --short HEAD))"
}

# whyd-init (fork whyd dengan backend syslog): membaca /var/log/aro dari LOG_PERSIST,
# menjelaskan kenapa sesi sebelumnya berhenti (shut down / berhenti mendadak / kernel
# panic) beserta masalahnya. Dibangun dari commit WHYD_REF ke /usr/local/bin/whyd;
# dilewati kalau commit itu sudah terpasang (UPDATE_WHYD=1 memaksa build ulang).
install_whyd() {
    [ "$LOG_PERSIST" = "yes" ] && [ "$WHYD" = "yes" ] || return 0
    local src=/opt/whyd-init-src stamp=/usr/local/share/whyd-init.ref
    if [ -x /usr/local/bin/whyd ] && [ "$(cat "$stamp" 2>/dev/null)" = "$WHYD_REF" ] && [ "${UPDATE_WHYD:-0}" != "1" ]; then
        echo "    whyd-init $WHYD_REF sudah ada -- skip (UPDATE_WHYD=1 untuk build ulang)"
        return 0
    fi
    command -v go >/dev/null || { warn "go tidak terpasang -- whyd-init dilewati"; return 0; }
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git clone --quiet https://github.com/d3vzero/whyd-init "$src"
    fi
    git -C "$src" fetch --quiet origin
    git -C "$src" checkout --quiet --force "$WHYD_REF"
    # cache Go di /var/cache, bukan di /root
    if (cd "$src" && GOMODCACHE=/var/cache/whyd-init/mod GOCACHE=/var/cache/whyd-init/build \
            GOFLAGS=-mod=readonly go build -trimpath \
            -ldflags "-s -w -X main.version=init-$WHYD_REF" -o /usr/local/bin/whyd ./cmd/whyd); then
        mkdir -p "$(dirname "$stamp")"; echo "$WHYD_REF" > "$stamp"
        echo "    whyd-init $WHYD_REF -> /usr/local/bin/whyd"
    else
        warn "build whyd-init gagal -- versi lama (kalau ada) tetap dipakai"
    fi
}

# qamariah-livepaper (LIVEPAPER=yes): live wallpaper di layer background aro, dari
# commit LIVEPAPER_REF github.com/d3vzero/qamariah-livepaper ke /usr/local. Membersihkan
# nama lama (aro-livepaper): file di /usr/local dan instance yang masih berjalan.
install_livepaper() {
    local old
    old="$(pgrep -f 'aro-livepaper/livepaper.py' || true)"
    if [ -n "$old" ]; then kill $old 2>/dev/null; echo "    instance aro-livepaper lama dihentikan"; fi
    if [ -e /usr/local/bin/aro-livepaper ] || [ -d /usr/local/share/aro-livepaper ]; then
        rm -f /usr/local/bin/aro-livepaper; rm -rf /usr/local/share/aro-livepaper
        echo "    sisa aro-livepaper di /usr/local dihapus"
    fi
    [ "$LIVEPAPER" = "yes" ] || return 0
    [ -n "$LIVEPAPER_REF" ] || { warn "LIVEPAPER_REF kosong -- qamariah-livepaper dilewati (isi commit di machine.conf)"; return 0; }
    local src=/opt/qamariah-livepaper-src stamp=/usr/local/share/qamariah-livepaper/.ref
    if [ -x /usr/local/bin/qamariah-livepaper ] && [ "$(cat "$stamp" 2>/dev/null)" = "$LIVEPAPER_REF" ] && [ "${UPDATE_LIVEPAPER:-0}" != "1" ]; then
        echo "    qamariah-livepaper $LIVEPAPER_REF sudah ada -- skip (UPDATE_LIVEPAPER=1 untuk pasang ulang)"
        return 0
    fi
    [ -d "$src/.git" ] || { rm -rf "$src"; git clone --quiet https://github.com/d3vzero/qamariah-livepaper "$src"; }
    git -C "$src" fetch --quiet origin
    git -C "$src" checkout --quiet --force "$LIVEPAPER_REF"
    # install.sh milik repo: memasang semua file (launcher, menu, data) -- file baru di
    # versi berikutnya ikut terpasang tanpa mengubah dotfiles. Dependensi sudah ada.
    (cd "$src" && sh ./install.sh) > /tmp/qamariah-livepaper-install.log 2>&1 ||
        { warn "install.sh qamariah-livepaper gagal -- lihat /tmp/qamariah-livepaper-install.log"; return 0; }
    echo "$LIVEPAPER_REF" > "$stamp"
    echo "    qamariah-livepaper $LIVEPAPER_REF -> /usr/local/bin/qamariah-livepaper"
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
    find "$REPO_DIR"/core/bin -maxdepth 1 -type f -exec install -m755 -t /usr/local/bin/ {} +
    install -m755 "$REPO_DIR"/tools/aro-stress /usr/local/bin/   # uji ketahanan aro (tools/README.md)
    # Entry launcher (fuzzel): superfile + Pengaturan (Jaringan, Bluetooth, Monitor
    # digabung di aro-settings). network/bluetooth.desktop versi lama dibuang.
    install -d /usr/local/share/applications
    install -m644 "$REPO_DIR"/core/desktop/*.desktop /usr/local/share/applications/
    rm -f /usr/local/share/applications/network.desktop /usr/local/share/applications/bluetooth.desktop
    # whyd hanya di launcher kalau memang dipasang
    if [ "$LOG_PERSIST" != "yes" ] || [ "$WHYD" != "yes" ]; then rm -f /usr/local/share/applications/whyd.desktop; fi
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

# Tailscale (TAILSCALE=yes): VPN pribadi -> PC bisa dijangkau dari mana saja tanpa
# membuka port (juga di belakang CGNAT). Login akun Tailscale sekali, manual:
#   sudo tailscale up --accept-dns=false
# (--accept-dns=false: tailscale tidak menimpa /etc/resolv.conf milik NetworkManager)
setup_tailscale() {
    local svc=/etc/dinit.d/tailscaled
    if [ "$TAILSCALE" != "yes" ]; then
        if [ -e /etc/dinit.d/boot.d/tailscaled ]; then
            rm -f /etc/dinit.d/boot.d/tailscaled
            dinitctl stop tailscaled >/dev/null 2>&1 || true
            echo "    tailscaled dinonaktifkan"
        fi
        return 0
    fi
    # service dinit sendiri, kecuali sudah disediakan paket (mis. tailscale-dinit)
    if ! pacman -Qqo "$svc" >/dev/null 2>&1; then
        cat > "$svc" <<'EOF'
# dikelola dotfiles-aro (TAILSCALE=yes)
type = process
command = /bin/sh -c "mkdir -p /run/tailscale /var/lib/tailscale && exec /usr/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641"
waits-for = NetworkManager
restart = true
smooth-recovery = true
logfile = /var/log/tailscaled.log
EOF
    fi
    ln -sf "$svc" /etc/dinit.d/boot.d/
    dinitctl start tailscaled >/dev/null 2>&1 || true
    if tailscale status >/dev/null 2>&1; then
        echo "    tailscale: $(tailscale ip -4 2>/dev/null | head -n1) ($(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null))"
    else
        echo "    tailscale terpasang -- login sekali: sudo tailscale up --accept-dns=false"
    fi
}

# Folder bersama (SHARED_DIR): bisa dibaca & ditulis SEMUA akun manusia (UID 1000+,
# sekarang maupun yang dibuat nanti) lewat grup "shared" + ACL. ACL bawaan diwariskan
# ke setiap file/folder baru, jadi isi dari akun mana pun (juga SFTP/X-plore) tetap
# bisa diubah akun lain. Tiap akun mendapat pintasan ~/shared.
#   SHARED_FIX=1  terapkan ulang ACL ke seluruh isi (mis. file yang disalin dengan
#                 izin lama); tanpa itu hanya folder utama & subfolder yang disentuh.
setup_shared() {
    [ -n "$SHARED_DIR" ] || return 0
    local d="$SHARED_DIR" u home sub users=()
    getent group shared >/dev/null || groupadd -r shared
    while IFS=: read -r u _ uid _ _ home shell; do
        [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
        case "$shell" in */nologin|*/false) continue ;; esac
        [ -d "$home" ] || continue
        users+=("$u")
        id -nG "$u" | tr ' ' '\n' | grep -qx shared || usermod -aG shared "$u"
    done < /etc/passwd
    if [ ! -d "$d" ]; then
        install -d -m 2770 -o "$ADMIN_USER" -g shared "$d"
        echo "    folder bersama dibuat: $d"
    fi
    chgrp shared "$d"; chmod 2770 "$d"
    for sub in $SHARED_SUBDIRS; do
        [ -d "$d/$sub" ] || install -d -m 2770 -o "$ADMIN_USER" -g shared "$d/$sub"
    done
    # grup shared (semua akun, juga yang baru) + entri per akun yang sudah ada sebelumnya
    local acl="g:shared:rwx" dacl="g:shared:rwx"
    for u in "${users[@]}"; do acl+=",u:$u:rwx"; dacl+=",u:$u:rwx"; done
    if [ "${SHARED_FIX:-0}" = "1" ]; then
        chgrp -R shared "$d"
        find "$d" -type d -exec chmod g+rwxs {} +
        setfacl -R -m "$acl" "$d"
        find "$d" -type d -exec setfacl -d -m "$dacl" {} +
        echo "    ACL folder bersama diterapkan ulang ke seluruh isi (SHARED_FIX=1)"
    else
        for sub in "$d" $(for s in $SHARED_SUBDIRS; do echo "$d/$s"; done); do
            chgrp shared "$sub"; chmod g+rwxs "$sub"
            setfacl -m "$acl" "$sub"; setfacl -d -m "$dacl" "$sub"
        done
    fi
    for u in "${users[@]}"; do
        home="$(getent passwd "$u" | cut -d: -f6)"
        if [ ! -e "$home/shared" ] || [ -L "$home/shared" ]; then
            ln -sfn "$d" "$home/shared"; chown -h "$u:" "$home/shared" 2>/dev/null || true
        fi
    done
    echo "    folder bersama: $d (${users[*]}; grup shared)"
}

enable_services() {
    local svc
    for svc in NetworkManager elogind; do
        ln -sf /etc/dinit.d/$svc /etc/dinit.d/boot.d/
    done
    setup_tailscale
    local dropin=/etc/ssh/sshd_config.d/10-aro.conf
    case "$ENABLE_SSH" in
    yes|tailscale)
        if [ "$ENABLE_SSH" = tailscale ]; then
            # login (SSH/SFTP) hanya dari jaringan Tailscale; dari LAN/internet ditolak
            install -d /etc/ssh/sshd_config.d
            grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config ||
                sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
            cat > "$dropin" <<EOF
# dikelola dotfiles-aro (ENABLE_SSH=tailscale) -- jangan diedit, ditulis ulang tiap update
PermitRootLogin no
AllowUsers $ADMIN_USER@100.64.0.0/10 $ADMIN_USER@fd7a:115c:a1e0::/48
EOF
        else
            rm -f "$dropin"
        fi
        ssh-keygen -A >/dev/null 2>&1 || true          # host key: dibuat sekali kalau belum ada
        if sshd -t 2>/tmp/sshd-test.log; then
            ln -sf /etc/dinit.d/sshd /etc/dinit.d/boot.d/
            dinitctl restart sshd >/dev/null 2>&1 || dinitctl start sshd >/dev/null 2>&1 || true
            echo "    sshd aktif ($ENABLE_SSH)"
        else
            warn "konfigurasi sshd tidak valid -- lihat /tmp/sshd-test.log; sshd tidak diaktifkan"
            rm -f /etc/dinit.d/boot.d/sshd
        fi
        ;;
    *)
        rm -f /etc/dinit.d/boot.d/sshd "$dropin"
        ;;
    esac
    if [ "$ENABLE_BLUETOOTH" = "yes" ]; then
        [ -e /etc/dinit.d/bluetoothd ] || warn "service dinit 'bluetoothd' tidak ada -- cek: ls /etc/dinit.d | grep -i blue"
        ln -sf /etc/dinit.d/bluetoothd /etc/dinit.d/boot.d/
        # kebijakan D-Bus BlueZ mengizinkan grup lp -> bluetoothctl/bluetui tanpa "Access denied"
        usermod -aG lp "$PUBLIC_USER"
    else
        rm -f /etc/dinit.d/boot.d/bluetoothd
    fi
    # Wi-Fi baru dari akun umum: default polkit NM untuk settings.modify.system
    # adalah "auth", dan aro tidak punya polkit agent -> nmtui gagal menyimpan
    # ("Insufficient privileges"). Rule ini memberi YES untuk grup network saja.
    if [ "$PUBLIC_NETWORK_CONTROL" = "yes" ]; then
        groupadd -f network
        usermod -aG network "$PUBLIC_USER"
        install -Dm644 "$REPO_DIR/core/polkit/50-networkmanager.rules" \
            /etc/polkit-1/rules.d/50-networkmanager.rules
    else
        rm -f /etc/polkit-1/rules.d/50-networkmanager.rules
        gpasswd -d "$PUBLIC_USER" network >/dev/null 2>&1 || true
    fi
}

# Log persisten (LOG_PERSIST=yes): syslog-ng menulis /var/log/aro/<tanggal>.log
# (TAB: waktu level program pid pesan, fsync tiap baris), service aro-bootlog
# menandai boot / shutdown bersih dan menyimpan catatan crash kernel (pstore).
# Tanpa ini, log boot sebelumnya hilang saat reboot (tidak ada journald di Artix).
setup_logging() {
    if [ "$LOG_PERSIST" != "yes" ]; then
        rm -f /etc/dinit.d/boot.d/aro-bootlog /etc/dinit.d/boot.d/syslog-ng
        return 0
    fi
    command -v syslog-ng >/dev/null || { warn "syslog-ng tidak terpasang -- log persisten dilewati"; return 0; }
    [ -f /etc/syslog-ng/syslog-ng.conf.orig ] || cp -a /etc/syslog-ng/syslog-ng.conf /etc/syslog-ng/syslog-ng.conf.orig 2>/dev/null
    # @version: current = versi yang terpasang (output --version berubah format antar versi)
    install -m644 "$REPO_DIR/core/logging/syslog-ng.conf.in" /etc/syslog-ng/syslog-ng.conf
    install -d -o root -g log -m 0750 /var/log/aro
    install -m644 "$REPO_DIR/core/dinit/aro-bootlog" /etc/dinit.d/aro-bootlog
    [ -e /etc/dinit.d/syslog-ng ] || warn "service dinit 'syslog-ng' tidak ada -- cek: ls /etc/dinit.d | grep -i syslog"
    ln -sf /etc/dinit.d/syslog-ng /etc/dinit.d/boot.d/
    ln -sf /etc/dinit.d/aro-bootlog /etc/dinit.d/boot.d/
    usermod -aG log "$ADMIN_USER"           # Admin membaca log (aro-lastboot) tanpa sudo
    if syslog-ng --syntax-only >/dev/null 2>&1; then echo "    log persisten: /var/log/aro (syslog-ng)"
    else warn "config syslog-ng ditolak: syslog-ng --syntax-only"; fi
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
               "$H/.config/mako" "$H/.config/zathura" "$H/.config/gtk-3.0" \
               "$H/.config/gtk-4.0" "$H/.config/xdg-desktop-portal" \
               "$H/.config/xdg-desktop-portal-wlr" "$H/.local/share/applications"

    # .bashrc (prompt, riwayat, ble.sh)
    install -m644 "$REPO_DIR/core/home/bashrc" "$H/.bashrc"
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
    sed -i -e 's/^# wallpaper = auto$/wallpaper = none/' \
           -e 's/spawn, foot$/spawn, kitty/' \
           -e '/^bind = mod+w, wallpapers/d' \
           -e 's/^layout = dwindle$/layout = scroll/' "$AC"
    { echo; cat "$T/config/aro/overrides.conf"; } >> "$AC"
    if [ "$ENABLE_BLUETOOTH" = "yes" ]; then
        printf '\nbind = mod+b, spawn, kitty --class bluetui -e bluetui\n' >> "$AC"
        # segmen bar: nama perangkat Bluetooth, kiri jaringan; klik -> bluetui
        printf 'bar_segment = top right bt  kitty --class bluetui -e bluetui\n' >> "$AC"
    fi
    # bawah kiri setelah MIC/SPK: DAC (MUSIC_MPD), lalu media MPRIS
    if [ "$MUSIC_MPD" = "yes" ]; then
        printf '\n# MPD + DAC (MUSIC_MPD): klik = DAC aktif, mode bit-perfect/bersama, Check…\nbar_segment = bottom left dac  aro-dac menu\nexec = aro-mpd\n' >> "$AC"
    fi
    printf '\n# media MPRIS (MPD, Sung, Firefox, mpv): klik = play/pause\nbar_segment = bottom left media  aro-player play-pause\n' >> "$AC"
    if [ "$LIVEPAPER" = "yes" ]; then
        printf '\n# live wallpaper (LIVEPAPER): langit, bulan, bintang, laut -- layer background\nexec = qamariah-livepaper\n' >> "$AC"
        printf 'bind = mod+w, spawn, qamariah-livepaper-menu\n' >> "$AC"   # scene, lokasi, kehalusan
        # config: dibuat sekali (dari config lama aro-livepaper kalau ada), lalu milik user
        local lp="$H/.config/qamariah-livepaper/config.ini" lpo="$H/.config/aro-livepaper/config.ini"
        if [ ! -e "$lp" ]; then
            install -d -o "$PUBLIC_USER" -g "$PUBLIC_USER" "$H/.config/qamariah-livepaper"
            if [ -f "$lpo" ]; then cp "$lpo" "$lp"; else cp /usr/local/share/qamariah-livepaper/config.example.ini "$lp"; fi
            chown "$PUBLIC_USER:$PUBLIC_USER" "$lp"
            echo "    config live wallpaper: $lp (lat/lon = lokasi pengamat)"
        fi
    fi
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
    if ! grep -q '^wallpaper = none' "$AC";  then warn "aro: 'wallpaper = none' tidak ter-set (config.example berubah?)"; fi
    if ! grep -q 'spawn, kitty$' "$AC";      then warn "aro: terminal default belum diganti ke kitty (config.example berubah?)"; fi
    if ! grep -q '^layout = scroll' "$AC";   then warn "aro: 'layout = scroll' tidak ter-set (config.example berubah?)"; fi

    cp "$T/config/fuzzel/fuzzel.ini" "$H/.config/fuzzel/fuzzel.ini"
    cp "$T/config/kitty/kitty.conf"  "$H/.config/kitty/kitty.conf"
    # tema hitam putih: notifikasi, PDF viewer, aplikasi GTK (Firefox, Mousepad)
    cp "$T/config/mako/config"        "$H/.config/mako/config"
    cp "$T/config/zathura/zathurarc"  "$H/.config/zathura/zathurarc"
    cp "$T/config/gtk-3.0/settings.ini" "$H/.config/gtk-3.0/settings.ini"
    cp "$T/config/gtk-4.0/settings.ini" "$H/.config/gtk-4.0/settings.ini"
    # portal: XDG_CURRENT_DESKTOP=aro tidak dikenal xdg-desktop-portal-wlr -> tanpa
    # file ini daftar sumber di OBS/Firefox kosong
    cp "$T/config/xdg-desktop-portal/aro-portals.conf" "$H/.config/xdg-desktop-portal/aro-portals.conf"
    cp "$T/config/xdg-desktop-portal-wlr/config"       "$H/.config/xdg-desktop-portal-wlr/config"
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

# NVIDIA: hook "kms" memasukkan modul nouveau ke initramfs, yang bisa merebut
# GPU saat boot awal sebelum nvidia dimuat (Arch wiki: hapus kms dari HOOKS).
setup_initramfs() {
    if [ "$GPU" = nvidia ] && grep -qE '^HOOKS=.*[( ]kms[ )]' /etc/mkinitcpio.conf; then
        sed -i -E '/^HOOKS=/ s/ kms( |\))/\1/' /etc/mkinitcpio.conf
        echo "    hook kms dihapus dari mkinitcpio (NVIDIA) -- initramfs dibuat ulang"
        mkinitcpio -P
    fi
}
