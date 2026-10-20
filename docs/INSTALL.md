# Instalasi dotfiles-aro.minimal — Artix dinit + aro

Satu disk NVMe, EFISTUB (tanpa GRUB), tanpa AUR. Satu core untuk dua jenis
mesin:

| Mesin | `PROFILES` | User umum | GPU |
|---|---|---|---|
| PC kantor | `office cad` | `Assy` | AMD |
| Workstation AI | `office ai` | mis. `AI-Trainer` | NVIDIA RTX 5060 / 5080 |

Dua script:

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
Di `/etc/dotfiles-aro.minimal.conf` yang wajib dicek: `HOST_NAME`,
`PUBLIC_USER`, `PROFILES` (`office cad daily ai`, pisah spasi), dan
hardware `CPU` / `GPU` / `GPU_GEN` (bagian 3a). Bootstrap membandingkan
isian hardware dengan yang terdeteksi; kalau tidak cocok muncul peringatan
dan konfirmasi `[y/N]` — tidak pernah diganti diam-diam.
Isi password **root** dan **Admin** saat diminta. User umum sengaja tanpa
password.

```
exit
umount -R /mnt
reboot
```
Cabut USB. Komputer boot langsung (EFISTUB) → autologin `Assy` → aro.

## 3a. Hardware: CPU / GPU / GPU_GEN

GPU yang didukung:

| `GPU` | Didukung | Tidak didukung |
|---|---|---|
| `amd` | GCN3+: RX 400 ke atas, Vega, RDNA, iGPU Ryzen | GCN1/2 (HD 7000, R7/R9 200) dan sebelumnya |
| `nvidia` | Turing+: GTX 16xx, RTX 20xx ke atas | Maxwell/Pascal (GTX 9xx/10xx) dan sebelumnya |
| `intel` | `GPU_GEN=new`: Broadwell+ · `GPU_GEN=old`: Haswell ke bawah | — |
| `vm` | VM QEMU/KVM, VirtualBox, VMware | — |

`GPU_GEN` hanya dipakai untuk Intel; untuk GPU lain biarkan `new`
(`old` ditolak dengan pesan error).

Yang dipasang otomatis:

| Pilihan | Paket | Parameter kernel |
|---|---|---|
| `CPU=amd` / `intel` | `amd-ucode` / `intel-ucode` | `initrd=\amd-ucode.img` / `initrd=\intel-ucode.img` |
| `GPU=vm` | `mesa` (tanpa ucode) | — |
| `GPU=amd` | `mesa vulkan-radeon` | — |
| `GPU=nvidia` | `nvidia-open-dkms nvidia-utils libva-nvidia-driver egl-wayland` | `nvidia_drm.modeset=1 nvidia_drm.fbdev=1` |
| `GPU=intel` new | `mesa vulkan-intel intel-media-driver` | — |
| `GPU=intel` old | `mesa vulkan-intel libva-intel-driver` | — |

Profil `daily` menambah driver 32-bit Steam yang sesuai GPU.

- Di Artix wajib **`nvidia-open-dkms`** (kernel Artix beda build dengan Arch;
  butuh `linux-headers`, sudah di basestrap). RTX 50xx hanya didukung open module.
- `GPU=nvidia`: hook `kms` dihapus dari `/etc/mkinitcpio.conf` supaya
  nouveau tidak masuk initramfs dan merebut GPU saat boot awal.
- aro di NVIDIA **belum diuji** — jalankan stress test dulu (`tools/`).
  Kalau ada glitch tampilan, coba tambahkan `export WLR_RENDERER=vulkan`.
- `GPU=vm`: tanpa microcode, plus `WLR_NO_HARDWARE_CURSORS=1` dan core dump
  aktif di `.bash_profile`.

## 3b. tmpfs (kurangi tulis ke NVMe)

Dipasang bootstrap dan `update.sh` lewat `core/setup-tmpfs.sh` (idempotent,
cadangan `/etc/fstab.bak-tmpfs`), berlaku setelah reboot:

| Lokasi | Ukuran (config) | Catatan |
|---|---|---|
| `/tmp` | `TMPFS_TMP_SIZE` (default `50%` RAM) | tanpa `noexec` (AppImage OnlyOffice mount di `/tmp`); dataset SH Trainer di-copy ke sini |
| `~/.cache` user umum | `TMPFS_CACHE_SIZE` (default `2G`, AI: `4G`) | tanpa `noexec` (cache `.so` triton/torch) |
| partisi ext4 | — | `relatime` → `noatime` |

**Tidak** di RAM: checkpoint/output training, `~/.torch`, venv. Cache yang
mahal dibuat ulang (shader Mesa/NVIDIA, matplotlib) diarahkan ke
`~/.local/state/` lewat env di `.bash_profile`.

