#!/usr/bin/env python3
"""Write a tiny random-weight llama model as a .gguf file (needs `pip install gguf numpy`).

It produces nonsense text, but it is a real model that a real Ollama can load
and run. The Docker test imports it with OLLAMA_MODEL_FILE so the whole install
(Ollama service, Open WebUI, the Wikipedia tool) can be tested without pulling
a multi-GB model.

Usage: make_tiny_gguf.py OUTPUT.gguf
"""

import sys

import numpy as np
from gguf import GGUFWriter, TokenType

N_EMBD, N_LAYERS, N_HEAD, N_FF, N_CTX = 64, 2, 4, 128, 4096
WORDS = (
    "the a an is of and to in it that for on with as was by at from this be are or "
    "capacitor energy moon water light wikipedia answer source article stores charge "
    "electric field plants sun earth first person computer offline deck hello yes no"
).split()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "tiny.gguf"
    rng = np.random.default_rng(1234)

    tokens, scores, types = [b"<unk>", b"<s>", b"</s>"], [0.0, 0.0, 0.0], [TokenType.UNKNOWN, TokenType.CONTROL, TokenType.CONTROL]
    for b in range(256):
        tokens.append(f"<0x{b:02X}>".encode())
        scores.append(0.0)
        types.append(TokenType.BYTE)
    for i, w in enumerate(WORDS):
        for piece in (f"▁{w}", w):
            tokens.append(piece.encode())
            scores.append(-float(i))
            types.append(TokenType.NORMAL)
    tokens.append("▁".encode())
    scores.append(-1000.0)
    types.append(TokenType.NORMAL)
    vocab = len(tokens)

    w = GGUFWriter(out, "llama")
    w.add_name("cyberdeck-tiny-test")
    w.add_context_length(N_CTX)
    w.add_embedding_length(N_EMBD)
    w.add_block_count(N_LAYERS)
    w.add_feed_forward_length(N_FF)
    w.add_head_count(N_HEAD)
    w.add_head_count_kv(N_HEAD)
    w.add_layer_norm_rms_eps(1e-5)
    w.add_rope_dimension_count(N_EMBD // N_HEAD)
    w.add_vocab_size(vocab)
    w.add_file_type(0)  # all F32
    w.add_tokenizer_model("llama")
    w.add_token_list(tokens)
    w.add_token_scores(scores)
    w.add_token_types(types)
    w.add_bos_token_id(1)
    w.add_eos_token_id(2)
    w.add_unk_token_id(0)
    w.add_add_bos_token(True)

    def t(name, *shape):
        w.add_tensor(name, (rng.standard_normal(shape) * 0.02).astype(np.float32))

    t("token_embd.weight", vocab, N_EMBD)
    w.add_tensor("output_norm.weight", np.ones(N_EMBD, dtype=np.float32))
    t("output.weight", vocab, N_EMBD)
    for i in range(N_LAYERS):
        w.add_tensor(f"blk.{i}.attn_norm.weight", np.ones(N_EMBD, dtype=np.float32))
        w.add_tensor(f"blk.{i}.ffn_norm.weight", np.ones(N_EMBD, dtype=np.float32))
        for n in ("attn_q", "attn_k", "attn_v", "attn_output"):
            t(f"blk.{i}.{n}.weight", N_EMBD, N_EMBD)
        t(f"blk.{i}.ffn_gate.weight", N_FF, N_EMBD)
        t(f"blk.{i}.ffn_up.weight", N_FF, N_EMBD)
        t(f"blk.{i}.ffn_down.weight", N_EMBD, N_FF)

    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()
    print(f"wrote {out} ({vocab} tokens)")


if __name__ == "__main__":
    main()
