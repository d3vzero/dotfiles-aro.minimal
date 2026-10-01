#!/bin/bash
# profil ai: build llama.cpp (Vulkan) di /opt/llama.cpp, link ke /usr/local/bin
set -euo pipefail
SRC=/opt/llama.cpp
BIN="$SRC/build/bin"

if [ -x "$BIN/llama-server" ] && [ "${UPDATE_LLAMA:-0}" != "1" ]; then
    echo "    llama.cpp sudah ada -- skip (UPDATE_LLAMA=1 untuk pull + rebuild)"
else
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" pull --ff-only
    else
        git clone https://github.com/ggml-org/llama.cpp "$SRC"
    fi
    cmake -S "$SRC" -B "$SRC/build" -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "$SRC/build" --config Release -j"$(nproc)"
fi
for b in llama-server llama-cli; do
    if [ -x "$BIN/$b" ]; then ln -sf "$BIN/$b" /usr/local/bin/$b; fi
done
mkdir -p /srv/models
chmod 755 /srv/models
echo "    Model GGUF: download manual ke /srv/models/"