> Ukuran baru di config **tidak** mengubah baris fstab yang sudah ada —
> edit `/etc/fstab` manual lalu reboot.
> Risiko: dataset besar bisa memenuhi `/tmp` ("No space left on device"),
> dan isi `/tmp` hilang saat reboot. Sesuaikan `TMPFS_TMP_SIZE` dengan RAM.

## 4. Keybind tambahan

**Layout default: scroll** (kolom di strip horizontal, `Super+T` mengganti
layout per workspace). Kolom yang difokus — termasuk aplikasi yang baru dibuka —
**selalu di tengah layar** (`scroll_center = true`). Opsi ini dari patch lokal
`core/patches/aro/0001-scroll-center.patch` yang diterapkan setiap aro dibuild;
kalau upstream aro berubah sampai patch tidak cocok, build berhenti dengan pesan jelas.

Semua bind default aro tetap ada (lihat `/usr/share/doc/aro/config.example`).
Tambahan dari repo ini:

| Tombol | Fungsi |
|---|---|
| `Ctrl+Alt+Del` | Menu Shutdown / Reboot (opsi pertama **Batal** + peringatan kalau training/GPU berjalan) |
| `Super+e` | File manager (superfile) |
| `Super+n` | Atur jaringan (nmtui) |
| `Super+b` | Bluetooth: scan, pair, connect (`bluetui`) — hanya kalau `ENABLE_BLUETOOTH="yes"` |
| `Super+Shift+c` | Cheatsheet keybind aro + superfile (dibaca dari config aktif) |
| `Super+Shift+s` | Screenshot: menu Window (default, Enter) / Region / Full screen → `~/Pictures/Screenshot` + clipboard |
| `Super+Shift+r` | Mulai/stop rekam layar (resolusi aktif, audio desktop + mic, .mp4) → `~/Videos/Casual` |
| Play/Pause · Next · Prev · Stop | tombol multimedia keyboard, atau `Super+P` · `Super+]` · `Super+[` · `Super+Shift+P` (Sung, Firefox, mpv lewat MPRIS) |
| Volume naik · turun · mute | tombol multimedia keyboard, atau `Super+F12` · `Super+F11` · `Super+F10` (maks. 100%, notifikasi level) |
| `Super+u` | Menu update: pilih satu item (lihat bagian 5a) |
| `Super+Ctrl+u` | Update semua yang ada update-nya (konfirmasi, default **Batal**) |

## 4a. Settings & display

`Super+D` → **Settings** membuka menu: **Network** (nmtui), **Bluetooth**
(bluetui, kalau `ENABLE_BLUETOOTH="yes"`), dan **Display**.

**Display** menampilkan resolusi + refresh rate (dari `MONITOR_MODES` di config,
atau semua mode yang dilaporkan monitor kalau kosong) beserta rasio. Setelah
memilih muncul konfirmasi **Keep / Revert**; tanpa jawaban 15 detik layar kembali
ke mode sebelumnya. Memilih mode yang sedang aktif (`● active`) menyimpannya.
Mode tersimpan per user (`~/.local/state/aro-monitor/mode`), dipasang lagi saat login.

Mode di luar daftar EDID monitor dicoba sebagai *custom mode*. **Driver NVIDIA
menolak custom mode** (teruji: 2560x1440 di panel 2560x1600 ditolak, bahkan 60 Hz),
jadi di workstation NVIDIA isi `MONITOR_MODES` hanya dengan mode bawaan monitor:
```
MONITOR_MODES="2560x1600@60 2560x1600@240 2560x1600@300"
```
Dari terminal: `monitor-mode apply 2560x1600@240` (tanpa menyimpan).

## 4c. Screenshot & rekam layar

- **`Super+Shift+S`** → menu kecil, **Window** di urutan pertama (cukup Enter):
  jendela yang difokus (ukuran dari `aroctl -j focused`). **Region** = seret area
  (slurp), **Full screen** = monitor yang difokus. Hasil `.png` di
  `~/Pictures/Screenshot/` dan disalin ke clipboard.
- **`Super+Shift+R`** → mulai rekam monitor yang difokus di **resolusi aktif**,
  audio desktop + mikrofon digabung, `.mp4` di `~/Videos/Casual/`. Tekan lagi
  untuk berhenti (file ditutup rapi). Encoder video mengikuti `GPU`: nvidia →
  `h264_nvenc`, amd/intel → `h264_vaapi`, lainnya `libx264`. FPS dari
  `RECORD_FPS` (default 60; monitor 240/300 Hz tidak direkam sepenuh itu).
  Log kalau gagal: `$XDG_RUNTIME_DIR/casual-record/log`.

