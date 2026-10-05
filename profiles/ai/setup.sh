#!/bin/bash
# profil ai: venv Detectron2 bersama di /opt/detectron2 (root, read-only untuk
# user umum) + train-run. Dataset/output/checkpoint: ~/training/<job>/ milik
# PUBLIC_USER. Backend dari config: cuda (NVIDIA new) atau cpu.
set -euo pipefail
D=/opt/detectron2
VENV="$D/venv"
B="$AI_BACKEND_RESOLVED"

install -m755 "$PDIR/bin/train-run" /usr/local/bin/train-run
install -d -o "$PUBLIC_USER" -g "$PUBLIC_USER" "$PUBLIC_HOME/training"

if [ "$B" = cuda ]; then
    pacman -S --needed --noconfirm cuda
    # PATH ke /opt/cuda/bin + NVCC_CCBIN (versi GCC yang cocok untuk CUDA)
    # shellcheck disable=SC1091
    set +u; . /etc/profile.d/cuda.sh; set -u
fi

# --- index wheel PyTorch ---
IDX="${TORCH_INDEX:-}"
if [ -z "$IDX" ]; then
    if [ "$B" = cuda ]; then
        read -r MAJ MIN < <(nvcc --version | sed -n 's/.*release \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
        # torch harus sama MAJOR CUDA-nya dengan nvcc sistem (kalau beda, build D2 gagal)
        if [ "$MAJ" = 13 ]; then IDX=https://download.pytorch.org/whl/cu130
        elif [ "$MAJ" = 12 ] && [ "$MIN" -ge 8 ]; then IDX="https://download.pytorch.org/whl/cu12$MIN"
        else echo "!! CUDA $MAJ.$MIN tidak didukung (Blackwell butuh >= 12.8). Isi TORCH_INDEX manual."; exit 1
        fi
    else
        IDX=https://download.pytorch.org/whl/cpu
    fi
fi

WANT="backend=$B index=$IDX d2=${D2_REV:-main} arch=${TORCH_CUDA_ARCH:-}"
if [ -x "$VENV/bin/python" ] && [ "$(cat "$D/.installed" 2>/dev/null)" = "$WANT" ] \
   && [ "${UPDATE_D2:-0}" != "1" ]; then
    echo "    Detectron2 sudah ada ($WANT) -- skip (UPDATE_D2=1 untuk build ulang)"
    exit 0
fi

echo "    Build venv Detectron2: $WANT"
mkdir -p "$D"
# Python dari uv WAJIB disimpan di /opt: default-nya di /root (700), venv
# jadi tidak bisa dibaca user umum.
export UV_PYTHON_INSTALL_DIR="$D/python" UV_CACHE_DIR="$D/.uv-cache"
rm -rf "$VENV"
uv venv --python 3.12 "$VENV"
PY="$VENV/bin/python"
uv pip install --python "$PY" torch torchvision --index-url "$IDX"
uv pip install --python "$PY" opencv-python-headless tensorboard setuptools wheel ninja

D2_URL="git+https://github.com/facebookresearch/detectron2.git${D2_REV:+@$D2_REV}"
if [ "$B" = cuda ]; then
    # FORCE_CUDA: build op CUDA walau GPU tidak terlihat (mis. di chroot).
    # Satu arch untuk 5060 & 5080 (sama-sama sm_120).
    env TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH:-12.0}" FORCE_CUDA=1 CUDA_HOME=/opt/cuda \
        ${NVCC_CCBIN:+CUDAHOSTCXX="$NVCC_CCBIN"} \
        uv pip install --python "$PY" --no-build-isolation "$D2_URL"
else
    uv pip install --python "$PY" --no-build-isolation "$D2_URL"
fi

echo "    Verifikasi:"
"$PY" - <<'PYEOF' || true
import torch
print("    torch", torch.__version__, "| CUDA torch:", torch.version.cuda,
      "| GPU terlihat:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("    GPU:", torch.cuda.get_device_name(0), "capability", torch.cuda.get_device_capability(0))
import detectron2
print("    detectron2", detectron2.__version__)
PYEOF
echo "    (di chroot GPU belum terlihat -- normal. Cek ulang setelah boot: lihat docs bagian AI)"

rm -rf "$D/.uv-cache"
chmod -R a+rX "$D"
echo "$WANT" > "$D/.installed"
