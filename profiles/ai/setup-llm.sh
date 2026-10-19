#!/bin/bash
# profil ai, bagian llm: llama.cpp (CUDA, dibangun dari LLAMA_REF), perintah llm
# (start/stop/status, model sebagian di VRAM dan expert MoE di RAM), OpenCode
# (agent coding di terminal, memakai llama-server lokal) dan gh (GitHub CLI).
# Pengaturan: $CONF_D/ai-llm.conf. Model .gguf diunduh manual ke ~/models.
set -euo pipefail
# shellcheck disable=SC1091
. "$CONF_D/ai-llm.conf"
PUB="$PUBLIC_USER"; H="$PUBLIC_HOME"

install -m755 "$PDIR/bin/llm" /usr/local/bin/llm
install -d -o "$PUB" -g "$PUB" "$H/models"

if [ "$GPU" != nvidia ]; then
    echo "    !! bagian llm di repo ini dibangun untuk GPU NVIDIA (CUDA) -- llama.cpp dilewati"
    exit 0
fi
pacman -S --needed --noconfirm cuda nodejs npm github-cli

# --- llama.cpp ---------------------------------------------------------------
stamp=/usr/local/share/llama.cpp.ref
if [ -x /usr/local/bin/llama-server ] && [ "$(cat "$stamp" 2>/dev/null)" = "$LLAMA_REF" ] && [ "${UPDATE_LLAMA:-0}" != 1 ]; then
    echo "    llama.cpp $LLAMA_REF sudah ada -- skip (UPDATE_LLAMA=1 untuk build ulang)"
else
    src=/opt/llama.cpp-src
    [ -d "$src/.git" ] || { rm -rf "$src"; git clone --quiet https://github.com/ggml-org/llama.cpp "$src"; }
    git -C "$src" fetch --quiet --tags origin
    git -C "$src" checkout --quiet --force "$LLAMA_REF"
    # nvcc + GCC yang didukungnya dari paket cuda (sama seperti build Detectron2)
    if [ -f /etc/profile.d/cuda.sh ]; then
        append_path() { case ":$PATH:" in *":$1:"*) ;; *) PATH="${PATH:+$PATH:}$1" ;; esac; }
        set +u; . /etc/profile.d/cuda.sh; set -u
        unset -f append_path
    fi
    export CUDA_HOME="${CUDA_HOME:-/opt/cuda}" PATH="${CUDA_HOME:-/opt/cuda}/bin:$PATH"
    host=(); [ -n "${NVCC_CCBIN:-}" ] && host=(-DCMAKE_CUDA_HOST_COMPILER="$NVCC_CCBIN")
    rm -rf "$src/build"
    if cmake -S "$src" -B "$src/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
            -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$LLAMA_CUDA_ARCH" "${host[@]}" \
            -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
       && cmake --build "$src/build" -j"$(nproc)" --target llama-server llama-cli llama-bench; then
        install -m755 "$src/build/bin/llama-server" "$src/build/bin/llama-cli" \
                      "$src/build/bin/llama-bench" /usr/local/bin/
        mkdir -p "$(dirname "$stamp")"; echo "$LLAMA_REF" > "$stamp"
        echo "    llama.cpp $LLAMA_REF -> /usr/local/bin/llama-server (sm_$LLAMA_CUDA_ARCH)"
    else
        echo "    !! build llama.cpp gagal -- versi lama (kalau ada) tetap dipakai"
    fi
fi

# --- OpenCode ----------------------------------------------------------------
have="$(opencode --version 2>/dev/null || true)"
if [ "$have" = "$OPENCODE_VERSION" ]; then
    echo "    OpenCode $OPENCODE_VERSION sudah ada -- skip"
elif npm install -g --prefix /usr/local "opencode-ai@$OPENCODE_VERSION" >/dev/null 2>&1; then
    echo "    OpenCode $OPENCODE_VERSION -> /usr/local/bin/opencode"
else
    echo "    !! pemasangan OpenCode $OPENCODE_VERSION gagal (npm) -- lewati"
fi

# config OpenCode akun umum: llama-server lokal, minta izin sebelum edit/perintah.
# Ditimpa setiap update (sumbernya profiles/ai/opencode.json).
install -d -o "$PUB" -g "$PUB" "$H/.config" "$H/.config/opencode"
sed "s/@PORT@/$LLM_PORT/g" "$PDIR/opencode.json" > "$H/.config/opencode/opencode.json"
chown "$PUB:$PUB" "$H/.config/opencode/opencode.json"
echo "    config OpenCode: $H/.config/opencode/opencode.json (model: llama-server :$LLM_PORT)"
