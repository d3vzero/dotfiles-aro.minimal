#!/bin/bash
# install-detectron2.sh — venv Detectron2 versi TERBARU untuk RTX 50xx (Blackwell, sm_120)
#
#   install-detectron2.sh install   build venv baru (bisa di chroot, GPU tidak wajib)
#   install-detectron2.sh rebuild   sama dengan install; venv lama disimpan sebagai venv.old
#                                   (dikembalikan otomatis kalau build gagal)
#   install-detectron2.sh verify    tes torch + op CUDA Detectron2 di GPU (setelah boot)
#   install-detectron2.sh rollback  kembalikan venv.old
#
# Dijalankan sebagai root. Hasil: /opt/detectron2/{venv,python,src,VERSIONS}
# Butuh paket: base-devel git cmake ninja uv cuda curl
#
# Opsi lewat env:
#   D2_PREFIX=/opt/detectron2         lokasi instalasi
#   D2_PYTHONS="3.13 3.12"            versi Python yang dicoba berurutan (terbaru dulu)
#   D2_REV=<commit>                   kunci commit Detectron2 (default: HEAD main terbaru)
#   D2_EXTRA_REQ=/path/req.txt        requirements tambahan (mis. SH Trainer)
#   TORCH_CUDA_ARCH_LIST=12.0         arsitektur GPU (5060 & 5080 = 12.0)
set -euo pipefail

PREFIX=${D2_PREFIX:-/opt/detectron2}
VENV="$PREFIX/venv"
PY_CANDIDATES=${D2_PYTHONS:-"3.13 3.12"}
D2_REPO=https://github.com/facebookresearch/detectron2.git
D2_REV=${D2_REV:-}
EXTRA_REQ=${D2_EXTRA_REQ:-}
export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-12.0}

# interpreter Python milik uv disimpan di /opt (bukan /root) supaya bisa dipakai semua user;
# cache uv di /tmp (tmpfs) supaya unduhan/build tidak menulis ke NVMe
export UV_PYTHON_INSTALL_DIR="$PREFIX/python"
export UV_CACHE_DIR=${UV_CACHE_DIR:-/tmp/uv-cache}
export UV_LINK_MODE=copy

