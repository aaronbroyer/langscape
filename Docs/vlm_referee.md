MobileVLM Referee (Optional)

The app can use a small multimodal VLM (e.g., MobileVLM) as a selective referee to verify mid‑confidence YOLO detections. This boosts precision without running a heavy model on every box.

How it works
- For detections with confidence in [0.30, 0.70], the referee crops the box to 224×224 and prompts: “Is this a <label>? Answer yes or no.”
- If the model returns ≥0.70 “yes” score, the detection is kept (and confidence may be raised). Otherwise it is filtered out.

Getting started
1) Obtain a Core ML package for MobileVLM, INT8‑quantized if possible (name it one of: `MobileVLMInt8.mlpackage`, `MobileVLM.mlpackage`, or `VLMReferee.mlpackage`).
2) Drop the package into `DetectionKit/Sources/DetectionKit/Resources/`.
3) Build and run. You should see a log line: “Loaded VLM referee: <name>.mlpackage”.

Notes
- Input size is 224 by default to keep inference fast. You can change it inside `VLMReferee(cropSize:)` if you ship a different input resolution.
- The model must accept an image input and a text input, and return either a scalar probability or a string→probability dictionary containing a `"yes"` key.
- The referee runs only when a matching model is found; otherwise the pipeline proceeds without it.

