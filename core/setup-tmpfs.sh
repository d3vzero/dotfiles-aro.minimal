#!/bin/bash
# setup-tmpfs.sh — kurangi tulis ke NVMe (root, idempotent, aman diulang)
#
#   setup-tmpfs.sh <user-umum> [ukuran-/tmp] [ukuran-~/.cache]
#   contoh: setup-tmpfs.sh AI-Trainer 50% 4G
#
# Yang dilakukan (di /etc/fstab, berlaku setelah reboot):
#   1. /tmp di RAM (tmpfs)          — dataset SH Trainer (/tmp/shtrainer_dataset_*), build, unduhan sementara
#   2. ~/.cache user umum di RAM     — cache Firefox, thumbnail, cache aplikasi
#   3. noatime pada partisi ext4     — membaca file tidak lagi memicu tulis metadata
#   4. folder persisten untuk cache yang mahal dibuat ulang (shader, matplotlib),
#      dipakai lewat env di .bash_profile (lihat catatan di bawah)
# TIDAK dipindah ke RAM: checkpoint/output training, ~/.torch (bobot model zoo), venv.
#
# Uji tanpa menyentuh sistem: FSTAB=/tmp/fstab.test setup-tmpfs.sh <user>
set -euo pipefail

FSTAB=${FSTAB:-/etc/fstab}
user=${1:?pakai: setup-tmpfs.sh <user-umum> [ukuran-/tmp] [ukuran-cache]}
tmp_size=${2:-50%}
cache_size=${3:-2G}

[ "$(id -u)" = 0 ] || [ "$FSTAB" != /etc/fstab ] || { echo "!! jalankan sebagai root"; exit 1; }
IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$user") || { echo "!! user $user tidak ada"; exit 1; }
[ -n "$home" ] || { echo "!! home $user tidak ditemukan"; exit 1; }

[ -f "$FSTAB.bak-tmpfs" ] || cp "$FSTAB" "$FSTAB.bak-tmpfs"
changed=0
add_line() {   # add_line <mountpoint> <baris>
    if awk -v m="$1" '$0 !~ /^[[:space:]]*#/ && $2 == m {f=1} END {exit !f}' "$FSTAB"; then
        echo "   sudah ada: $1"
    else
        echo "$2" >> "$FSTAB"; echo "   ditambah : $1"; changed=1
    fi
}

echo "==> fstab: $FSTAB"
add_line /tmp "tmpfs  /tmp  tmpfs  rw,nosuid,nodev,size=$tmp_size,mode=1777  0 0"
add_line "$home/.cache" "tmpfs  $home/.cache  tmpfs  rw,nosuid,nodev,size=$cache_size,uid=$uid,gid=$gid,mode=0700  0 0"

# noatime untuk ext4 (fstabgen menulis relatime)
if grep -qE '^[^#].*[[:space:]]ext4[[:space:]].*relatime' "$FSTAB"; then
    sed -i -E '/^[^#].*[[:space:]]ext4[[:space:]]/ s/(^|,|[[:space:]])relatime(,|[[:space:]])/\1noatime\2/' "$FSTAB"
    echo "   ext4     : relatime → noatime"; changed=1
fi

echo "==> Folder"
install -d -o "$uid" -g "$gid" -m 700 "$home/.cache"
install -d -o "$uid" -g "$gid" -m 700 "$home/.local/state" \
    "$home/.local/state/shader-cache" "$home/.local/state/matplotlib"

# hanya gagal kalau fstab tidak bisa di-parse (error lain, mis. UUID di chroot, diabaikan)
if command -v findmnt >/dev/null &&
   findmnt --verify --tab-file "$FSTAB" 2>&1 | grep -qE '^[1-9][0-9]* parse error'; then
    echo "!! $FSTAB tidak valid:"; findmnt --verify --tab-file "$FSTAB" || true
    echo "   Cadangan asli: $FSTAB.bak-tmpfs"; exit 1
fi

echo
grep -E '[[:space:]](tmpfs|ext4)[[:space:]]' "$FSTAB"
echo
[ $changed = 1 ] && echo "Selesai. Berlaku setelah reboot." || echo "Tidak ada perubahan."
cat <<EOF

Tambahkan ke .bash_profile $user (sebelum exec aro), supaya cache yang mahal
dibuat ulang tetap di disk dan tidak hilang tiap boot:
  export MESA_SHADER_CACHE_DIR="\$HOME/.local/state/shader-cache/mesa"
  export __GL_SHADER_DISK_CACHE_PATH="\$HOME/.local/state/shader-cache/nvidia"
  export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
  export MPLCONFIGDIR="\$HOME/.local/state/matplotlib"
EOF
