# On-Device Detection Upgrade with Automated Data + MobileCLIP Precision

This walkthrough shows how to assemble a high-recall, high-precision detection stack that stays fully on-device once the student
model ships. It layers three pillars:

1. **Automated, free data sourcing** from open repositories (no custom photo shoots required).
2. **Open-vocabulary distillation** to train a YOLOv8 student that understands ~1K everyday objects.
3. **MobileCLIP verification** inside the DetectionKit pipeline to suppress false positives without sacrificing recall.

---

## 1. Pull Open Datasets Instead of Shooting Photos
Use the `openimages` downloader to grab a diverse sample from Google’s Open Images (600+ categories) and Objects365 (365+
categories). Both are free; you only pay with download time.

```bash
python3 -m venv .venv-ovd
source .venv-ovd/bin/activate
pip install --upgrade pip
pip install openimages tqdm

# Download 50 images per class (adjust to control dataset size)
python -m openimages.downloader \
  --classes_file Scripts/ovd/prompts_en_common_1000.txt \
  --max-images 50 \
  --dataset-dir datasets/openimages \
  --no_labels

# Pull the official annotations for the same split (YOLO labels will be regenerated later)
python -m openimages.downloader \
  --classes_file Scripts/ovd/prompts_en_common_1000.txt \
  --max-images 50 \
  --dataset-dir datasets/openimages \
  --annotations
```

The downloader stores images under `datasets/openimages/train/…` by default; point later scripts at the directory root so they
recursively pick up every JPEG.

To widen coverage further without extra effort, mirror the Objects365 mini split (free, no login) with `aria2c` or `wget`:

```bash
mkdir -p datasets/objects365
wget -c https://objects365.org/download/objects365v1/objects365-mini.zip -P datasets/objects365
unzip datasets/objects365/objects365-mini.zip -d datasets/objects365
```

> Tip: Run both downloads overnight; even the mini splits provide tens of thousands of labeled boxes across indoor/outdoor scenes.

## 2. Use the Pre-Baked Prompt Library (≈1,000 Nouns)
The repository now ships `Scripts/ovd/prompts_en_common_1000.txt`, a curated list of 1,000 everyday object prompts spanning
kitchens, living rooms, offices, gyms, cafés, grocery aisles, parking lots, parks, and more. Feed it directly to the teacher and
to MobileCLIP without crafting prompts by hand.

If you ever want to regenerate or customize the list, edit `Scripts/ovd/prompts_en_common_1000.txt` (simple text file—one noun
phrase per line) and rerun the pipeline.

## 3. Prepare the Distillation Environment
Install the rest of the toolchain on top of the same virtualenv.

```bash
source .venv-ovd/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install transformers pillow opencv-python numpy tqdm ultralytics coremltools==8.3.0
```

## 4. Generate Zero-Shot Pseudo-Labels Automatically
Point the teacher at the downloaded datasets. OWL-ViT (base) runs on CPU, but a GPU accelerates things; swap in Grounding DINO if
you have the compute.

```bash
python Scripts/ovd/ovd_generate.py \
  --images datasets/openimages \
  --prompts Scripts/ovd/prompts_en_common_1000.txt \
  --out ovd-data \
  --model google/owlvit-base-patch16 \
  --conf 0.22 --iou 0.5
```

To add the Objects365 mini images, point the same command at the extracted folder (the script appends results when `--out` matches).

## 5. Clean and Normalize Pseudo-Labels
```bash
python Scripts/ovd/ovd_generate.py \
  --clean ovd-data \
  --min-area 0.006 \
  --max-aspect 4.0 \
  --merge-iou 0.6
```
This merges overlapping boxes, removes tiny artifacts, and aligns synonyms with the canonical vocabulary used throughout the app.

## 6. Train the YOLO Student for Free (GPU Options)
Pick any of the free GPU tiers below. Each setup takes ~5 minutes and gives you a T4 or better—plenty for a 60-epoch YOLOv8m run.

