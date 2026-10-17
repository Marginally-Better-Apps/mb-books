"""Pocket TTS's FlowLM as a stateful Core ML model.

Two functions share one KV cache state and one copy of the weights:

- `prefill(token_ids, position)`: runs PREFILL text tokens through the transformer, writing their keys and values,
  and returns the BOS latent that starts generation. Shorter text is padded; the padding lands past the real
  tokens, and generation overwrites it.
- `generate(latent, noise, position)`: one audio frame. Runs the previous latent (or the BOS latent) through the
  transformer, then the flow head's single LSD step, returning the next latent and the end-of-speech logit.

Every input has a fixed shape, so Core ML plans each function once rather than per call. (Flexible shapes
re-planned every frame on the GPU, and enumerated ones computed wrong results on the CPU.) Voices are
precomputed caches the app writes into the state directly, so the model never sees audio.
"""

import math

import torch
from torch import nn
from torch.nn import functional as F

LAYERS = 6
HEADS = 16
HEAD_DIM = 64
# Text tokens per prefill call; shorter text is padded.
PREFILL = 64
D_MODEL = 1024
LATENT = 32


def rope_tables(length: int, max_period: float) -> tuple[torch.Tensor, torch.Tensor]:
    """Cosines and sines of Kyutai's rotary embedding for every cache position, [length, HEAD_DIM / 2]."""
    freqs = torch.exp(torch.arange(HEAD_DIM // 2, dtype=torch.float64) * (-math.log(max_period) * 2 / HEAD_DIM))
    angles = torch.arange(length, dtype=torch.float64)[:, None] * freqs[None, :]
    return torch.cos(angles).float(), torch.sin(angles).float()


def rope(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    """Rotates interleaved pairs of `x` ([1, T, HEADS, HEAD_DIM]) by the tables' rows for its positions."""
    pairs = x.reshape(1, -1, HEADS, HEAD_DIM // 2, 2)
    real, imaginary = pairs[..., 0], pairs[..., 1]
    rotated = torch.stack([real * cos - imaginary * sin, real * sin + imaginary * cos], dim=-1)
    return rotated.reshape(1, -1, HEADS, HEAD_DIM)


class StatefulFlowLM(nn.Module):
    def __init__(self, flow_lm, cache_length: int):
        super().__init__()
        self.flow_lm = flow_lm
        self.length = cache_length
        cos, sin = rope_tables(cache_length, flow_lm.transformer.layers[0].self_attn.rope.max_period)
        self.register_buffer("rope_cos", cos)
        self.register_buffer("rope_sin", sin)
        shape = (LAYERS, 1, HEADS, cache_length, HEAD_DIM)
        self.register_buffer("k_cache", torch.zeros(shape, dtype=torch.float16))
        self.register_buffer("v_cache", torch.zeros(shape, dtype=torch.float16))

    def transformer(self, x: torch.Tensor, position: torch.Tensor, t: int) -> torch.Tensor:
        """Runs `x` ([1, t, D_MODEL]) at cache positions `position` ..< `position` + t."""
        length = self.length
        # Positions become one-hot rows, and every read and write of the cache and the rotary tables is a matrix
        # product with them, so no shape depends on the position.
        rows = position.view(1, 1).to(torch.float32) + torch.arange(t, dtype=torch.float32).view(t, 1)
        slots = torch.arange(length, dtype=torch.float32).view(1, length)
        one_hot = (slots == rows).to(torch.float32)  # [t, L]
        written = one_hot.sum(dim=0).view(1, 1, length, 1)
        mask = torch.where(slots <= rows, 0.0, float("-inf")).view(1, 1, t, length)
        cos = torch.matmul(one_hot, self.rope_cos).view(t, 1, HEAD_DIM // 2)
        sin = torch.matmul(one_hot, self.rope_sin).view(t, 1, HEAD_DIM // 2)
        scatter = one_hot.transpose(0, 1)  # [L, t]
        for index, layer in enumerate(self.flow_lm.transformer.layers):
            attn = layer.self_attn
            h = layer.norm1(x)
            q, k, v = attn.in_proj(h).reshape(1, t, 3, HEADS, HEAD_DIM).unbind(dim=2)
            q = rope(q, cos, sin).transpose(1, 2)
            k = rope(k, cos, sin).transpose(1, 2)
            v = v.transpose(1, 2)
            keys = self.k_cache[index].to(torch.float32) * (1 - written) + torch.matmul(scatter, k)
            values = self.v_cache[index].to(torch.float32) * (1 - written) + torch.matmul(scatter, v)
            self.k_cache[index : index + 1] = keys.to(torch.float16).unsqueeze(0)
            self.v_cache[index : index + 1] = values.to(torch.float16).unsqueeze(0)
            out = F.scaled_dot_product_attention(q, keys, values, attn_mask=mask)
            out = attn.out_proj(out.transpose(1, 2).reshape(1, t, D_MODEL))
            x = x + layer.layer_scale_1(out)
            x = layer._ff_block(x)
        return self.flow_lm.out_norm(x)


class Prefill(nn.Module):
    def __init__(self, core: StatefulFlowLM):
        super().__init__()
        # Registered first so Core ML names the states `k_cache` and `v_cache`.
        self.register_buffer("k_cache", core.k_cache)
        self.register_buffer("v_cache", core.v_cache)
        self.core = core

    def forward(self, token_ids: torch.Tensor, position: torch.Tensor) -> torch.Tensor:
        embeddings = self.core.flow_lm.conditioner.embed(token_ids)
        out = self.core.transformer(embeddings, position, PREFILL)
        # The BOS latent that starts generation, tied to the graph so it isn't folded into a bare constant.
        return self.core.flow_lm.bos_emb.view(1, 1, LATENT) + 0 * out[:, -1:, :1]


class Generate(nn.Module):
    def __init__(self, core: StatefulFlowLM):
        super().__init__()
        # Registered first so Core ML names the states `k_cache` and `v_cache`.
        self.register_buffer("k_cache", core.k_cache)
        self.register_buffer("v_cache", core.v_cache)
        self.core = core

    def forward(self, latent: torch.Tensor, noise: torch.Tensor, position: torch.Tensor):
        flow_lm = self.core.flow_lm
        x = flow_lm.input_linear(latent)
        hidden = self.core.transformer(x, position, 1)[:, -1]
        eos_logit = flow_lm.out_eos(hidden)
        # One LSD step from s=0 to t=1, as the released model is sampled.
        s = torch.zeros_like(noise[..., :1])
        t = torch.ones_like(noise[..., :1])
        next_latent = noise + flow_lm.flow_net(hidden, s, t, noise)
        return next_latent, eos_logit
