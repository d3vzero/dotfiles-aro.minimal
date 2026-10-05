#!/bin/bash
# update.sh -- terapkan ulang dotfiles-aro.minimal di sistem yang sudah jalan.
# Dijalankan ADMIN_USER: sudo /opt/dotfiles-aro.minimal/update.sh
# Aman diulang (idempotent). Opsi lewat env:
#   UPDATE_ARO=1         rebuild aro dari source
#   UPDATE_ONLYOFFICE=1  download ulang OnlyOffice AppImage (profil office)
#   UPDATE_PROTONGE=1    download Proton-GE terbaru (profil daily)
#   UPDATE_SUNG=1        build ulang Sung dari SUNG_REV (profil daily)
#   UPDATE_D2=1          build ulang venv Detectron2 (profil ai)
# Contoh: sudo UPDATE_ARO=1 UPDATE_ONLYOFFICE=1 /opt/dotfiles-aro.minimal/update.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF=/etc/dotfiles-aro.minimal.conf
# shellcheck source=lib/apply.sh
. "$REPO_DIR/lib/apply.sh"

require_root
load_conf "$CONF"

step "[1/8] Cek hardware vs config";    validate_hw
step "[2/8] Repo Arch + full upgrade";   enable_repos
step "[3/8] Paket (core + $PROFILES)";   install_packages
step "[4/8] aro + superfile";            build_aro; install_superfile
step "[5/8] File sistem + service";      install_system_files; enable_services
step "[6/8] Setup profil";               run_profile_hooks
step "[7/8] Home $PUBLIC_USER";          setup_public_home
step "[8/8] EFISTUB (cmdline dari CPU/GPU)"; setup_efistub

echo
echo "==> SELESAI. $PUBLIC_USER perlu logout/login ulang (atau reboot) supaya config aro baru terbaca."
