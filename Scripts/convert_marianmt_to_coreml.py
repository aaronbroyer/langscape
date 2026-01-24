#!/usr/bin/env python3
"""
Export MarianMT (Helsinki-NLP/opus-mt-*) to CoreML encoder/decoder packages for on-device noun translation.

This script provides a guided path and reference code for conversion. Exporting
encoder–decoder transformers to CoreML is non-trivial and may require adapting
to current coremltools capabilities. Treat this as a starting point and test
carefully on device.

High-level plan
1) Download model + tokenizer from Hugging Face.
2) Export encoder and decoder (with logits) to CoreML (MLProgram) using coremltools.
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
  pip install coremltools==7.2 "numpy<2" "torch==2.2.2" "transformers==4.39.3" sentencepiece tokenizers

Usage
  python Scripts/convert_marianmt_to_coreml.py --repo-id Helsinki-NLP/opus-mt-en-es \
         --out LLMKit/Sources/LLMKit/Resources --pair en_es

"""
import argparse
import shutil
from pathlib import Path

import torch
import numpy as np
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
import coremltools as ct


def load_model_and_tokenizer(repo_id: str):
    tokenizer = AutoTokenizer.from_pretrained(repo_id)
    model = AutoModelForSeq2SeqLM.from_pretrained(repo_id, torch_dtype=torch.float32)
    model.eval()
    return model, tokenizer


def export_encoder_decoder_to_coreml(model, tokenizer, out_dir: Path, pair: str, max_input: int, max_output: int):
    out_dir.mkdir(parents=True, exist_ok=True)

    # TorchScript stubs for encoder and decoder. We expose token id tensors.
    class EncoderWrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
        def forward(self, input_ids, attention_mask):
            enc = self.m.get_encoder()(input_ids=input_ids, attention_mask=attention_mask)
            return enc.last_hidden_state

    class DecoderWithLMHead(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.decoder = m.get_decoder()
            self.lm_head = m.lm_head
            self.final_logits_bias = m.final_logits_bias

        def forward(self, decoder_input_ids, encoder_hidden_states, encoder_attention_mask):
            out = self.decoder(
                input_ids=decoder_input_ids,
                encoder_hidden_states=encoder_hidden_states,
                encoder_attention_mask=encoder_attention_mask
            )
            hidden = out.last_hidden_state
            logits = self.lm_head(hidden) + self.final_logits_bias
            return logits

    # Dummy inputs for tracing
    input_ids = torch.ones(1, max_input, dtype=torch.long)
    attn_mask = torch.ones(1, max_input, dtype=torch.long)
    dec_ids = torch.ones(1, max_output, dtype=torch.long)

    encoder = EncoderWrapper(model)
    encoder.eval()
    enc_ts = torch.jit.trace(encoder, (input_ids, attn_mask))
    enc_out = enc_ts(input_ids, attn_mask)
    decoder = DecoderWithLMHead(model)
    decoder.eval()
    dec_ts = torch.jit.trace(decoder, (dec_ids, enc_out, attn_mask))

    # Convert to CoreML (MLProgram)
    enc_ml = ct.convert(
        enc_ts,
        convert_to='mlprogram',
        inputs=[
            ct.TensorType(name='input_ids', shape=input_ids.shape, dtype=np.int32),
            ct.TensorType(name='attention_mask', shape=attn_mask.shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name='encoder_hidden_states')],
        minimum_deployment_target=ct.target.iOS17,
    )
    dec_ml = ct.convert(
        dec_ts,
        convert_to='mlprogram',
        inputs=[
            ct.TensorType(name='decoder_input_ids', shape=dec_ids.shape, dtype=np.int32),
            ct.TensorType(name='encoder_hidden_states', shape=(1, max_input, model.config.d_model)),
            ct.TensorType(name='encoder_attention_mask', shape=attn_mask.shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name='logits')],
        minimum_deployment_target=ct.target.iOS17,
    )

    enc_path = out_dir / f'marian_{pair}_encoder.mlpackage'
    dec_path = out_dir / f'marian_{pair}_decoder.mlpackage'
    enc_ml.save(enc_path)
    dec_ml.save(dec_path)

    tokenizer_dir = out_dir / f'marian_{pair}_tokenizer'
    tokenizer_dir.mkdir(parents=True, exist_ok=True)
    tokenizer.save_pretrained(tokenizer_dir)

    source_spm = tokenizer_dir / 'source.spm'
    target_spm = tokenizer_dir / 'target.spm'
    vocab_file = tokenizer_dir / 'vocab.json'
    if source_spm.exists():
        source_spm.rename(out_dir / f'marian_{pair}_source.spm')
    if target_spm.exists():
        target_spm.rename(out_dir / f'marian_{pair}_target.spm')
    if vocab_file.exists():
        vocab_file.rename(out_dir / f'marian_{pair}_vocab.json')

    if tokenizer_dir.exists():
        shutil.rmtree(tokenizer_dir)

    print(f"Saved encoder to {enc_path}")
    print(f"Saved decoder to {dec_path}")
    print("NOTE: You'll implement tokenization + generation loop in Swift, using these models.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo-id', default='Helsinki-NLP/opus-mt-en-es')
    ap.add_argument('--out', default='LLMKit/Sources/LLMKit/Resources')
    ap.add_argument('--pair', default='en_es', help='Pair token for output naming (e.g., en_es)')
    ap.add_argument('--max-input', type=int, default=32)
    ap.add_argument('--max-output', type=int, default=32)
    args = ap.parse_args()

    out_dir = Path(args.out)
    model, tok = load_model_and_tokenizer(args.repo_id)
    export_encoder_decoder_to_coreml(model, tok, out_dir, args.pair, args.max_input, args.max_output)


if __name__ == '__main__':
    main()
