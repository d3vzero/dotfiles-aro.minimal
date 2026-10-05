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
- aro di NVIDIA **belum diuji** — jalankan stress test dulu (`tools/`).
  Kalau ada glitch tampilan, coba tambahkan `export WLR_RENDERER=vulkan`.
- `GPU=vm`: tanpa microcode, plus `WLR_NO_HARDWARE_CURSORS=1` dan core dump
  aktif di `.bash_profile`.

## 4. Keybind tambahan

Semua bind default aro tetap ada (lihat `/usr/share/doc/aro/config.example`).
Tambahan dari repo ini:

| Tombol | Fungsi |
|---|---|
| `Ctrl+Alt+Del` | Menu Shutdown / Reboot (opsi pertama **Batal** + peringatan kalau training/GPU berjalan) |
| `Super+e` | File manager (superfile) |
| `Super+n` | Atur jaringan (nmtui) |
| `Super+Shift+c` | Cheatsheet keybind aro + superfile (dibaca dari config aktif) |
| `Super+u` | Menu update: pilih satu item (lihat bagian 5a) |
| `Super+Ctrl+u` | Update semua yang ada update-nya (konfirmasi, default **Batal**) |

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
`UPDATE_D2` build ulang venv Detectron2.

`update.sh` juga membuat ulang entry EFISTUB **kalau cmdline berubah**
(mis. `CPU`/`GPU`/`GPU_GEN` diganti); kalau sama, entry tidak disentuh.

Ganti profil: edit `PROFILES` di `/etc/dotfiles-aro.minimal.conf`, lalu jalankan
`update.sh`. (Profil yang dihapus tidak meng-uninstall paket.)

> Config di home `Assy` **di-copy dan ditimpa** tiap `update.sh` — repo
> adalah sumber kebenaran. Perubahan langsung di home `Assy` akan hilang;
> ubah di repo lalu jalankan `update.sh`.

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
Sung, aro, dan *Cek-saja*. `Super+Ctrl+U` hanya mencakup Sistem, yt-dlp,
OnlyOffice, superfile — **Sung dan aro sengaja manual** lewat `Super+U`
karena dibuild dari commit terbaru upstream (di luar versi yang dikunci).

Komponen: `/usr/local/bin/office-update` (menu), `/usr/local/sbin/office-update-root`
(daftar putih: system | onlyoffice | superfile | aro), dan
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

## 6a. Profil ai: Detectron2 + train-run

**Backend** (`AI_BACKEND=auto`): `GPU=nvidia` → **cuda**, selain itu →
**cpu** (ROCm belum didukung skrip ini). Paket `cuda` (beberapa GB) hanya dipasang untuk cuda.

**Lokasi:** venv bersama `/opt/detectron2/venv` (milik root, read-only untuk
user umum; Python 3.12 lewat `uv`). Dataset, output, checkpoint di home user
umum: `~/training/<nama-job>/`.

**Versi:** index wheel PyTorch dipilih dari versi `nvcc` (CUDA 13 → `cu130`,
12.8/12.9 → `cu128`/`cu129`) — major CUDA torch **harus sama** dengan nvcc
sistem. Bisa dipaksa lewat `TORCH_INDEX`. Arch build `TORCH_CUDA_ARCH="12.0"`
(RTX 5060 & 5080 sama-sama `sm_120`). Detectron2 dikunci lewat `D2_REV`
setelah lolos uji. Setiap torch di-upgrade → `UPDATE_D2=1`.

**Cek setelah boot pertama** (di chroot GPU belum terlihat):
```
/opt/detectron2/venv/bin/python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))"
/opt/detectron2/venv/bin/python -m detectron2.utils.collect_env
```
Harus: capability `(12, 0)` dan major CUDA sama di `collect_env`. Lalu uji
inference nyata supaya op CUDA Detectron2 (ROIAlign, NMS) terbukti jalan
di GPU (bobot model diunduh sekali ke `~/.torch/iopath_cache`):
```
mkdir -p ~/uji/gambar      # isi beberapa .jpg/.png
/opt/detectron2/venv/bin/python /opt/dotfiles-aro.minimal/tools/d2-infer-load.py ~/uji/gambar 3
```

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
