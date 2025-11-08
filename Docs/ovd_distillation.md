# Open‑Vocabulary Distillation (Teacher → YOLO Student)

This guide lets you bootstrap much higher recall/coverage by using an Open‑Vocabulary Detector (OVD) as a teacher (e.g., OWL‑ViT / Grounding DINO), then distill the labels into a fast YOLOv8 student that ships on‑device (Core ML).

High‑level
- Teacher: OWL‑ViT (base) or Grounding DINO (Swin‑T/B). Runs offline on your laptop to generate pseudo‑labels from prompts (arbitrary nouns), not limited to COCO‑80.
- Cleaner: apply confidence + IoU NMS + synonym normalization (maps variants to canonical class names).
- Student: YOLOv8 (m or l). Train on pseudo‑labels + any real labels; optionally KD losses.
- Export: CoreML MLProgram @ 896–1024 with NMS thresholds baked in; drop in DetectionKit resources.

## 0) One‑time setup
```
python3 -m venv .venv-ovd
source .venv-ovd/bin/activate
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install transformers pillow opencv-python numpy tqdm ultralytics coremltools==8.3.0
```

## 1) Prepare prompts
Edit `Scripts/ovd/prompts_en.txt`. Add the long‑tail nouns you care about (e.g., “moka pot”, “lanyard”, “water bottle”).

## 2) Generate pseudo‑labels with OWL‑ViT
```
source .venv-ovd/bin/activate
python Scripts/ovd/ovd_generate.py \
  --images path/to/images \
  --prompts Scripts/ovd/prompts_en.txt \
  --out ovd-data \
  --model google/owlvit-base-patch16 \
  --conf 0.25 --iou 0.5
```
This writes Ultralytics/YOLO‑format labels under `ovd-data/labels` with canonical class IDs derived from your prompt list (saved to `ovd-data/classes.txt`).

## 3) Optional cleaning
```
python Scripts/ovd/ovd_generate.py --clean ovd-data --min-area 0.006 --max-aspect 4.0 --merge-iou 0.6
```
This pass merges duplicates, rejects tiny/odd boxes, and normalizes synonyms to match `VocabStore`.

## 4) Train YOLO student on pseudo‑labels
```
# Prepare Ultralytics dataset YAML
python Scripts/ovd/ovd_make_dataset_yaml.py --root ovd-data --name ovdset --out ovd-data/ovdset.yaml

# Train (choose size according to device budget)
 yolo detect train model=yolov8m.pt data=ovd-data/ovdset.yaml imgsz=896 epochs=60 \
      lr0=0.01 batch=16 mosaic=0.5 hsv_h=0.015 hsv_s=0.7 hsv_v=0.4 \
      name=ovd-student-m-896

# (Option) KD: use the teacher boxes as additional loss targets
# See Scripts/ovd/README for pointers to integrating KD losses with Ultralytics.
```

## 5) Export to Core ML (student)
```
source .venv-ovd/bin/activate
python Scripts/ovd/ovd_export_coreml.py \
  --weights runs/detect/ovd-student-m-896/weights/best.pt \
  --imgsz 896 --nms --out DetectionKit/Sources/DetectionKit/Resources/YOLOv8-ovd.mlpackage
```
The iOS app will auto‑prefer this package (the loader checks multiple common names).

## 6) Integrate with translations
- Update `VocabStore` aliases if you add long‑tail class names so they map to canonical English keys.
- Add Spanish strings to `VocabStore/Resources/vocab-es-en.json` for the most common long‑tail nouns.

## Model picks
- Fastest path: OWL‑ViT (HF Transformers) — simple install; good zero‑shot.
- Stronger teacher: Grounding DINO (requires a bit more setup, better grounding; swap into `ovd_generate.py` later).

## Notes
- Start with ~3–5k images across your environments; more variety → better student.
- Evaluate with `yolo val` on a small held‑out set you hand‑label.
- Keep Core ML export at 896–1024 for accuracy; choose m or l according to latency/size targets.

