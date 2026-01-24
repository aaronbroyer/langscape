Langscape LLMKit – CoreML Translator Manifest

This package looks for `model-manifest.json` in its resources at runtime and, when present, loads one or more CoreML translation models for noun translation. The default setup expects Marian (Opus‑MT) encoder/decoder pairs with SentencePiece tokenizers (via `SentencepieceTokenizer`).

Manifest schema
- `models` (array): One entry per supported translation pair.
  - `type` (string): Set to `marian` for Opus‑MT encoder/decoder models.
  - `source` ("english"|"spanish"|"french"): Source language the model supports.
  - `target` ("english"|"spanish"|"french"): Target language the model supports.
  - `encoderModel` (string): CoreML encoder `.mlpackage`/`.mlmodelc` file in this bundle.
  - `decoderModel` (string): CoreML decoder-with-logits `.mlpackage`/`.mlmodelc` file in this bundle.
  - `sourceTokenizer` (string): SentencePiece model for the source language (`.spm`).
  - `targetTokenizer` (string): SentencePiece model for the target language (`.spm`).
  - `vocabFile` (string): Marian vocabulary mapping (`vocab.json`) used to map SentencePiece pieces to model ids.
  - `maxInputTokens` / `maxOutputTokens` (int): Token budgets used by the Swift decoder loop.
  - `decoderStartTokenId` / `eosTokenId` / `padTokenId` (int): Token ids from the Marian config (varies per model).

Example (bundled):
{
  "models": [
    {
      "type": "marian",
      "source": "english",
      "target": "spanish",
      "encoderModel": "marian_en_es_encoder.mlpackage",
      "decoderModel": "marian_en_es_decoder.mlpackage",
      "sourceTokenizer": "marian_en_es_source.spm",
      "targetTokenizer": "marian_en_es_target.spm",
      "vocabFile": "marian_en_es_vocab.json",
      "maxInputTokens": 32,
      "maxOutputTokens": 32,
      "decoderStartTokenId": 59513,
      "eosTokenId": 0,
      "padTokenId": 59513
    }
  ]
}

Notes on token ids
- Marian configs differ by model. For example, EN↔ES uses `pad/decoderStart=65000`, EN↔FR uses `59513`, and ES↔FR uses `74821` (see each model's `config.json`).

Notes
- Only a single manifest file is loaded (`model-manifest.json`), but it can list multiple models.
- If a manifest entry points to a missing model, `LLMService` skips it and continues.
- By default `LLMService` is local-only; if no model is available for a pair it throws `localModelUnavailable`. Callers decide how to handle missing translations.
- Optional: enable remote fallback by constructing `LLMService(translationPolicy: .localThenRemote)` or `.remoteThenLocal`.
