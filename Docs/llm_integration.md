# LLM/MT Integration Guide

This guide captures concrete choices and steps to add an on‑device translation model to Langscape’s `LLMKit` while staying within the MVP constraints (offline, fast, ≤500MB total).

## Recommendation
- Use MarianMT checkpoints from Hugging Face:
  - EN→ES: `Helsinki-NLP/opus-mt-en-es`
  - ES→EN: `Helsinki-NLP/opus-mt-es-en`
- Reason: small, accurate for short phrases, and easier to deploy than a general LLM.

## Two viable integration paths

- Practical (recommended for MVP)
  - Export encoder and decoder to CoreML (MLProgram).
  - Keep tokenization + greedy decode loop in Swift.
  - Pros: small, fast, predictable; easier to debug.
  - Cons: Not a single string-in/string-out CoreML model.

- Advanced (string I/O model)
  - Build a CoreML pipeline that includes tokenization and generation.
  - This yields a model that accepts `src_text` and returns `tgt_text` and plugs directly into `LLMService`.
  - Cons: more engineering; requires careful graph authoring and testing.

## What’s already in the repo
- `LLMKit/Resources/model-manifest.json`: template manifest for a single EN→ES model. `LLMService` will load it and route translation requests through the CoreML model if present.
- `LLMKit/Sources/LLMKit/LLMService.swift`: manifest loading bug fixed to accept a Foundation JSON object.
- `Scripts/convert_marianmt_to_coreml.py`: example exporter that saves encoder/decoder models for `Helsinki-NLP/opus-mt-en-es`.

## Steps (Practical path)
1. Run the exporter
   - `python Scripts/convert_marianmt_to_coreml.py --repo-id Helsinki-NLP/opus-mt-en-es --out LLMKit/Resources/marian_en_es`
   - This saves `marian_encoder.mlpackage` and `marian_decoder.mlpackage` in the resources folder.
2. Add a small Swift translator that orchestrates tokenization and decoding using those two models (string in/out at the Swift layer). You can either:
   - Add a new `EncoderDecoderTranslator` in `LLMKit` and inject it into `LLMService`, or
   - Temporarily bypass `LLMService` for testing.
3. If you choose this path, you can ignore `model-manifest.json` until you later assemble a single pipeline.

## Steps (Advanced string I/O model)
1. Create a CoreML pipeline model that encapsulates:
   - Text tokenization → `input_ids`, `attention_mask`
   - Encoder forward pass
   - Autoregressive loop (greedy) over the decoder to produce tokens
   - Detokenization to a final string output
2. Save the pipeline as `marian_en_es.mlpackage` and ensure the model exposes a single string input and output.
3. Update `LLMKit/Resources/model-manifest.json` fields:
   - `modelFile`: `marian_en_es.mlpackage`
   - `inputFeature`: `src_text`
   - `outputFeature`: `tgt_text`
   - `source`: `english`
   - `target`: `spanish`
4. Build and run. `LLMService` will detect the manifest, load the model, and use it automatically.

## ES→EN support
- To support both directions today, ship one manifest at a time (the code loads a single manifest). For bi‑directional support, extend `LLMService` to load multiple manifests and pick the one matching the requested `(source,target)` pair.

## General LLM option (future)
- For macOS dev: use Ollama with `phi3.1:3.8b-instruct` or `qwen2.5:3b-instruct`.
- For iOS embed: use MLC LLM with a 1–2B model in 4‑bit if you truly need general generation. Expect quality compromises and tighter size budgets.

## Size and performance notes
- MarianMT (tiny) models are typically ~100–300MB when converted; quantization can help.
- Keep the end‑to‑end round trip under tens of milliseconds for short inputs.

## Testing
- Unit-test tokenization + generation determinism for a few known noun pairs.
- In UI tests, validate labels appear with correct articles for a stable set of YOLO classes.

