#!/usr/bin/env python3
"""
Generate pseudo-labels with an open-vocabulary detector (OWL-ViT by default).

Outputs Ultralytics/YOLO-style labels and a classes.txt mapping derived from prompts.

Usage:
  source .venv-ovd/bin/activate
  python Scripts/ovd/ovd_generate.py --images path/to/images \
         --prompts Scripts/ovd/prompts_en.txt --out ovd-data \
         --model google/owlvit-base-patch16 --conf 0.25 --iou 0.5

Clean pass only:
  python Scripts/ovd/ovd_generate.py --clean ovd-data --min-area 0.006 --max-aspect 4.0 --merge-iou 0.6
"""
import argparse
import json
import math
from pathlib import Path
from typing import Iterable, List, Tuple

import numpy as np
import torch
import cv2
from tqdm import tqdm
from PIL import Image
from transformers import OwlViTProcessor, OwlViTForObjectDetection


def load_prompts(path: Path) -> List[str]:
    return [p.strip() for p in path.read_text(encoding='utf-8').splitlines() if p.strip() and not p.startswith('#')]


def xyxy_to_yolo(x1, y1, x2, y2, w, h):
    cx = ((x1 + x2) / 2) / w
    cy = ((y1 + y2) / 2) / h
    bw = (x2 - x1) / w
    bh = (y2 - y1) / h
    return cx, cy, bw, bh


def iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)
    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    inter = inter_w * inter_h
    area_a = max(0.0, (ax2 - ax1)) * max(0.0, (ay2 - ay1))
    area_b = max(0.0, (bx2 - bx1)) * max(0.0, (by2 - by1))
    denom = area_a + area_b - inter
    return inter / denom if denom > 0 else 0.0


def nms(boxes: List[Tuple[float, float, float, float]], scores: List[float], iou_thr: float):
    idxs = np.argsort(scores)[::-1]
    keep = []
    while len(idxs):
        i = idxs[0]
        keep.append(i)
        if len(idxs) == 1:
            break
        rest = idxs[1:]
        suppress = []
        for j in rest:
            if iou(boxes[i], boxes[j]) >= iou_thr:
                suppress.append(j)
        idxs = np.array([k for k in rest if k not in suppress])
    return keep


def generate(args):
    out = Path(args.out)
    (out / 'labels').mkdir(parents=True, exist_ok=True)
    (out / 'images').mkdir(parents=True, exist_ok=True)

    prompts = load_prompts(Path(args.prompts))
    classes_path = out / 'classes.txt'
    classes_path.write_text('\n'.join(prompts), encoding='utf-8')
    name_to_id = {name: i for i, name in enumerate(prompts)}

    proc = OwlViTProcessor.from_pretrained(args.model)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = OwlViTForObjectDetection.from_pretrained(args.model).to(device)
    model.eval()

    images = []
    imroot = Path(args.images)
    for ext in ('*.jpg', '*.jpeg', '*.png', '*.bmp'):
        images.extend(imroot.rglob(ext))
    images.sort()
    existing = {p.stem for p in (out / 'labels').glob('*.txt')} if args.resume else set()
    chunk_size = max(1, args.prompt_chunk)

    for img_path in tqdm(images, desc='OVD inference'):
        if img_path.stem in existing:
            continue
        try:
            image = Image.open(img_path).convert('RGB')
        except Exception:
            continue

        boxes: List[List[float]] = []
        scores: List[float] = []
        labels_idx: List[int] = []
        for start in range(0, len(prompts), chunk_size):
            chunk = prompts[start:start + chunk_size]
            inputs = proc(text=[chunk], images=image, return_tensors="pt")
            inputs = {k: v.to(device) for k, v in inputs.items()}
            with np.errstate(all='ignore'):
                outputs = model(**inputs)
            target_sizes = torch.tensor([(image.height, image.width)], device=device)
            result = proc.post_process_object_detection(
                outputs=outputs, threshold=args.conf, target_sizes=target_sizes
            )[0]
            chunk_boxes = result.get('boxes', [])
            chunk_scores = result.get('scores', [])
            chunk_labels = result.get('labels', [])
            boxes.extend(chunk_boxes.tolist())
            scores.extend(chunk_scores.tolist())
            labels_idx.extend((chunk_labels + start).tolist())

        if not boxes:
            continue

        # NMS per prompt label
        kept = nms(boxes, scores, args.iou)
        H, W = image.height, image.width
        yolo_lines = []
        for i in kept:
            x1, y1, x2, y2 = boxes[i]
            # area / aspect filters (optional)
            bw = max(0.0, x2 - x1)
            bh = max(0.0, y2 - y1)
            area = (bw * bh) / float(W * H)
            asp = (max(bw, bh) / max(1e-6, min(bw, bh))) if bw > 0 and bh > 0 else 1e6
            if area < args.min_area or asp > args.max_aspect:
                continue
            cls_name = prompts[labels_idx[i]]
            cls_id = name_to_id.get(cls_name, None)
            if cls_id is None:
                continue
            cx, cy, ww, hh = xyxy_to_yolo(x1, y1, x2, y2, W, H)
            yolo_lines.append(f"{cls_id} {cx:.6f} {cy:.6f} {ww:.6f} {hh:.6f}")

        if not yolo_lines:
            continue

        # Symlink/copy image under dataset root for Ultralytics
        dst_img = out / 'images' / img_path.name
        if not dst_img.exists():
            try:
                # hard copy; could symlink instead
                import shutil
                shutil.copy2(img_path, dst_img)
            except Exception:
                pass

        (out / 'labels').mkdir(parents=True, exist_ok=True)
        (out / 'labels' / (img_path.stem + '.txt')).write_text('\n'.join(yolo_lines), encoding='utf-8')


def clean(args):
    root = Path(args.clean)
    labels_dir = root / 'labels'
    updated = 0
    for p in labels_dir.glob('*.txt'):
        lines = [ln.strip() for ln in p.read_text().splitlines() if ln.strip()]
        if not lines:
            continue
        # Very light dedupe: merge identical class+box lines
        uniq = list(dict.fromkeys(lines))
        if uniq != lines:
            p.write_text('\n'.join(uniq), encoding='utf-8')
            updated += 1
    print(f"Cleaned {updated} label files")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--images', help='Directory of images for teacher inference')
    ap.add_argument('--prompts', default='Scripts/ovd/prompts_en.txt')
    ap.add_argument('--out', default='ovd-data')
    ap.add_argument('--model', default='google/owlvit-base-patch16')
    ap.add_argument('--conf', type=float, default=0.25)
    ap.add_argument('--iou', type=float, default=0.5)
    ap.add_argument('--min-area', type=float, default=0.004)
    ap.add_argument('--max-aspect', type=float, default=6.0)
    ap.add_argument('--prompt-chunk', type=int, default=128, help='Number of prompts per forward pass')
    ap.add_argument('--clean', help='Run only cleanup on an existing ovd-data dir')
    ap.add_argument('--resume', action='store_true', help='Skip images that already have labels')
    args = ap.parse_args()

    if args.clean:
        clean(args)
        return
    assert args.images, '--images is required when generating labels'
    generate(args)


if __name__ == '__main__':
    main()
