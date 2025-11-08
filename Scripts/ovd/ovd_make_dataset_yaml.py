#!/usr/bin/env python3
import argparse
from pathlib import Path

TEMPLATE = """
path: {root}
train: images  # all images under images/
val: images    # (optionally split later)
names:
{names}
"""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='ovd-data')
    ap.add_argument('--name', default='ovdset')
    ap.add_argument('--out', default='ovd-data/ovdset.yaml')
    args = ap.parse_args()

    root = Path(args.root)
    classes_txt = (root / 'classes.txt').read_text(encoding='utf-8').splitlines()
    names = ''.join([f"  {i}: {n}\n" for i, n in enumerate(classes_txt)])
    Path(args.out).write_text(TEMPLATE.format(root=str(root.resolve()), names=names))
    print(f"Wrote dataset yaml → {args.out}")

if __name__ == '__main__':
    main()