die()  { echo "!! $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

BUILDING=0
restore_on_fail() {
    if [ "$BUILDING" = 1 ]; then
        echo "!! build gagal — venv lama dikembalikan" >&2
        rm -rf "$VENV"
        [ -d "$VENV.old" ] && mv "$VENV.old" "$VENV"
    fi
}

cuda_env() {
    # paket cuda Arch menyediakan PATH dan NVCC_CCBIN (versi GCC yang didukung nvcc)
    # shellcheck disable=SC1091
    # set +u: cuda.sh bisa memakai variabel yang belum di-set
    if [ -f /etc/profile.d/cuda.sh ]; then set +u; . /etc/profile.d/cuda.sh; set -u; fi
    export CUDA_HOME=${CUDA_HOME:-/opt/cuda}
    export PATH="$CUDA_HOME/bin:$PATH"
    command -v nvcc >/dev/null || die "nvcc tidak ditemukan (pasang paket cuda)"
    if [ -n "${NVCC_CCBIN:-}" ]; then
        export NVCC_PREPEND_FLAGS="-ccbin $NVCC_CCBIN ${NVCC_PREPEND_FLAGS:-}"
    fi
    read -r CMAJ CMIN < <(nvcc --version | sed -n 's/.*release \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
    [ -n "${CMAJ:-}" ] || die "gagal membaca versi nvcc"
    if [ "$CMAJ" -lt 12 ] || { [ "$CMAJ" -eq 12 ] && [ "$CMIN" -lt 8 ]; }; then
        die "CUDA $CMAJ.$CMIN terlalu lama untuk Blackwell (butuh >= 12.8)"
    fi
}

torch_index() {
    # cari index PyTorch dengan major CUDA sama, minor <= nvcc sistem (mis. 13.0 → cu130)
    local m tag
    for m in $(seq "$CMIN" -1 0); do
        tag="cu${CMAJ}${m}"
        [ "$CMAJ" -eq 12 ] && [ "$m" -lt 8 ] && break
        if curl -fsI --max-time 15 "https://download.pytorch.org/whl/$tag/torch/" >/dev/null; then
            echo "https://download.pytorch.org/whl/$tag"; return 0
        fi
    done
    return 1
}

cmd_install() {
    [ "$(id -u)" = 0 ] || die "jalankan sebagai root"
    for c in uv git curl g++; do command -v "$c" >/dev/null || die "$c tidak ditemukan"; done
    cuda_env
    echo "CUDA sistem : $CMAJ.$CMIN   host compiler: ${NVCC_CCBIN:-default}"
    echo "Arsitektur  : $TORCH_CUDA_ARCH_LIST"

    local idx; idx=$(torch_index) || die "tidak ada wheel PyTorch untuk CUDA $CMAJ.x di download.pytorch.org"
    echo "Index torch : $idx"

    mkdir -p "$PREFIX" "$UV_CACHE_DIR"
    # venv lama disingkirkan dulu; dikembalikan otomatis kalau build gagal
    if [ -d "$VENV" ]; then rm -rf "$VENV.old"; mv "$VENV" "$VENV.old"; fi
    BUILDING=1; trap restore_on_fail EXIT
    local new="$VENV" py ok=""
    for py in $PY_CANDIDATES; do
        step "Venv Python $py"
        rm -rf "$new"
        uv venv -q --python "$py" "$new" || continue
        if uv pip install -q --python "$new/bin/python" torch torchvision --index-url "$idx"; then
            ok=$py; break
        fi
        echo "   torch belum tersedia untuk Python $py, coba versi berikutnya"
    done
    [ -n "$ok" ] || die "tidak ada kombinasi Python/torch yang berhasil"
    local P="$new/bin/python"

    step "Dependensi build & runtime"
    uv pip install -q --python "$P" setuptools wheel ninja \
        opencv-python-headless tensorboard pycocotools

    step "Source Detectron2"
    if [ -d "$PREFIX/src/.git" ]; then
        git -C "$PREFIX/src" fetch -q origin
    else
        git clone -q "$D2_REPO" "$PREFIX/src"
    fi
    git -C "$PREFIX/src" checkout -q "${D2_REV:-origin/main}"
    local rev; rev=$(git -C "$PREFIX/src" rev-parse HEAD)
    echo "Commit      : $rev"

    step "Build Detectron2 (beberapa menit)"
    rm -rf "$PREFIX/src/build"
    FORCE_CUDA=1 MAX_JOBS=${MAX_JOBS:-$(nproc)} \
        uv pip install --python "$P" --no-build-isolation "$PREFIX/src"

    if [ -n "$EXTRA_REQ" ]; then
        step "Requirements tambahan: $EXTRA_REQ"
        uv pip install --python "$P" -r "$EXTRA_REQ"
    fi

    step "Cek import (tanpa GPU)"
    "$P" - <<'EOF'
import torch, detectron2
from detectron2 import _C
print("torch", torch.__version__, "cuda", torch.version.cuda, "| detectron2", detectron2.__version__)
try:
    import tkinter; print("tkinter OK")
except Exception as e:
    print("PERINGATAN: tkinter tidak tersedia:", e)
# get_arch_list() mengembalikan [] kalau GPU tidak terlihat (mis. di chroot),
# jadi baca daftar arch yang dikompilasi langsung -- tidak butuh GPU.
arch = torch._C._cuda_getArchFlags().split()
print("arch torch:", " ".join(arch))
assert any(a.startswith("sm_120") for a in arch), "torch ini tidak berisi kernel sm_120 (Blackwell)"
EOF

    BUILDING=0; trap - EXIT

    "$VENV/bin/python" - > "$PREFIX/VERSIONS" <<EOF
import sys, torch, detectron2
print("tanggal      : $(date '+%F %T')")
print("python       :", sys.version.split()[0])
print("torch        :", torch.__version__, "(cuda", torch.version.cuda + ")")
print("index        : $idx")
print("cuda sistem  : $CMAJ.$CMIN")
print("detectron2   :", detectron2.__version__, "commit $rev")
print("arch         : $TORCH_CUDA_ARCH_LIST")
EOF
    chmod -R a+rX "$PREFIX"
    step "Selesai"; cat "$PREFIX/VERSIONS"
    echo
    echo "Setelah boot dengan driver NVIDIA aktif, jalankan: $0 verify"
}

cmd_verify() {
    [ -x "$VENV/bin/python" ] || die "venv belum ada"
    "$VENV/bin/python" - <<'EOF'
import torch
assert torch.cuda.is_available(), "CUDA tidak tersedia (driver NVIDIA aktif?)"
n = torch.cuda.get_device_name(0); cap = torch.cuda.get_device_capability(0)
print("GPU:", n, "capability", cap)
from detectron2.layers import nms, ROIAlign
b = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11], [50, 50, 60, 60]], dtype=torch.float, device="cuda")
s = torch.tensor([0.9, 0.8, 0.7], device="cuda")
keep = nms(b, s, 0.5); print("nms (CUDA):", keep.tolist())
ra = ROIAlign((7, 7), 1.0, 0, aligned=True)
y = ra(torch.rand(1, 3, 32, 32, device="cuda"),
       torch.tensor([[0, 0, 0, 16, 16]], dtype=torch.float, device="cuda"))
print("ROIAlign (CUDA):", tuple(y.shape))
print("VERIFY OK")
EOF
    "$VENV/bin/python" -m detectron2.utils.collect_env | grep -E "Python|PyTorch|CUDA|GPU|detectron2|Detectron2" || true
}

cmd_rollback() {
    [ -d "$VENV.old" ] || die "tidak ada venv.old"
    rm -rf "$VENV.broken"; mv "$VENV" "$VENV.broken"; mv "$VENV.old" "$VENV"
    echo "venv dikembalikan ke versi sebelumnya (yang gagal disimpan di venv.broken)"
}

case "${1:-}" in
    install|rebuild) cmd_install ;;
    verify)          cmd_verify ;;
    rollback)        cmd_rollback ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