## 4d. Membuka file (superfile / xdg-open)

Enter di superfile memakai aplikasi default dari `~/.config/mimeapps.list`
(`core/home/config/mimeapps.list`), bukan Firefox:

| Jenis | Dibuka dengan |
|---|---|
| PDF | zathura |
| Word/Excel/PowerPoint, ODF, CSV | OnlyOffice (profil office) |
| Teks & kode (txt, md, sh, py, json, yaml, toml, xml, log, …) | Mousepad |
| Gambar (png, jpg, gif, webp, svg, …) | imv |
| Video & audio | mpv |
| Arsip (zip, tar, tar.gz/xz/zst/bz2, 7z, rar, …) | `archive-open`: menu **Extract here** / **Extract to folder** / **Show contents** |
| Folder | superfile |

Jenis yang tidak terdaftar tetap jatuh ke aplikasi default sistem (biasanya Firefox).
Tambahkan baris `tipe/mime=aplikasi.desktop` ke file itu lalu jalankan `update.sh`.
Cek tipe sebuah file: `xdg-mime query filetype FILE`.

## 4b. Bluetooth (`ENABLE_BLUETOOTH`)

`ENABLE_BLUETOOTH="yes"` memasang `bluez bluez-utils bluez-dinit bluetui`,
mengaktifkan service `bluetoothd`, menambah user umum ke grup `lp` (kebijakan
D-Bus BlueZ), dan menulis bind `Super+B` → `bluetui`. Audio Bluetooth tidak
butuh paket tambahan (PipeWire + WirePlumber di core); headset muncul sebagai
output audio setelah connect. `"no"` mematikan service dan bind (paket tidak
di-uninstall).

Cek setelah reboot:
```
dinitctl status bluetoothd
rfkill list bluetooth        # "Soft blocked: yes" -> rfkill unblock bluetooth
bluetoothctl show            # sebagai user umum
```

Catatan akun bersama: siapa pun yang memakai akun umum bisa pair perangkat.
Kalau tidak diinginkan, biarkan `"no"`.

## 4e. Wi-Fi untuk akun umum (`PUBLIC_NETWORK_CONTROL`)

Default polkit NetworkManager: akun umum boleh menyambung/memutus dan scan
Wi-Fi, tetapi **menyimpan koneksi baru** (`settings.modify.system`) butuh
autentikasi admin, dan aro tidak punya polkit agent → nmtui gagal dengan
"Insufficient privileges".

- `"yes"`: akun umum masuk grup `network`, dan
  `/etc/polkit-1/rules.d/50-networkmanager.rules` memberi izin **hanya** untuk
  action itu ke grup `network`. Berlaku setelah logout/login (grup baru).
- `"no"`: rule dihapus, akun umum keluar dari grup `network`. Admin menyiapkan
  koneksi Wi-Fi; akun umum hanya bisa menyambung/memutus koneksi tersimpan.

Cek (sebagai akun umum):

    nmcli general permissions | grep modify.system    # yes

## 4g. Bar atas

Patch aro `0008-bar-segments` + script `aro-bar`:

    1 2 3  CPU 12% 54°  RAM 9.4G  GPU 3% 41° 1.2G      21:45   Sun 11 Oct      Headset  ↓1.2M  wifi  ↑35K

- **Kiri**: pill workspace (klik = pindah), lalu segmen `sysmon`.
- **Tengah**: jam dan tanggal.
- **Kanan** (dari kanan): `net` (↓ kecepatan, nama koneksi, ↑ kecepatan; klik → nmtui),
  `bt` (nama perangkat tersambung = terang, `BT` = redup; klik → bluetui; hanya
  kalau `ENABLE_BLUETOOTH="yes"`).
- Segmen diatur di config aro: `bar_segment = top|bottom left|right <nama> [perintah]`;
  teksnya dibaca dari `$XDG_RUNTIME_DIR/aro-bar/<nama>` (terang seperti jam; awalan
  `~` = redup), jadi script lain bisa menambah segmen sendiri.
- Posisi dan ukuran: `bar_top = true`, `bar_height = 36`, `bar_font = Sans 12`
  (kunci dari patch 0008; `bar_font` default = `font_small`).
- GPU: NVIDIA lewat satu proses `nvidia-smi -lms`; AMD lewat sysfs. Interval
  `ARO_BAR_INTERVAL` (detik, default 2).
- **Bar bawah** (`bar_bottom = true`, butuh `bar_top = true`): di tengah pill
  workspace dan **semua jendela terbuka** (nama pendek: bagian terakhir app id, atau
  judul untuk game Proton). Jendela fokus tebal dan terang, lainnya redup. Klik
  nama = fokus ke jendela itu (pindah workspace kalau perlu); klik pill = pindah
  workspace. Segmen `bar_segment = bottom left|right ...` tampil di sini.
