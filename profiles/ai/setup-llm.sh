#!/bin/bash
# profil ai, bagian llm: llama.cpp (CUDA, dibangun dari LLAMA_REF), perintah llm
# (start/stop/status, model sebagian di VRAM dan expert MoE di RAM), OpenCode
# (agent coding di terminal, memakai llama-server lokal) dan gh (GitHub CLI).
# Pengaturan: $CONF_D/ai-llm.conf. Model .gguf diunduh manual ke ~/models.
set -euo pipefail
# shellcheck disable=SC1091
. "$CONF_D/ai-llm.conf"
PUB="$PUBLIC_USER"; H="$PUBLIC_HOME"

install -m755 "$PDIR/bin/llm" "$PDIR/bin/qwen-task" "$PDIR/bin/ai-project" /usr/local/bin/
# launcher: OpenCode dan Claude Code (pilih proyek, buka di kitty dengan app id sendiri)
install -d /usr/local/share/applications
install -m644 "$PDIR/desktop/opencode.desktop" /usr/local/share/applications/opencode.desktop
if [ "${CLAUDE_CODE:-yes}" = yes ]; then
    install -m644 "$PDIR/desktop/claude.desktop" /usr/local/share/applications/claude.desktop
else
    rm -f /usr/local/share/applications/claude.desktop
fi
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
# opencode-ai di npm hanya pembungkus: binary aslinya dipasang oleh postinstall.mjs,
# yang tidak selalu dijalankan npm saat dipanggil sebagai root -> jalankan sendiri,
# lalu pastikan opencode --version benar-benar menjawab versi yang diminta.
have="$(opencode --version 2>/dev/null || true)"
if [ "$have" = "$OPENCODE_VERSION" ]; then
    echo "    OpenCode $OPENCODE_VERSION sudah ada -- skip"
else
    pkg=/usr/local/lib/node_modules/opencode-ai
    if npm install -g --prefix /usr/local "opencode-ai@$OPENCODE_VERSION" > /tmp/opencode-npm.log 2>&1 &&
       (cd "$pkg" && node postinstall.mjs) >> /tmp/opencode-npm.log 2>&1 &&
       [ "$(opencode --version 2>/dev/null)" = "$OPENCODE_VERSION" ]; then
        echo "    OpenCode $OPENCODE_VERSION -> /usr/local/bin/opencode"
    else
        echo "    !! pemasangan OpenCode $OPENCODE_VERSION gagal -- lihat /tmp/opencode-npm.log"
    fi
fi

# config OpenCode akun umum: llama-server lokal, minta izin sebelum edit/perintah.
# Ditimpa setiap update (sumbernya profiles/ai/opencode.json).
install -d -o "$PUB" -g "$PUB" "$H/.config" "$H/.config/opencode"
sed "s/@PORT@/$LLM_PORT/g" "$PDIR/opencode.json" > "$H/.config/opencode/opencode.json"
chown "$PUB:$PUB" "$H/.config/opencode/opencode.json"
echo "    config OpenCode: $H/.config/opencode/opencode.json (model: llama-server :$LLM_PORT)"

# --- Claude Code (perencana + pemeriksa; qwen-task menyerahkan penulisan ke model lokal)
# Installer resmi per-user (~/.local/bin/claude, update otomatis, kanal stable).
# CLAUDE.md dan settings.json hanya dipasang kalau belum ada: setelah itu milik user.
if [ "${CLAUDE_CODE:-yes}" = yes ]; then
    if [ -x "$H/.local/bin/claude" ]; then
        echo "    Claude Code sudah ada ($(runuser -u "$PUB" -- "$H/.local/bin/claude" --version 2>/dev/null | head -n1)) -- update otomatis"
    elif runuser -u "$PUB" -- env HOME="$H" bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s stable' > /tmp/claude-install.log 2>&1 &&
         [ -x "$H/.local/bin/claude" ]; then
        echo "    Claude Code -> $H/.local/bin/claude (login sekali: jalankan claude)"
    else
        echo "    !! pemasangan Claude Code gagal -- lihat /tmp/claude-install.log"
    fi
    install -d -o "$PUB" -g "$PUB" "$H/.claude"
    if [ ! -e "$H/.claude/CLAUDE.md" ]; then
        install -m644 -o "$PUB" -g "$PUB" "$PDIR/claude/CLAUDE.md" "$H/.claude/CLAUDE.md"
        echo "    $H/.claude/CLAUDE.md dipasang (tidak ditimpa update berikutnya)"
    fi
    # settings.json: installer Claude Code membuatnya sendiri (autoUpdatesChannel) ->
    # GABUNGKAN izin dari repo ke isi yang ada; aturan buatan user tetap dipertahankan
    sj="$H/.claude/settings.json"
    if [ ! -s "$sj" ]; then
        install -m644 -o "$PUB" -g "$PUB" "$PDIR/claude/settings.json" "$sj"
        echo "    $sj dipasang"
    elif jq -s '.[0] * {permissions: {
                 allow: ((.[0].permissions.allow // []) + .[1].permissions.allow | unique),
                 deny:  ((.[0].permissions.deny  // []) + .[1].permissions.deny  | unique)}}' \
             "$sj" "$PDIR/claude/settings.json" > "$sj.new" 2>/dev/null; then
        if cmp -s "$sj" "$sj.new"; then rm -f "$sj.new"
        else mv -f "$sj.new" "$sj"; chown "$PUB:$PUB" "$sj"; echo "    izin dari repo digabung ke $sj"; fi
    else
        rm -f "$sj.new"; echo "    !! $sj tidak bisa dibaca sebagai JSON -- izin dari repo tidak digabung"
    fi
fi
