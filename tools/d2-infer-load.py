#!/usr/bin/env python3
"""d2-infer-load.py — beban GPU realistis untuk aro-stress (GPU_LOAD_CMD).

Satu run = muat model Detectron2 (COCO Mask R-CNN R50-FPN dari model zoo),
lalu inference pada semua gambar di folder uji sebanyak ROUNDS putaran.
Exit code 0 = sukses, selain itu = gagal (dicatat aro-stress di gpuload.log).

Pakai:
  /opt/detectron2/venv/bin/python /opt/dotfiles-aro.minimal/tools/d2-infer-load.py ~/uji/gambar 20
Bobot model diunduh sekali ke ~/.torch/iopath_cache saat run pertama.
"""
import sys, time, glob, os

import cv2
import torch
from detectron2 import model_zoo
from detectron2.config import get_cfg
from detectron2.engine import DefaultPredictor

img_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/uji/gambar")
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 20
cfg_name = "COCO-InstanceSegmentation/mask_rcnn_R_50_FPN_3x.yaml"

if not torch.cuda.is_available():
    print("CUDA tidak tersedia", file=sys.stderr)
    sys.exit(2)

paths = sorted(p for ext in ("jpg", "jpeg", "png") for p in glob.glob(f"{img_dir}/*.{ext}"))
if not paths:
    print(f"tidak ada gambar di {img_dir}", file=sys.stderr)
    sys.exit(3)
imgs = [cv2.imread(p) for p in paths]

cfg = get_cfg()
cfg.merge_from_file(model_zoo.get_config_file(cfg_name))
cfg.MODEL.WEIGHTS = model_zoo.get_checkpoint_url(cfg_name)
cfg.MODEL.ROI_HEADS.SCORE_THRESH_TEST = 0.5
cfg.MODEL.DEVICE = "cuda"
pred = DefaultPredictor(cfg)

t0 = time.time(); n = 0; dets = 0
for _ in range(rounds):
    for im in imgs:
        out = pred(im)
        dets += len(out["instances"])
        n += 1
torch.cuda.synchronize()
dt = time.time() - t0
print(f"{torch.cuda.get_device_name(0)}: {n} gambar, {n/dt:.1f} img/s, "
      f"{dets} deteksi, VRAM puncak {torch.cuda.max_memory_allocated()/2**20:.0f} MB")