- **Urutan bar bawah**: daftar jendela di kiri, lalu pill workspace (patch 0008).
  `workspaces = 4` dan `workspace_names = 1 2 3 GAMES` (kunci patch 0008; `-` =
  pakai nomor). Workspace 4 = game Proton (rule profil daily).
- **Display** (paling kanan bawah): mode aktif `2560x1600@300`; lebih dari satu monitor
  → `DP-3 2560x1600@300  HDMI-A-1 1920x1080@60` (diperbarui tiap 10 detik, monitor
  yang baru dicolok ikut muncul). Klik → `monitor-mode menu`: pilih monitor dulu kalau
  lebih dari satu, lalu resolusi + refresh. Mode tersimpan per monitor
  (`~/.local/state/aro-monitor/<output>.mode`); `MONITOR_MODES` hanya untuk monitor
  utama.
- **MIC / SPK** (kiri bawah): `MIC 80%` dan `SPK 45% JBL Go 4` (redup kalau mute).
  Klik → `audio-menu`: pilih perangkat default (● = aktif; stream yang sedang jalan
  ikut pindah) atau Volume +5% / -5% / Mute. Ganti output tidak memindah mikrofon.
  Volume mikrofon: `Super+,` / `Super+.` (turun / naik, tanpa Fn). **Fn+mute** (Fn+I)
  me-mute speaker **dan** mikrofon sekaligus; tekan lagi untuk menyalakan keduanya.
  Speaker: Fn+Y / Fn+U, atau `Super+F10/F11/F12`.
  Nama perangkat di bar dipendekkan (akhiran `Analog Stereo` dsb. dibuang, dipotong di
  batas kata). Output yang tidak dipakai (mis. jack headphone di mikrofon USB)
  disembunyikan lewat `AUDIO_HIDE_OUTPUTS="Meteor"` di config mesin.
- **REC** dan **pengaturan rekam** (kanan bawah, di antara USB dan Display):
  `REC` redup saat diam, `● REC 01:23` terang saat merekam; klik = mulai/stop (sama
  dengan `Super+Shift+R`). Di sebelahnya `native MP4` / `1920x1200 MKV`; klik →
  pilih resolusi (hanya yang rasionya sama dengan monitor, jadi tidak gepeng) lalu
  format (mp4 / mkv). Tersimpan di `~/.config/casual-record.conf`, berlaku untuk
  rekaman berikutnya. Turun resolusi: NVIDIA/CPU lewat filter `scale`, AMD/Intel
  lewat `scale_vaapi`.
- **USB** (kanan bawah): `USB <label>` terang kalau ada perangkat yang dipasang
  udiskie di `/run/media/$USER`, `USB 2` kalau lebih dari satu, `USB` redup kalau
  kosong. Klik → `usb-open`: superfile langsung di perangkat itu (lebih dari satu:
  pilih lewat fuzzel).

## 4f. Tema hitam putih

Semua warna dari repo (ditimpa tiap `update.sh`):

| Aplikasi | File |
|---|---|
| aro (bingkai, aksen, notifikasi, latar) | `core/home/config/aro/overrides.conf` (blok tema di awal) |
| mako (notifikasi) | `core/home/config/mako/config` |
| fuzzel (launcher, Settings, menu) | `core/home/config/fuzzel/fuzzel.ini` |
| kitty (+ superfile, nmtui, bluetui) | `core/home/config/kitty/kitty.conf` (warna ANSI abu-abu) |
| zathura (PDF) | `core/home/config/zathura/zathurarc` (Ctrl+R = balik warna halaman) |
| GTK (Firefox, Mousepad, dialog file) | `core/home/config/gtk-{3,4}.0/settings.ini` (Adwaita gelap) |

Tidak ikut: aplikasi dengan tema sendiri (OnlyOffice, Steam, Sung, OBS) dan
isi halaman web.

## 4h. Log persisten (`LOG_PERSIST`)

Artix tidak punya journald: tanpa ini log boot sebelumnya hilang saat reboot. Dengan
`LOG_PERSIST="yes"` (default):

- **syslog-ng** menulis semua pesan (kernel + program) ke `/var/log/aro/<tanggal>.log`,
  satu baris per pesan dipisah TAB (`waktu level program pid pesan`), `fsync` tiap baris
  supaya baris terakhir sebelum hang tetap ada. Grup `log` (Admin masuk otomatis).
- Service dinit **aro-bootlog** menulis `boot <id>` saat boot dan `shutdown clean` saat
  dimatikan dengan benar; menyalin catatan crash kernel (pstore) ke
  `/var/log/aro/pstore/`; menghapus log lebih tua dari `LOG_KEEP_DAYS` (30).
