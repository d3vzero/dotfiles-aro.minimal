# Instalasi dotfiles-aro.minimal — Artix dinit + aro (CPU & GPU AMD)

Satu disk NVMe, EFISTUB (tanpa GRUB), tanpa AUR. Dua script:

| Script | Kapan | Sebagai |
|---|---|---|
| `bootstrap/install-chroot.sh` | Sekali, di dalam chroot | root |
| `update.sh` | Kapan saja setelah sistem jalan | `Admin` lewat `sudo` |

Semua dikerjakan root (tidak ada AUR = tidak perlu `makepkg` sebagai user),
termasuk menulis home user umum lalu `chown`.

**Yang dibutuhkan:** USB ISO `artix-base-dinit` + internet. Repo ini harus
**public** (di-clone tanpa login di dalam chroot).

---

## 1. Partisi, format, mount (live ISO)

> ⚠️ Langkah ini **menghapus seluruh isi disk**. Cek nama disk dulu.

**1. Cek disk** — cocokkan dari ukurannya, jangan asumsi dari nama:
```
lsblk
```
Contoh di bawah memakai `nvme0n1` (PC). Untuk VM virtio, ganti
`nvme0n1` → `vda`, `nvme0n1p1` → `vda1`, `nvme0n1p2` → `vda2`.

**2. Partisi:**
```
cfdisk /dev/nvme0n1
```
Pilih `gpt` → **New** `512M` → **Type** `EFI System` → **New** (sisa disk)
→ **Type** `Linux filesystem` → **Write** → ketik `yes` → **Quit**.

**3. Format:**
```
mkfs.fat -F 32 /dev/nvme0n1p1
mkfs.ext4 /dev/nvme0n1p2
```

**4. Mount** — ESP ke `/mnt/boot` (bukan `/mnt/boot/efi`):
```
mount /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
```

**5. Cek WAJIB sebelum basestrap:**
```
lsblk -f
```
Harus terlihat `nvme0n1p1` **vfat** di `/mnt/boot` dan `nvme0n1p2` **ext4**
di `/mnt`. Kalau `/mnt/boot` tidak muncul, kernel akan terpasang ke
partisi root dan bootstrap menolak jalan (`/boot bukan partisi EFI`).

## 2. Basestrap

```
basestrap /mnt base base-devel linux linux-firmware linux-headers dinit elogind-dinit neovim git efibootmgr
fstabgen -U /mnt >> /mnt/etc/fstab
```

## 3. Chroot, clone, atur mesin, jalankan bootstrap

```
artix-chroot /mnt
git clone https://github.com/d3vzero/dotfiles-aro.minimal /opt/dotfiles-aro.minimal
cp /opt/dotfiles-aro.minimal/machine.conf /etc/dotfiles-aro.minimal.conf
nvim /etc/dotfiles-aro.minimal.conf
bash /opt/dotfiles-aro.minimal/bootstrap/install-chroot.sh
```
Di `/etc/dotfiles-aro.minimal.conf` yang paling sering diubah: `HOST_NAME`,
`PROFILES` (`daily`, `work`, `ai`, pisah spasi), `IS_VM` (biarkan `auto`).
Isi password **root** dan **Admin** saat diminta. User umum (`Assy`)
sengaja tanpa password.

```
exit
umount -R /mnt
reboot
```
Cabut USB. Komputer boot langsung (EFISTUB) → autologin `Assy` → aro.

## 4. Keybind tambahan

Semua bind default aro tetap ada (lihat `/usr/share/doc/aro/config.example`).
Tambahan dari repo ini:

| Tombol | Fungsi |
|---|---|
| `Ctrl+Alt+Del` | Menu Shutdown / Reboot |
| `Super+e` | File manager (superfile) |
| `Super+n` | Atur jaringan (nmtui) |

## 5. Admin & update

Admin login di tty lain: `Ctrl+Alt+F2` → login `Admin`.
```
sudo git -C /opt/dotfiles-aro.minimal pull
sudo /opt/dotfiles-aro.minimal/update.sh
```
Opsi (gabungkan seperlunya):
```
sudo UPDATE_ARO=1 UPDATE_ONLYOFFICE=1 /opt/dotfiles-aro.minimal/update.sh
```
`UPDATE_ARO` rebuild aro · `UPDATE_ONLYOFFICE` download ulang AppImage ·
`UPDATE_PROTONGE` Proton-GE terbaru · `UPDATE_LLAMA` pull + rebuild llama.cpp.

Ganti profil: edit `PROFILES` di `/etc/dotfiles-aro.minimal.conf`, lalu jalankan
`update.sh`. (Profil yang dihapus tidak meng-uninstall paket.)

> Config di home `Assy` **di-copy dan ditimpa** tiap `update.sh` — repo
> adalah sumber kebenaran. Perubahan langsung di home `Assy` akan hilang;
> ubah di repo lalu jalankan `update.sh`.

## 6. Catatan per profil

- **work** — FreeCAD, KiCad (+library), OnlyOffice (AppImage resmi di
  `/opt/onlyoffice`, tidak lewat AUR). Printer tidak dipasang: pakai
  *Export/Print to PDF*.
- **daily** — Steam, OBS, Proton-GE system-wide
  (`/usr/share/steam/compatibilitytools.d`). Mengaktifkan `[multilib]` +
  `[core]` Arch otomatis. DaVinci Resolve **tidak** termasuk (butuh AUR).
- **ai** — llama.cpp dengan backend **Vulkan** (jalan di GPU AMD lewat
  `vulkan-radeon`, tanpa ROCm). Binary: `llama-server`, `llama-cli`.
  Model GGUF download manual ke `/srv/models/`.

## 7. Kalau BIOS "lupa" entry boot

Beberapa BIOS menghapus entry EFISTUB setelah update firmware. Boot lagi
ISO, mount seperti langkah 1, `artix-chroot /mnt`, lalu:
```
efibootmgr        # cek entry "Artix" masih ada atau tidak
bash /opt/dotfiles-aro.minimal/bootstrap/install-chroot.sh
```
Bootstrap aman diulang: entry lama berlabel sama dihapus lalu dibuat ulang.
Cadangan jangka panjang: bootloader `limine` (repo resmi).
