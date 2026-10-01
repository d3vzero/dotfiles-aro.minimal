#!/bin/bash
# bootstrap/install-chroot.sh -- instalasi penuh dotfiles-aro.minimal.
# Jalan SEKALI di dalam `artix-chroot /mnt` sebagai root, dari repo yang
# sudah di-clone ke /opt/dotfiles-aro.minimal (lihat docs/INSTALL.md).
# Target: Artix dinit, CPU + GPU AMD, EFISTUB (tanpa GRUB), tanpa AUR.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF=/etc/dotfiles-aro.minimal.conf
# shellcheck source=../lib/apply.sh
. "$REPO_DIR/lib/apply.sh"

require_root
# Tolak jalan di sistem yang sedang hidup: di dalam chroot, "/" berbeda
# dengan root milik PID 1 (host). Kalau sama -> bukan chroot -> stop.
if [ "$(stat -c %d:%i /)" = "$(stat -c %d:%i /proc/1/root/.)" ]; then
    die "Bukan di dalam chroot. Untuk sistem yang sudah jalan: sudo /opt/dotfiles-aro.minimal/update.sh"
fi
if [ "$(findmnt -no FSTYPE /boot 2>/dev/null)" != "vfat" ]; then
    die "/boot bukan partisi EFI (vfat). Mount ESP ke /mnt/boot sebelum chroot."
fi

if [ ! -f "$CONF" ]; then
    cp "$REPO_DIR/machine.conf" "$CONF"
    warn "$CONF belum ada -- dibuat dari default machine.conf"
fi
load_conf "$CONF"

step "[1/10] Deteksi mesin"
detect_vm

step "[2/10] Zona waktu, locale, hostname"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
grep -v '^en_US.UTF-8 UTF-8' /etc/locale.gen > /tmp/locale.gen.new || true
echo 'en_US.UTF-8 UTF-8' >> /tmp/locale.gen.new
mv /tmp/locale.gen.new /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo "$HOST_NAME" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOST_NAME" "$HOST_NAME" > /etc/hosts

step "[3/10] Repo Arch + full upgrade"
enable_repos

step "[4/10] Paket (core + profil: $PROFILES)"
install_packages

step "[5/10] User & sudo"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd -m -G wheel "$ADMIN_USER"
fi
if ! id "$PUBLIC_USER" >/dev/null 2>&1; then
    useradd -m -G video,audio "$PUBLIC_USER"      # sengaja tanpa password
fi
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo ">> Password root:"
passwd
echo ">> Password $ADMIN_USER:"
passwd "$ADMIN_USER"

step "[6/10] aro (build dari source) + superfile"
build_aro
install_superfile

step "[7/10] File sistem + service dinit"
install_system_files
enable_services

step "[8/10] Setup profil"
run_profile_hooks

step "[9/10] Home $PUBLIC_USER"
setup_public_home

step "[10/10] EFISTUB"
ESP_SRC="$(findmnt -no SOURCE /boot)"
ESP_DISK="/dev/$(lsblk -no PKNAME "$ESP_SRC")"
ESP_PART="$(cat "/sys/class/block/$(basename "$ESP_SRC")/partition")"
ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_SRC="${ROOT_SRC%%\[*}"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC")"
[ -n "$ROOT_UUID" ] || die "UUID root tidak terbaca dari $ROOT_SRC"
[ -f /boot/vmlinuz-linux ] || die "/boot/vmlinuz-linux tidak ada"

INITRD=""
if [ "$IS_VM" != "yes" ]; then INITRD='initrd=\amd-ucode.img '; fi
CMDLINE="root=UUID=$ROOT_UUID rw ${INITRD}initrd=\\initramfs-linux.img quiet"
echo "    disk=$ESP_DISK part=$ESP_PART"
echo "    cmdline: $CMDLINE"

if efibootmgr | grep -qE "^Boot[0-9A-Fa-f]{4}\*? ${EFI_LABEL}([[:space:]]|$)"; then
    warn "Entry EFI '$EFI_LABEL' sudah ada -- tidak dibuat ulang (hapus dulu dengan efibootmgr -b XXXX -B kalau mau diganti)"
else
    efibootmgr --create --disk "$ESP_DISK" --part "$ESP_PART" --label "$EFI_LABEL" \
        --loader /vmlinuz-linux --unicode "$CMDLINE"
fi

echo
echo "==> SELESAI bootstrap."
echo "    exit -> umount -R /mnt -> reboot (cabut USB)"
echo "    Setelah boot: autologin $PUBLIC_USER -> aro."
echo "    Admin: Ctrl+Alt+F2, login $ADMIN_USER. Update: sudo /opt/dotfiles-aro.minimal/update.sh"