- **`aro-lastboot`** (`aro-lastboot 2` = dua boot lalu): cara boot berakhir (bersih /
  berhenti mendadak / kernel panic), masalah penting (level 0-3, NVIDIA Xid, OOM, hung
  task, suhu, I/O error), dan 20 baris terakhir sebelum berhenti.
- Config syslog-ng asli disimpan sebagai `/etc/syslog-ng/syslog-ng.conf.orig`.
- **`whyd`** ([whyd-init](https://github.com/d3vzero/whyd-init), fork whyd dengan
  backend syslog; `WHYD="yes"`): daftar semua sesi beserta cara berakhirnya, masalah per
  sesi, dan laporan Markdown (`whyd report`). Dibangun dari commit `WHYD_REF` ke
  `/usr/local/bin/whyd`; naikkan `WHYD_REF` setelah ada commit baru di whyd-init, atau
  `UPDATE_WHYD=1` untuk build ulang. Butuh grup `log` (Admin) atau sudo.

## 4i. ble.sh (`BLESH`)

`BLESH="yes"` (default): ble.sh dibangun sekali dari source ke `/usr/local/share/blesh`
(tidak ada di repo resmi), dan `~/.bashrc` akun umum (dari `core/home/bashrc`, ditimpa
tiap update) memuatnya: saran otomatis dari riwayat (→ untuk menerima) dan warna
sintaks. Cache ble.sh di `~/.local/state/ble-cache` karena `~/.cache` tmpfs.
Build ulang ke versi terbaru: `sudo UPDATE_BLESH=1 update.sh`. Biaya: tiap shell
interaktif sekitar 15–30 MB lebih besar dan mulai sedikit lebih lambat.

## 4j. Mirror (`MIRROR_RANK`)

`aro-mirrors` mengukur mirror Artix (`world.db`) dan Arch (`extra.db`, hanya bagian
negara di `MIRROR_COUNTRIES`), lalu menaruh hingga 5 mirror **tercepat dan up to date**
di atas mirrorlist (daftar asli tetap di bawahnya; aslinya disimpan sebagai
`<file>.aro-orig`). Up to date = paket terbaru di daftar mirror itu tidak lebih tua
6 jam dari mirror tersegar **dan** file paketnya benar-benar ada (menolak mirror yang
daftarnya baru tapi filenya belum, penyebab error 404 saat unduh).

- `MIRROR_RANK="auto"` (default): `update.sh` hanya mengukur ulang kalau mirror pertama
  lebih lambat dari 1 MB/s atau gagal. `yes`: setiap update. `no`: tidak pernah.
- Manual: `sudo aro-mirrors` (ukur + tulis), `aro-mirrors --dry-run` (hanya lihat).

## 4k. Live wallpaper (`LIVEPAPER`)

`LIVEPAPER="yes"`: [qamariah-livepaper](https://github.com/d3vzero/qamariah-livepaper) --
langit hitam dengan matahari, bulan (fase sebenarnya), bintang dan planet pada posisi
nyata, cuaca live (Open-Meteo), dan laut bergelombang; garis putih tipis, >95% piksel
hitam, anti burn-in. Dipasang dari commit `LIVEPAPER_REF` ke `/usr/local`, dijalankan
lewat `exec = qamariah-livepaper` di config aro (layer background). Animasi berhenti
sendiri saat tertutup jendela (CPU ~0%); saat terlihat ~14% satu core di 2560x1600/12 FPS.
Config: `~/.config/qamariah-livepaper/config.ini` (dibuat sekali; `lat`/`lon` = lokasi
pengamat). Sisa nama lama `aro-livepaper` dibersihkan otomatis. `UPDATE_LIVEPAPER=1`
memasang ulang.

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
`UPDATE_PROTONGE` Proton-GE terbaru · `UPDATE_SUNG` build ulang Sung ·
`UPDATE_D2` build ulang venv Detectron2 (versi terbaru).

`update.sh` juga membuat ulang entry EFISTUB **kalau cmdline berubah**
(mis. `CPU`/`GPU`/`GPU_GEN` diganti); kalau sama, entry tidak disentuh.

Ganti profil: edit `PROFILES` di `/etc/dotfiles-aro.minimal.conf`, lalu jalankan
`update.sh`. (Profil yang dihapus tidak meng-uninstall paket.)

> Config di home `Assy` **di-copy dan ditimpa** tiap `update.sh` — repo
> adalah sumber kebenaran. Perubahan langsung di home `Assy` akan hilang;
> ubah di repo lalu jalankan `update.sh`.

### Driver NVIDIA ditahan otomatis

Arch (`extra`/`multilib`) biasanya merilis driver NVIDIA baru beberapa hari
sebelum Artix `world`. Selama jeda itu `lib32-nvidia-utils` (profil daily)
meminta `nvidia-utils` baru, sementara `nvidia-open-dkms` masih versi lama →
pacman menolak upgrade. `update.sh` dan menu `Super+U` mendeteksinya dan
**menahan seluruh paket driver** di versi terpasang untuk run itu (pesan
`driver NVIDIA ditahan`); driver naik bersama setelah Artix menyusul.
Tidak perlu `IgnorePkg` manual di `pacman.conf`.

## 5a. Menu update (Super+U) — untuk user umum

`Assy` bisa memperbarui sendiri tanpa sudo; bagian sistem meminta
**password Admin satu kali**.

| Status | Arti |
|---|---|
| ● | ada update |
| ✓ | sudah terbaru |
| – | tidak terpasang di mesin ini |
| ? | gagal cek (offline / batas API GitHub) |

Item: Sistem (pacman), YouTube-Sung (yt-dlp), OnlyOffice, superfile,
Sung, aro, Detectron2 (profil ai), dan *Cek-saja*. `Super+Ctrl+U` hanya mencakup Sistem, yt-dlp,
OnlyOffice, superfile — **Sung, aro, dan Detectron2 sengaja manual** lewat `Super+U`
karena dibuild dari commit terbaru upstream (di luar versi yang dikunci).

Komponen: `/usr/local/bin/office-update` (menu), `/usr/local/sbin/office-update-root`
(daftar putih: system | onlyoffice | superfile | aro | detectron2), dan
`/etc/sudoers.d/office-update` (Admin boleh menjalankan helper itu tanpa
sudo kedua; divalidasi `visudo` sebelum dipasang).

> Versi dari menu boleh lebih baru dari yang dikunci di config
> (`ARO_REF`, `SUNG_REV`, `SPF_VERSION`). `update.sh` biasa tidak
> menimpanya; `UPDATE_ARO=1` / `UPDATE_SUNG=1` mengembalikan ke versi
> terkunci.

Di workstation AI, memilih **Sistem** saat ada job `train-run` atau
proses compute GPU memunculkan peringatan + konfirmasi `[y/N]` (default
batal): update bisa memperbarui driver NVIDIA/CUDA dan membuat training crash.

Risiko: update Python sistem (minor naik) bisa merusak venv Sung —
`sung-yt check` melapor rusak; perbaiki dengan Super+U → Sung. Kalau
`wlroots0.20` diganti paket major baru, aro perlu dibuild ulang.

## 6. Catatan per profil

- **office** — OnlyOffice (AppImage resmi di `/opt/onlyoffice`, tidak
  lewat AUR), font kompatibel Office (`ttf-liberation ttf-carlito
  ttf-caladea`), zathura. Printer tidak dipasang: pakai *Export/Print to PDF*.
- **cad** — FreeCAD, KiCad (+library).
- **daily** — Steam, OBS, Proton-GE system-wide
  (`/usr/share/steam/compatibilitytools.d`), dan **Sung** (pemutar YouTube
  Music / file lokal / Navidrome). Mengaktifkan `[multilib]` + `[core]`
  Arch otomatis. DaVinci Resolve **tidak** termasuk (butuh AUR).
  - Sung di-build **per-user** di home `Assy` (`~/.local/bin/sung`, venv
    Python milik `Assy`), dikunci ke commit `SUNG_REV` yang sudah dites.
  - `sung-yt` mengecek YouTube 60 detik setelah login lalu tiap 6 jam,
    dan memberi notifikasi **hanya saat status berubah** (rusak / pulih).
    Kalau rusak: `Super+U` → YouTube-Sung (update yt-dlp + rollback
    otomatis kalau tetap gagal). `Assy` bisa melakukannya sendiri tanpa sudo.
  - `UPDATE_SUNG=1` atau mengganti `SUNG_REV` mengembalikan yt-dlp ke versi
    terkunci; script langsung menjalankan `sung-yt update` sesudahnya.
  - Aplikasi dari fuzzel "diam" tanpa jendela: jalankan dari kitty
    untuk melihat error, lalu cek `command -v <app>` dan baris `Exec=`
    di file `.desktop`-nya. Peringatan `qt.qpa.services ... App info not
    found for 'sung'` dan `qt.qml.propertyCache` saat Sung start aman
    diabaikan.
- **ai** — Detectron2 untuk **training**, lihat bagian 6a.

## 6b. OBS (profil daily)

- Rekam/stream layar lewat **Screen Capture (PipeWire)** → menu fuzzel "Share ❯".
  Butuh `~/.config/xdg-desktop-portal/aro-portals.conf` (dipasang otomatis):
  `XDG_CURRENT_DESKTOP=aro` tidak dikenal `xdg-desktop-portal-wlr`.
- **Rekam per jendela belum berfungsi di aro 0.4** (kosong / `buffer constraint
  mismatch`); pakai monitor (`DP-3`) lalu crop di *Edit Transform*. Game windowed
  yang lebih kecil dari layar ada di tengah: crop atas/bawah = (1600 − tinggi)/2,
  kiri/kanan = (2560 − lebar)/2 (2560x1440 → atas/bawah 80).
- Config awal dari `profiles/daily/obs-studio/` (salinan dari Sway, path
  `@HOME@`), dipasang hanya kalau OBS belum pernah dikonfigurasi
  (`UPDATE_OBS=1` untuk menimpa). Password websocket & stream key tidak ikut.
- `Super+Alt+S`: `split-obs-record` memecah `~/Videos/OBS/RAW/RecordRAW.mkv`
  (track 1 campuran, 2 desktop, 3 mic) ke `~/Videos/OBS/Split/{All,Screen,Audio,Mic}`.

## 6a0. Profil ai: dua bagian (`AI_PARTS`)

Profil `ai` punya dua bagian yang dipilih di config mesin, masing-masing dengan file
config sendiri di `/etc/dotfiles-aro.minimal.d/` (dibuat sekali dari template di
`profiles/ai/`, tidak ditimpa `update.sh`):

| `AI_PARTS` | Isi | Config |
|---|---|---|
| `trainer` | train-run + Detectron2 (bagian 6a) | `ai-trainer.conf` (`AI_BACKEND`, `TORCH_CUDA_ARCH`, `D2_REV`, `TORCH_INDEX`; saat dibuat diisi dari nilai lama di config mesin) |
| `llm` | llama.cpp (CUDA) + `llm` + OpenCode + `gh` | `ai-llm.conf` (`LLAMA_REF`, `LLAMA_CUDA_ARCH`, `OPENCODE_VERSION`, `LLM_VRAM_MB`, `LLM_CTX`, `LLM_PORT`, `LLM_MODEL`) |

`AI_PARTS="trainer llm"` memasang keduanya. Bagian **llm**:

- llama.cpp dibangun dari `LLAMA_REF` ke `/usr/local/bin/llama-server` (+ `llama-cli`,
  `llama-bench`); dilewati kalau sudah sama (`UPDATE_LLAMA=1` memaksa).
- **Model diunduh manual** ke `~/models` (file `.gguf`), mis. Qwen3.6-35B-A3B Q4.
- `llm start [model]` / `llm stop` / `llm status` / `llm models` / `llm log`. Server di
  `127.0.0.1:LLM_PORT` (API OpenAI). `--fit` mengisi GPU sampai `LLM_VRAM_MB` (default
  14000), sisanya (expert MoE) di RAM; KV cache q8_0; `--jinja` untuk tool calling.
- **Tidak bersamaan dengan training**: `llm start` menolak saat ada job `train-run`, dan
  `train-run start` menolak saat LLM berjalan (`TRAIN_FORCE=1` untuk memaksa).
- Segmen bar bawah **LLM** (kiri, setelah SPK): redup = mati, terang = nama model; klik =
  start/stop.
- **OpenCode** (`opencode`): agent coding di terminal, config
  `~/.config/opencode/opencode.json` dari `profiles/ai/opencode.json` (ditimpa tiap
  update) -- model `llama.cpp/local`, minta izin sebelum mengedit file, menjalankan
  perintah, atau membuka web.
- **Claude Code + `qwen-task`** (`CLAUDE_CODE="yes"` di `ai-llm.conf`): Claude Code dipasang
  per-user dengan installer resmi (`~/.local/bin/claude`, kanal stable, update otomatis);
  login sekali dengan `claude`. `~/.claude/CLAUDE.md` (alur: Claude merencanakan dan
  memeriksa, model lokal menulis kode) dan `~/.claude/settings.json` (izin: `qwen-task`,
  `git status/diff/log`, test; larangan: `gh pr merge`, push ke main, `sudo`) dipasang
  sekali dari `profiles/ai/claude/`, lalu milik user. `qwen-task [-b BRANCH] "TUGAS"`:
  OpenCode tanpa interaksi dengan model lokal (boleh edit dan menjalankan perintah;
  dilarang commit/push/ganti branch/gh/sudo/unduh), menolak bekerja di main, mulai dari
  working tree bersih, hasil dibiarkan belum di-commit untuk diperiksa, log di
  `.git/qwen-task/`.
- **GitHub**: `gh auth login` di akun umum dengan *fine-grained token* (hanya repo yang
  dikerjakan agent, Contents + Pull requests, ada masa berlaku); kerja di branch, gabung
  lewat pull request; aktifkan branch protection di `main`.

## 6a. Profil ai: Detectron2 + train-run

Hanya untuk **GPU NVIDIA** (`AI_BACKEND=auto` → cuda). Di mesin lain
Detectron2 dilewati; `train-run` tetap terpasang.

Semua versi **terbaru** (bukan meniru mesin Ubuntu lama), dibangun oleh
`profiles/ai/install-detectron2.sh` (root):

```
sudo /opt/dotfiles-aro.minimal/profiles/ai/install-detectron2.sh verify     # setelah boot: NMS + ROIAlign di GPU
sudo /opt/dotfiles-aro.minimal/profiles/ai/install-detectron2.sh rebuild    # versi terbaru; gagal -> venv lama kembali
sudo /opt/dotfiles-aro.minimal/profiles/ai/install-detectron2.sh rollback   # kembali ke venv sebelumnya
```
`rebuild` juga tersedia di menu **Super+U → Detectron2** (password Admin;
tidak ikut "update semua"; peringatan kalau training sedang berjalan).

Yang ditangani script:
- Index PyTorch dipilih dari versi `nvcc`: major CUDA sama, minor ≤ sistem.
  CUDA < 12.8 ditolak (Blackwell butuh ≥ 12.8).
- Python dicoba dari yang terbaru (`3.13`, lalu `3.12`); dipakai yang sudah
  punya wheel torch. Interpreter `uv` di `/opt/detectron2/python` (bukan
  `/root`), cache `uv` di `/tmp`.
- Host compiler dari `/etc/profile.d/cuda.sh` (`NVCC_CCBIN` → `-ccbin`),
  karena GCC terbaru Artix terlalu baru untuk nvcc.
- Wajib: torch berisi kernel `sm_120` (dicek tanpa GPU, jadi aman di chroot).
  `tkinter` dicek sebagai peringatan (SH Trainer mungkin GUI Tk).
- Versi + commit tercatat di `/opt/detectron2/VERSIONS`.

Opsi di config: `TORCH_CUDA_ARCH` (5060 & 5080 = `12.0`), `D2_REV` (kosong =
terbaru; isi untuk mengunci). Requirements SH Trainer: taruh
`profiles/ai/shtrainer-requirements.txt` (dari `pip freeze` mesin lama,
**tanpa** torch/torchvision/detectron2) — otomatis dipakai.

**Lokasi:** venv `/opt/detectron2/venv` (milik root, read-only untuk user
umum). Dataset, output, checkpoint di home user umum: `~/training/<job>/`.

**Uji inference nyata** (bobot model diunduh sekali ke `~/.torch/iopath_cache`):
```
mkdir -p ~/uji/gambar      # isi beberapa .jpg/.png
/opt/detectron2/venv/bin/python /opt/dotfiles-aro.minimal/tools/d2-infer-load.py ~/uji/gambar 3
```

**Validasi akhir sebelum produksi:** training SH Trainer di Artix
menghasilkan AP50 setara mesin Ubuntu (BBox/Segm ~65–70 pada dataset yang
sama). Mesin Ubuntu tetap produksi sampai hasilnya setara. Cek juga path
hardcode `/home/aiserver/...` di source SH Trainer.

**Menjalankan training** — selalu lewat `train-run`, supaya menutup kitty
tidak menghentikan job:
```
train-run start mask-v1 /opt/detectron2/venv/bin/python train_net.py --config-file cfg.yaml --resume
train-run status          # job yang berjalan / selesai
train-run log mask-v1     # ikuti log (Ctrl+C hanya berhenti melihat)
train-run stop mask-v1    # TERM, lalu KILL setelah 30 detik
```
Notifikasi muncul saat job selesai atau gagal. `Ctrl+Alt+Del` dan menu
update memberi peringatan selama job berjalan.

**Config training:** RTX 5060 VRAM jauh lebih kecil dari 5080 → config per
mesin, batch kecil, `SOLVER.AMP.ENABLED: True`. Checkpoint berkala
(`SOLVER.CHECKPOINT_PERIOD`) + `--resume` supaya reboot tidak menghapus progres.

## 7. Kalau BIOS "lupa" entry boot

Beberapa BIOS menghapus entry EFISTUB setelah update firmware. Boot lagi
ISO, mount seperti langkah 1, `artix-chroot /mnt`, lalu:
```
efibootmgr        # cek entry "Artix" masih ada atau tidak
bash /opt/dotfiles-aro.minimal/bootstrap/install-chroot.sh
```
Bootstrap aman diulang: entry lama berlabel sama dihapus lalu dibuat ulang.
Cadangan jangka panjang: bootloader `limine` (repo resmi).
