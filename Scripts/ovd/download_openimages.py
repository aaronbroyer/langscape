#!/usr/bin/env python3
"""Chunked Open Images downloader using the bundled OIDv4_ToolKit."""
from __future__ import annotations
import argparse
import csv
import json
import pathlib
import re
import subprocess
import sys
from typing import Iterable, List, Sequence, Tuple

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOLKIT = ROOT / "third_party" / "OIDv4_ToolKit"
DEFAULT_CLASS_MAP = ROOT / "OID" / "csv_folder" / "class-descriptions-boxable.csv"
DEFAULT_ALIAS_MAP = pathlib.Path(__file__).with_name("openimages_aliases.json")
TOKEN_SYNONYMS = {
    "tv": "television",
    "tvs": "television",
    "smartphone": "cell phone",
    "smartphones": "cell phone",
    "cellphone": "cell phone",
    "cellphones": "cell phone",
    "iphone": "cell phone",
    "iphones": "cell phone",
    "android": "cell phone",
    "fridge": "refrigerator",
    "freezer": "refrigerator",
    "armchair": "chair",
    "recliner": "chair",
    "loveseat": "couch",
    "sofa": "couch",
    "sectional": "couch",
    "rocking": "chair",
    "ottoman": "stool",
    "beanbag": "beanbag",
    "bean": "beanbag",
    "smartwatch": "watch",
    "watch": "watch",
    "tablet": "tablet computer",
    "yogamat": "mat",
    "dumbbells": "dumbbell",
    "kettlebells": "kettlebell",
    "barbells": "barbell",
    "mic": "microphone",
    "usb": "flash drive",
    "thumb": "flash drive",
    "flash": "flash",
}
STOPWORDS = {"smart", "portable", "wireless", "cordless", "electric", "digital", "analog", "stackable"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Chunked Open Images downloader")
    parser.add_argument("classes_file", type=pathlib.Path, help="Text file with one class per line")
    parser.add_argument("dataset_dir", type=pathlib.Path, help="Directory to store downloaded data")
    parser.add_argument("max_images", type=int, help="Maximum images per class")
    parser.add_argument("chunk_size", type=int, help="Number of classes per toolkit invocation")
    parser.add_argument("--start", type=int, default=0, help="Start index in the class list")
    parser.add_argument("--count", type=int, default=None, help="Optional number of classes to process from start")
    parser.add_argument("--split", choices=["train", "validation", "test"], default="train", help="OID split to pull")
    parser.add_argument("--threads", type=int, default=10, help="Number of download threads")
    parser.add_argument("--no-labels", action="store_true", help="Skip label generation")
    parser.add_argument("--auto-yes", action="store_true", help="Automatically consent to toolkit prompts")
    parser.add_argument("--class-map", type=pathlib.Path, default=DEFAULT_CLASS_MAP, help="Path to class-descriptions-boxable.csv")
    parser.add_argument("--alias-map", type=pathlib.Path, default=DEFAULT_ALIAS_MAP, help="Optional JSON file with label aliases")
    parser.add_argument("--skipped-log", type=pathlib.Path, help="Optional file to log skipped classes")
    return parser.parse_args()


def chunked(seq: List[str], size: int) -> Iterable[List[str]]:
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def load_oid_classes(csv_path: pathlib.Path) -> dict[str, str]:
    mapping: dict[str, str] = {}
    if not csv_path.exists():
        return mapping
    with csv_path.open() as fh:
        reader = csv.reader(fh)
        for _, name in reader:
            mapping[normalize(name)] = name.strip()
    return mapping


def load_alias_map(alias_path: pathlib.Path | None) -> dict[str, str]:
    if not alias_path or not alias_path.exists():
        return {}
    try:
        data = json.loads(alias_path.read_text())
    except json.JSONDecodeError:
        return {}
    return {normalize(key): value for key, value in data.items()}


def normalize(label: str) -> str:
    text = label.lower().strip()
    text = text.replace("-", " ")
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def tokenize(label: str) -> List[str]:
    normalized = normalize(label)
    tokens: List[str] = []
    for raw in normalized.split():
        if raw in STOPWORDS:
            continue
        token = TOKEN_SYNONYMS.get(raw, raw)
        if token:
            tokens.append(token)
    return tokens or normalized.split()


def build_token_index(mapping: dict[str, str]) -> dict[str, set[str]]:
    return {key: set(tokenize(name)) for key, name in mapping.items()}


def resolve_alias(alias: str, mapping: dict[str, str]) -> str | None:
    alias_norm = normalize(alias)
    return mapping.get(alias_norm)


def resolve_label(label: str, mapping: dict[str, str], alias_map: dict[str, str], token_index: dict[str, set[str]]) -> str | None:
    norm = normalize(label)
    if alias := alias_map.get(norm):
        resolved = resolve_alias(alias, mapping)
        if resolved:
            return resolved
    if norm in mapping:
        return mapping[norm]
    tokens = tokenize(label)
    if not tokens:
        return None
    for span in range(1, min(3, len(tokens)) + 1):
        tail = " ".join(tokens[-span:])
        if tail in mapping:
            return mapping[tail]
    token_set = set(tokens)
    best_name = None
    best_score = 0.0
    for key, canon_tokens in token_index.items():
        intersection = canon_tokens & token_set
        if not intersection:
            continue
        score_label = len(intersection) / len(token_set)
        score_canon = len(intersection) / max(len(canon_tokens), 1)
        combined = 0.7 * score_label + 0.3 * score_canon
        if combined > best_score:
            best_score = combined
            best_name = mapping[key]
    if best_score >= 0.6:
        return best_name
    return None


def canonicalize(classes: Sequence[str], mapping: dict[str, str], alias_map: dict[str, str]) -> Tuple[list[str], list[str]]:
    token_index = build_token_index(mapping)
    resolved: list[str] = []
    skipped: list[str] = []
    for label in classes:
        canonical = resolve_label(label, mapping, alias_map, token_index)
        if canonical:
            resolved.append(canonical)
        else:
            skipped.append(label)
    return resolved, skipped


def dedupe_preserve_order(items: Sequence[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for entry in items:
        if entry not in seen:
            seen.add(entry)
            ordered.append(entry)
    return ordered


def main() -> int:
    args = parse_args()
    classes = [c.strip() for c in args.classes_file.read_text().splitlines() if c.strip()]
    if args.count is not None:
        classes = classes[args.start : args.start + args.count]
    else:
        classes = classes[args.start :]
    if not classes:
        print("No classes to download", file=sys.stderr)
        return 0

    mapping = load_oid_classes(args.class_map)
    if not mapping:
        print(f"Warning: missing class map at {args.class_map}", file=sys.stderr)
    alias_map = load_alias_map(args.alias_map)
    if mapping:
        canonical, skipped = canonicalize(classes, mapping, alias_map)
        canonical = dedupe_preserve_order(canonical)
        if skipped:
            skipped_path = args.skipped_log or (args.dataset_dir / "openimages_skipped.txt")
            skipped_path.parent.mkdir(parents=True, exist_ok=True)
            skipped_path.write_text("\n".join(skipped) + "\n")
            preview = ", ".join(skipped[:5])
            print(f"Skipped {len(skipped)} classes (logged to {skipped_path}): {preview}", file=sys.stderr)
    else:
        canonical = classes
    if not canonical:
        print("No classes resolved against Open Images", file=sys.stderr)
        return 1

    python = sys.executable
    dataset_arg = str(args.dataset_dir.resolve())
    for idx, batch in enumerate(chunked(canonical, args.chunk_size), 1):
        print(f"\n[Batch {idx}] downloading {len(batch)} classes: {batch}")
        cmd = [
            python,
            str(TOOLKIT / "main.py"),
            "downloader",
            "--Dataset",
            dataset_arg,
            "--type_csv",
            args.split,
            "--limit",
            str(args.max_images),
            "--n_threads",
            str(args.threads),
        ]
        if args.no_labels:
            cmd.append("--noLabels")
        if args.auto_yes:
            cmd.append("--yes")
        cmd.append("--classes")
        cmd.extend(batch)
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            print(f"Batch {idx} failed with {exc.returncode}", file=sys.stderr)
            return exc.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
