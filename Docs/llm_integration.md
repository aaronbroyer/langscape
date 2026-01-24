# LLM/MT Integration Guide

This guide captures concrete choices and steps to add an on‑device translation model to Langscape’s `LLMKit` while staying within the MVP constraints (offline, fast, ≤500MB total).

## Recommendation
- Use MarianMT checkpoints from Hugging Face (Opus‑MT):
  - EN→ES: `Helsinki-NLP/opus-mt-en-es`
  - ES→EN: `Helsinki-NLP/opus-mt-es-en`
- Reason: small, accurate for short phrases, and easier to deploy than a general LLM.

## Two viable integration paths

- Practical (recommended for MVP)
  - Export encoder and decoder (with logits) to CoreML (MLProgram).
  - Keep tokenization + greedy decode loop in Swift.
  - Pros: small, fast, predictable; easier to debug.
  - Cons: Not a single string-in/string-out CoreML model.

- Advanced (string I/O model)
  - Build a CoreML pipeline that includes tokenization and generation.
  - This yields a model that accepts `src_text` and returns `tgt_text` and plugs directly into `LLMService`.
  - Cons: more engineering; requires careful graph authoring and testing.

## What’s already in the repo
- `LLMKit/Sources/LLMKit/Resources/model-manifest.json`: manifest listing one or more translation models. `LLMService` loads entries and routes requests to matching CoreML models when present.
- `LLMKit/Sources/LLMKit/LLMService.swift`: manifest loading bug fixed to accept a Foundation JSON object.
- `Scripts/convert_marianmt_to_coreml.py`: example exporter that saves encoder/decoder models for `Helsinki-NLP/opus-mt-en-es`.

## Steps (Practical path)
1. Run the exporter
   - `python Scripts/convert_marianmt_to_coreml.py --repo-id Helsinki-NLP/opus-mt-en-es --out LLMKit/Sources/LLMKit/Resources --pair en_es`
   - This saves `marian_en_es_encoder.mlpackage`, `marian_en_es_decoder.mlpackage`, `marian_en_es_source.spm`, `marian_en_es_target.spm`, `marian_en_es_vocab.json` in the resources folder.
2. The Swift `MarianTranslator` uses these files directly and is wired via `model-manifest.json` (include `vocabFile` and the model’s token ids from `config.json`; pad/start values vary by pair).

Notes
- The conversion script expects `coremltools==7.2`, `torch==2.2.2`, `transformers==4.39.3`, and `numpy<2` (see script header).

## Steps (Advanced string I/O model)
1. Create a CoreML pipeline model that encapsulates:
   - Text tokenization → `input_ids`, `attention_mask`
   - Encoder forward pass
   - Autoregressive loop (greedy) over the decoder to produce tokens
   - Detokenization to a final string output
2. Save the pipeline as `marian_en_es.mlpackage` and ensure the model exposes a single string input and output.
3. Update `LLMKit/Sources/LLMKit/Resources/model-manifest.json` fields for each entry:
   - `modelFile`: e.g., `marian_en_es.mlpackage`
   - `inputFeature`: `src_text`
   - `outputFeature`: `tgt_text`
   - `source`: `english`
   - `target`: `spanish`
4. Build and run. `LLMService` will detect the manifest, load the model, and use it automatically.

## ES→EN support
- The manifest now supports multiple entries; add a second model entry for ES→EN (or EN→FR, FR→EN, etc.).

## Remote LLM option (future)
- For macOS dev: use Ollama with `phi3.1:3.8b-instruct` or `qwen2.5:3b-instruct`.
- For iOS embed: use MLC LLM with a 1–2B model in 4‑bit if you truly need general generation. Expect quality compromises and tighter size budgets.
 - If you do want a hosted fallback, set `LLMService(translationPolicy: .localThenRemote)` and provide an API key for the configured `LLMClient`.

## Size and performance notes
- MarianMT (tiny) models are typically ~100–300MB when converted; quantization can help.
- Keep the end‑to‑end round trip under tens of milliseconds for short inputs.

## Testing
- Unit-test tokenization + generation determinism for a few known noun pairs.
- In UI tests, validate labels appear with correct articles for a stable set of YOLO classes.
