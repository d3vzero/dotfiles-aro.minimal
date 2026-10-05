# tools

Alat uji manual -- tidak dipakai bootstrap/update.

## aro-stress (v2)

Stress test compositor aro lewat `aroctl`. v2: info sistem/GPU
(`system.txt`), metrik GPU per menit (nvidia-smi / sysfs AMD), beban GPU
paralel opsional (`GPU_LOAD_CMD`), aksi multi-monitor otomatis, ringkasan
error log aro + error GPU kernel di akhir.

Pasang (sebagai Admin):

    sudo install -m755 /opt/dotfiles-aro.minimal/tools/aro-stress /usr/local/bin/aro-stress

Jalankan dari kitty, sebagai user yang sedang login di aro:

    setsid -f aro-stress 8 >/dev/null 2>&1     # 8 jam, jalan di latar
    tail -f ~/aro-stress/latest/actions.log    # pantau
    touch ~/aro-stress/STOP                    # berhenti

## d2-infer-load.py

Beban GPU realistis (inference Detectron2 Mask R-CNN) untuk `GPU_LOAD_CMD`,
atau uji cepat bahwa op CUDA Detectron2 jalan. Butuh profil `ai` + CUDA.

    /opt/detectron2/venv/bin/python /opt/dotfiles-aro.minimal/tools/d2-infer-load.py ~/uji/gambar 3

## Urutan uji di workstation AI

1. Tanpa beban GPU, 8 jam (cek aro di driver NVIDIA):

       setsid -f aro-stress 8 >/dev/null 2>&1

2. Setelah Detectron2 terpasang, dengan beban GPU, 4 jam:

       GPU_LOAD_CMD="/opt/detectron2/venv/bin/python /opt/dotfiles-aro.minimal/tools/d2-infer-load.py $HOME/uji/gambar 20" \
       setsid -f aro-stress 4 >/dev/null 2>&1

3. Bandingkan `summary.txt` + `system.txt` kedua tes dan hasil VM. Kalau
   tes 1 bersih tapi tes 2 bermasalah, masalahnya interaksi dengan beban
   GPU, bukan aro di driver NVIDIA.
