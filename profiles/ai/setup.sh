#!/bin/bash
# profil ai: train-run + venv Detectron2 bersama di /opt/detectron2 (root,
# read-only untuk user umum). Build lewat install-detectron2.sh (versi
# terbaru, Blackwell sm_120). Dataset/output/checkpoint: ~/training/<job>/.
set -euo pipefail
install -m755 "$PDIR/bin/train-run" /usr/local/bin/train-run
install -d -o "$PUBLIC_USER" -g "$PUBLIC_USER" "$PUBLIC_HOME/training"

if [ "$AI_BACKEND_RESOLVED" != cuda ]; then
    echo "    !! Detectron2 di repo ini hanya untuk GPU NVIDIA (CUDA) -- dilewati."
    echo "       (train-run tetap terpasang)"
    exit 0
fi

pacman -S --needed --noconfirm cuda

if [ -x /opt/detectron2/venv/bin/python ] && [ "${UPDATE_D2:-0}" != "1" ]; then
    echo "    Detectron2 sudah ada -- skip. Update: Super+U -> Detectron2, atau UPDATE_D2=1"
    sed 's/^/    /' /opt/detectron2/VERSIONS 2>/dev/null || true
    exit 0
fi

REQ="$PDIR/shtrainer-requirements.txt"
env TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH:-12.0}" D2_REV="${D2_REV:-}" \
    D2_EXTRA_REQ="$( [ -f "$REQ" ] && echo "$REQ" || true )" \
    bash "$PDIR/install-detectron2.sh" install
# cache uv: di chroot /tmp masih di disk (tmpfs baru aktif setelah reboot)
rm -rf /tmp/uv-cache
echo "    Setelah boot dengan driver NVIDIA aktif: sudo $PDIR/install-detectron2.sh verify"
