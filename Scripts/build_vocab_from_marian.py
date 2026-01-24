#!/usr/bin/env python3
"""
Build a bilingual vocabulary JSON for YOLO/COCO classes using local Marian models.

Outputs VocabStore/Resources/vocab-es-en.json with entries:
  { "className": "car", "english": "the car", "spanish": "el coche" }

Usage:
  source .venv-llm/bin/activate
  python Scripts/build_vocab_from_marian.py \
      --en-es LLMKit/Sources/LLMKit/Resources/hf_en_es \
      --es-en LLMKit/Sources/LLMKit/Resources/hf_es_en \
      --out VocabStore/Resources/vocab-es-en.json
"""
import argparse
import json
from pathlib import Path
from typing import List

from transformers import pipeline


COCO_CLASSES: List[str] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
    "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--en-es', required=True, help='Path to HF-format EN→ES model dir')
    ap.add_argument('--es-en', required=False, help='Path to HF-format ES→EN model dir')
    ap.add_argument('--out', default='VocabStore/Resources/vocab-es-en.json')
    args = ap.parse_args()

    trans_en_es_local = pipeline('translation', model=args.en_es, tokenizer=args.en_es)
    # Fallback to hosted model if local output looks identical (common when
    # conversion lacks target language settings).
    try:
        trans_en_es_remote = pipeline('translation', model='Helsinki-NLP/opus-mt-en-es', tokenizer='Helsinki-NLP/opus-mt-en-es')
    except Exception:
        trans_en_es_remote = None

    items = []
    for cname in COCO_CLASSES:
        noun = cname.strip().lower()
        english = f"the {noun}"
        # Ask for article by providing an English article in the source.
        try:
            out_local = trans_en_es_local(english, max_length=32)
            cand = out_local[0]['translation_text'].strip()
            # If the local model returns an English-like echo, try remote.
            if trans_en_es_remote is not None and cand.lower() == english.lower():
                out_remote = trans_en_es_remote(english, max_length=32)
                cand = out_remote[0]['translation_text'].strip()
            spanish = cand
        except Exception:
            spanish = f"el/la {noun}"

        items.append({
            'className': noun,
            'english': english,
            'spanish': spanish
        })

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open('w', encoding='utf-8') as f:
        json.dump({'items': items}, f, ensure_ascii=False, indent=2)

    print(f"Wrote {len(items)} entries → {out_path}")


if __name__ == '__main__':
    main()
