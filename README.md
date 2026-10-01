# dotfiles-aro.minimal

Artix **dinit** + window manager **aro** untuk PC **full AMD** (CPU + GPU),
minimal, tanpa AUR. Dari disk kosong sampai desktop jadi dalam 1 repo.

**Panduan lengkap: [`docs/INSTALL.md`](docs/INSTALL.md)**

## Isi

- `machine.conf` — template setting per mesin (copy ke `/etc/dotfiles-aro.minimal.conf`)
- `bootstrap/install-chroot.sh` — instalasi penuh, sekali, di dalam chroot
- `update.sh` — terapkan ulang di sistem yang jalan (`sudo`)
- `lib/apply.sh` — fungsi bersama kedua script
- `core/` — paket, script, dan template home user umum
- `profiles/daily/` — Steam, OBS, Proton-GE
- `profiles/work/` — FreeCAD, KiCad, OnlyOffice
- `profiles/ai/` — llama.cpp (Vulkan)
- `tools/` — alat uji (stress test aro)

## Ringkas

    artix-chroot /mnt
    git clone https://github.com/d3vzero/dotfiles-aro.minimal /opt/dotfiles-aro.minimal
    cp /opt/dotfiles-aro.minimal/machine.conf /etc/dotfiles-aro.minimal.conf && nvim /etc/dotfiles-aro.minimal.conf
    bash /opt/dotfiles-aro.minimal/bootstrap/install-chroot.sh

Update (sebagai Admin):

    sudo git -C /opt/dotfiles-aro.minimal pull && sudo /opt/dotfiles-aro.minimal/update.sh
