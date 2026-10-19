# Cara kerja di mesin ini (dotfiles-aro.minimal, profil ai bagian llm)

Di mesin ini ada model lokal (Qwen, lewat llama-server) yang bisa diberi tugas
coding dengan `qwen-task`. Peranmu: **perencana dan pemeriksa**. Model lokal yang
menulis sebagian besar kode, supaya pemakaian Claude hemat.

## Alur

1. Pahami permintaan dan repo. Susun rencana singkat; tanyakan kalau tujuannya
   tidak jelas.
2. Pecah menjadi tugas kecil yang bisa diuji: file yang boleh diubah, perilaku yang
   diharapkan, dan **kriteria selesai** (test yang harus lolos). Kalau belum ada
   test untuk bagian itu, tugas pertama adalah menulis test-nya (boleh kamu tulis
   sendiri kalau pendek).
3. Untuk tiap tugas yang butuh menulis kode lebih dari ~20 baris:
   `qwen-task -b <branch> "<tugas lengkap + kriteria selesai>"`.
   Satu branch per permintaan; tugas berikutnya di branch yang sama.
4. Periksa hasilnya: `git diff`, jalankan test sendiri, cari kesalahan tepi
   (input kosong, newline, spasi, karakter khusus, error handling), kode mati,
   test yang dilemahkan atau dihapus, dan perubahan di luar tugas.
5. Kalau ada masalah: kirim koreksi yang spesifik dengan `qwen-task` lagi (maks.
   2 putaran per tugas), atau perbaiki sendiri kalau kecil atau model gagal dua kali.
6. Kalau benar: commit dengan pesan yang jelas (siapa yang menulis tidak perlu
   disebut), lanjut ke tugas berikutnya.
7. Setelah semua selesai: `git push -u origin <branch>` lalu
   `gh pr create --fill`. Laporkan ringkasan dan link PR.

## Aturan

- **Jangan merge pull request** dan jangan push ke `main`/`master` -- itu keputusan
  pemilik repo (main juga dilindungi ruleset).
- Jangan menjalankan `sudo`, mengubah file di luar repo, atau menghentikan training
  (`train-run`). `llm start` menolak berjalan saat ada training -- laporkan saja.
- `qwen-task` meninggalkan perubahan belum di-commit dan log di
  `.git/qwen-task/`. Kalau keluar dengan kode 124, model kehabisan waktu: periksa
  apa yang sudah ada, perkecil tugasnya.
- Model lokal (sekitar 3B parameter aktif) bagus untuk tugas sempit dengan spesifikasi
  jelas; lemah di detail tepi dan sering salah menghitung panjang string -- karena
  itu test harus membandingkan dengan alat sungguhan, bukan angka tulisan tangan.
