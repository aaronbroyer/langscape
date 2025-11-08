#!/usr/bin/env python3
import argparse
from pathlib import Path
from ultralytics import YOLO

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--weights', required=True)
    ap.add_argument('--imgsz', type=int, default=896)
    ap.add_argument('--out', required=True)
    ap.add_argument('--nms', action='store_true')
    args = ap.parse_args()

    m = YOLO(args.weights)
    print('Exporting to CoreML...')
    m.export(format='coreml', imgsz=args.imgsz, nms=args.nms, half=True, dynamic=False)
    produced = None
    for p in Path('.').glob('*.mlpackage'):
        produced = p
        break
    if produced is None:
        raise SystemExit('No .mlpackage found after export')
    dest = Path(args.out)
    dest.parent.mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.move(str(produced), str(dest))
    print('Saved CoreML →', dest)

if __name__ == '__main__':
    main()

