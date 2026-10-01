# tools

Alat uji manual -- tidak dipakai bootstrap/update.

## aro-stress

Stress test compositor aro lewat `aroctl` (sudah dipakai 8 jam di VM).

Pasang (sebagai Admin):

    sudo install -m755 /opt/dotfiles-aro.minimal/tools/aro-stress /usr/local/bin/aro-stress

Jalankan dari kitty, sebagai user yang sedang login di aro:

    setsid -f aro-stress 8 >/dev/null 2>&1     # 8 jam, jalan di latar
    tail -f ~/aro-stress/latest/actions.log    # pantau
    touch ~/aro-stress/STOP                    # berhenti
