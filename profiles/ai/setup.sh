#!/bin/bash
# profil ai: dua bagian yang bisa dipilih lewat AI_PARTS di config mesin.
#   trainer  train-run + Detectron2           (config: <conf>.d/ai-trainer.conf)
#   llm      llama.cpp + llm + OpenCode       (config: <conf>.d/ai-llm.conf)
# File config tiap bagian dibuat sekali dari template di profil ini, lalu
# dibiarkan (tidak ditimpa update.sh). Config bagian trainer pertama kali
# diisi dari nilai lama di config mesin, supaya pengaturan yang ada tidak hilang.
set -euo pipefail
CONF_D="${CONF_D:?}"
install -d -m755 "$CONF_D"

has_part() { [[ " $AI_PARTS " == *" $1 "* ]]; }

if [ ! -f "$CONF_D/ai-trainer.conf" ]; then
    sed -e "s|^AI_BACKEND=.*|AI_BACKEND=\"${AI_BACKEND:-auto}\"|" \
        -e "s|^TORCH_CUDA_ARCH=\"[^\"]*\"|TORCH_CUDA_ARCH=\"${TORCH_CUDA_ARCH:-12.0}\"|" \
        -e "s|^D2_REV=\"[^\"]*\"|D2_REV=\"${D2_REV:-}\"|" \
        -e "s|^TORCH_INDEX=\"[^\"]*\"|TORCH_INDEX=\"${TORCH_INDEX:-}\"|" \
        "$PDIR/trainer.conf" > "$CONF_D/ai-trainer.conf"
    echo "    config bagian trainer: $CONF_D/ai-trainer.conf"
fi
[ -f "$CONF_D/ai-llm.conf" ] || { install -m644 "$PDIR/llm.conf" "$CONF_D/ai-llm.conf"
                                  echo "    config bagian llm: $CONF_D/ai-llm.conf"; }

echo "    bagian ai: ${AI_PARTS}"
if has_part trainer; then bash "$PDIR/setup-trainer.sh"; fi
if has_part llm;     then bash "$PDIR/setup-llm.sh"; fi
