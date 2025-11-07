Langscape LLMKit – CoreML Translator Manifest

This package looks for `model-manifest.json` in its resources at runtime and, when present, loads a CoreML translation model for English→Spanish noun translation.

Manifest schema
- `modelFile` (string): Filename of the compiled CoreML model in this bundle. Use `.mlpackage` or `.mlmodelc` (not raw `.mlmodel`).
- `inputFeature` (string): Name of the model's string input feature (e.g., `src_text`).
- `outputFeature` (string): Name of the model's string output feature (e.g., `tgt_text`).
- `source` ("english"|"spanish"): Source language the model supports.
- `target` ("english"|"spanish"): Target language the model supports.

Example (bundled):
{
  "modelFile": "marian_en_es.mlpackage",
  "inputFeature": "src_text",
  "outputFeature": "tgt_text",
  "source": "english",
  "target": "spanish"
}

Notes
- Only a single manifest is loaded (`model-manifest.json`). If you want ES→EN as well, ship a second build that swaps the manifest, or extend `LLMService` to scan multiple manifests.
- If the manifest/model is missing, `LLMService` falls back to a deterministic formatter (e.g., `el/la <noun>`), and LabelEngine will prefer VocabStore entries when available.

