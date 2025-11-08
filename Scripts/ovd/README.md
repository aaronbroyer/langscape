# OVD → YOLO Distillation Scripts

- `prompts_en.txt` — seed list of nouns to detect.
- `ovd_generate.py` — run OWL‑ViT to produce YOLO labels under `ovd-data/`.
- `ovd_make_dataset_yaml.py` — creates Ultralytics dataset YAML from `ovd-data`.
- `ovd_export_coreml.py` — export trained YOLO student to Core ML.

Quick start
```
python3 -m venv .venv-ovd && source .venv-ovd/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install transformers pillow opencv-python numpy tqdm ultralytics coremltools==8.3.0

python Scripts/ovd/ovd_generate.py --images path/to/images --prompts Scripts/ovd/prompts_en.txt --out ovd-data
python Scripts/ovd/ovd_make_dataset_yaml.py --root ovd-data --out ovd-data/ovdset.yaml

yolo detect train model=yolov8m.pt data=ovd-data/ovdset.yaml imgsz=896 epochs=60 name=ovd-student-m-896
python Scripts/ovd/ovd_export_coreml.py --weights runs/detect/ovd-student-m-896/weights/best.pt --imgsz 896 --out DetectionKit/Sources/DetectionKit/Resources/YOLOv8-ovd.mlpackage
```

Switch teacher
- Replace OWL‑ViT with Grounding DINO (Swin‑T) by plugging its processor/model where indicated in `ovd_generate.py`.

KD pointers
- Ultralytics supports custom losses via callbacks. Feed teacher logits/scores into distillation losses for classification/regression confidence matching.