### Option A: Google Colab Free Tier
1. Visit [https://colab.research.google.com](https://colab.research.google.com) and create a new notebook.
2. Set the runtime to **GPU** (Runtime → Change runtime type → GPU).
3. Mount Google Drive (optional) or use Colab’s ephemeral storage.
4. Copy the repo or upload the `Scripts/` + dataset folders (zip first for faster transfer).
5. Run the same `pip install` commands as above, then execute:
   ```bash
   yolo detect train model=yolov8m.pt data=ovd-data/ovdset.yaml imgsz=896 epochs=60 \
        lr0=0.01 batch=16 mosaic=0.5 hsv_h=0.015 hsv_s=0.7 hsv_v=0.4 \
        name=ovd-student-m-896
   ```
6. Download `runs/detect/ovd-student-m-896/weights/best.pt` back to your machine.

### Option B: Kaggle Notebooks (Free T4/P100)
1. Go to [https://www.kaggle.com/code](https://www.kaggle.com/code) and start a new notebook.
2. Turn on the **GPU** accelerator (Notebook → Accelerators → GPU → T4/P100).
3. Upload your `ovd-data` zip and the repo’s `Scripts/ovd` folder or mount Google Drive.
4. Install dependencies exactly as in Step 3.
5. Run the `yolo detect train …` command (identical hyperparameters).
6. Use Kaggle’s output panel to download the trained weights.

### Option C: Paperspace Gradient (Community Free Tier)
1. Sign up at [https://www.paperspace.com/gradient](https://www.paperspace.com/gradient) → Notebooks → Free GPU.
2. Select a **Free GPU (M4000/T4 depending on queue availability)** image with Ubuntu + Python.
3. Clone the repo or upload the scripts/data, install dependencies, and run the same YOLO training command.

> All three platforms are free (usage caps apply) and let you resume training later if you save checkpoints to cloud storage.

Once training finishes, generate the dataset YAML (only once):
```bash
python Scripts/ovd/ovd_make_dataset_yaml.py \
  --root ovd-data \
  --name ovdset \
  --out ovd-data/ovdset.yaml
```

## 7. Export the Student to Core ML
```bash
python Scripts/ovd/ovd_export_coreml.py \
  --weights runs/detect/ovd-student-m-896/weights/best.pt \
  --imgsz 896 \
  --nms \
  --out DetectionKit/Sources/DetectionKit/Resources/YOLOv8-ovd.mlpackage
```
DetectionKit automatically prefers this package; no code changes required.

## 8. Wire the High-Recall Detector into DetectionKit
Follow the high-scale detection design doc (`Docs/2025-11-08-high-scale-detection-design.md`) to:
- Lower YOLO confidence to ~0.15 and IoU to ~0.35 so the new model emits dense proposals.
- Raise the maximum detection cap (e.g., 4096 boxes) to keep recall high.
- Enable `DetectionFilter` for size filtering, confidence bucketing, and fast NMS before MobileCLIP kicks in.
- Keep `DetectionVM` throttling + temporal smoothing to stabilize boxes frame-to-frame.

## 9. Integrate MobileCLIP as the Precision Filter
1. Embed all 1,000 prompt embeddings at build time:
   ```bash
   python Scripts/vlm/embed_labels.py \
     --labels Scripts/ovd/prompts_en_common_1000.txt \
     --out DetectionKit/Sources/DetectionKit/Resources/mobileclip_labelbank.json
   ```
2. Configure `VLMReferee` to batch 32 crops, target mid-confidence detections (0.15–0.60), and apply cosine gates:
   - ≥0.80 → accept or relabel (mid bucket)
   - 0.75–0.80 → keep but lower confidence (flag for future human verification)
   - <0.75 → drop the detection
3. Skip MobileCLIP for boxes above 0.60 confidence to preserve throughput.

## 10. Refresh Vocabulary and Translations
- Map any new English labels to your canonical class names so they stay consistent across detectors and UI.
- Let `LLMService` translate missing terms once, then cache them for gameplay.

## 11. Validate and Iterate
- Hand-label ~200 images across scenes and run `yolo val` to monitor precision/recall.
- Periodically rerun Steps 1–7 with updated prompt lists to grow coverage.
- Cache MobileCLIP decisions (label + similarity) in `DetectionCache` so repeated scenes skip re-verification.

---

By automating dataset collection, distillation, and precision filtering, you get a broad on-device detector that rivals cloud
accuracy while remaining free to train (using community GPU tiers) and entirely offline at runtime.
