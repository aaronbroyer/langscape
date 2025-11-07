#!/usr/bin/env python3
"""
Export MarianMT (Helsinki-NLP/opus-mt-en-es) to a CoreML package for on-device noun translation.

This script provides a guided path and reference code for conversion. Exporting
encoder–decoder transformers to CoreML is non-trivial and may require adapting
to current coremltools capabilities. Treat this as a starting point and test
carefully on device.

High-level plan
1) Download model + tokenizer from Hugging Face.
2) Export encoder and decoder to CoreML (MLProgram) using coremltools.
3) Wrap generation (tokenization + autoregressive decode) in a small Swift layer
   or assemble a CoreML pipeline if you have a graph that implements greedy
   decoding.
4) Save as a compiled `.mlpackage`, and set input/output string features
   (`src_text` / `tgt_text`) if you wrap tokenization inside the model. If not,
   expose token ids and do pre/post in Swift.

Practical options
- Easiest path: keep tokenization and decoding loop in Swift; export only
  encoder/decoder blocks as CoreML models operating on token ids.
- If you need a single string-in/string-out model, you must embed tokenizer and
  generation into the CoreML graph (advanced; out-of-scope for a short script).

Dependencies
  pip install coremltools==7.2 transformers tokenizers torch

Usage
  python Scripts/convert_marianmt_to_coreml.py --repo-id Helsinki-NLP/opus-mt-en-es \
         --out LLMKit/Resources/marian_en_es.mlpackage

"""
import argparse
from pathlib import Path

import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
import coremltools as ct


def load_model_and_tokenizer(repo_id: str):
    tokenizer = AutoTokenizer.from_pretrained(repo_id)
    model = AutoModelForSeq2SeqLM.from_pretrained(repo_id, torch_dtype=torch.float32)
    model.eval()
    return model, tokenizer


def export_encoder_decoder_to_coreml(model, tokenizer, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)

    # TorchScript stubs for encoder and decoder. We expose token id tensors.
    class EncoderWrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
        def forward(self, input_ids, attention_mask):
            enc = self.m.get_encoder()(input_ids=input_ids, attention_mask=attention_mask)
            return enc.last_hidden_state

    class DecoderWrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
        def forward(self, decoder_input_ids, encoder_hidden_states, encoder_attention_mask):
            out = self.m.get_decoder()(input_ids=decoder_input_ids,
                                       encoder_hidden_states=encoder_hidden_states,
                                       encoder_attention_mask=encoder_attention_mask)
            return out.last_hidden_state

    # Dummy inputs for tracing
    max_len = 32
    input_ids = torch.ones(1, max_len, dtype=torch.long)
    attn_mask = torch.ones(1, max_len, dtype=torch.long)
    dec_ids = torch.ones(1, 1, dtype=torch.long)

    enc_ts = torch.jit.trace(EncoderWrapper(model), (input_ids, attn_mask))
    dec_ts = torch.jit.trace(DecoderWrapper(model), (dec_ids, enc_ts(input_ids, attn_mask), attn_mask))

    # Convert to CoreML (MLProgram)
    enc_ml = ct.convert(
        enc_ts,
        convert_to='mlprogram',
        inputs=[
            ct.TensorType(name='input_ids', shape=input_ids.shape, dtype=int),
            ct.TensorType(name='attention_mask', shape=attn_mask.shape, dtype=int),
        ],
        outputs=[ct.TensorType(name='encoder_hidden_states')],
        minimum_deployment_target=ct.target.iOS17,
    )
    dec_ml = ct.convert(
        dec_ts,
        convert_to='mlprogram',
        inputs=[
            ct.TensorType(name='decoder_input_ids', shape=dec_ids.shape, dtype=int),
            ct.TensorType(name='encoder_hidden_states', shape=(1, max_len, model.config.d_model)),
            ct.TensorType(name='encoder_attention_mask', shape=attn_mask.shape, dtype=int),
        ],
        outputs=[ct.TensorType(name='decoder_hidden_states')],
        minimum_deployment_target=ct.target.iOS17,
    )

    enc_path = out_dir / 'marian_encoder.mlpackage'
    dec_path = out_dir / 'marian_decoder.mlpackage'
    enc_ml.save(enc_path)
    dec_ml.save(dec_path)

    print(f"Saved encoder to {enc_path}")
    print(f"Saved decoder to {dec_path}")
    print("NOTE: You'll implement tokenization + generation loop in Swift, using these models.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo-id', default='Helsinki-NLP/opus-mt-en-es')
    ap.add_argument('--out', default='LLMKit/Resources/marian_en_es')
    args = ap.parse_args()

    out_dir = Path(args.out)
    model, tok = load_model_and_tokenizer(args.repo_id)
    export_encoder_decoder_to_coreml(model, tok, out_dir)


if __name__ == '__main__':
    main()

