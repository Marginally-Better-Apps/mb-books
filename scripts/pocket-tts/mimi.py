"""Pocket TTS's Mimi decoder as a streaming Core ML model: one latent frame in, 1920 samples (80 ms) out.

Every piece of streaming state is an explicit fp32 input with a matching `new_` output, which the app feeds
back on the next frame. A fresh utterance starts from zeros. Inputs keep fixed shapes, so the plan is built
once. The transformer keeps a sliding window of the last WINDOW positions, which covers its 250-step context.
"""

import math

import torch
from torch import nn
from torch.nn import functional as F

from pocket_tts.modules.conv import StreamingConv1d, StreamingConvTranspose1d
from pocket_tts.modules.seanet import SEANetResnetBlock

LATENT = 32
STEPS = 16  # transformer steps per latent frame (200 Hz against 12.5 Hz)
WINDOW = 256
HEADS = 8
HEAD_DIM = 64


# State lengths come from the modules, not tensor shapes, so they trace as constants.
def conv_step(conv: StreamingConv1d, x: torch.Tensor, previous: torch.Tensor):
    kept = conv._effective_kernel_size - conv._stride
    x = torch.cat([previous, x], dim=-1)
    return conv.conv(x), x[..., -kept:]


def convtr_step(conv: StreamingConvTranspose1d, x: torch.Tensor, partial: torch.Tensor):
    y = conv.convtr(x)
    overlap = conv._kernel_size - conv._stride
    head = y[..., :overlap] + partial
    tail = y[..., -overlap:]
    if conv.convtr.bias is not None:
        tail = tail - conv.convtr.bias[:, None]
    return torch.cat([head, y[..., overlap:-overlap]], dim=-1), tail


class MimiDecoderStep(nn.Module):
    def __init__(self, mimi, emb_mean: torch.Tensor, emb_std: torch.Tensor):
        super().__init__()
        self.mimi = mimi
        self.register_buffer("emb_mean", emb_mean.clone())
        self.register_buffer("emb_std", emb_std.clone())
        self.layers = mimi.decoder_transformer.transformer.layers
        self.context = self.layers[0].self_attn.context
        period = self.layers[0].self_attn.rope.max_period
        self.register_buffer(
            "freqs", torch.exp(torch.arange(HEAD_DIM // 2, dtype=torch.float32) * (-math.log(period) * 2 / HEAD_DIM))
        )
        # The decoder's streaming layers in order; ELUs between them have no state.
        self.convs = [m for m in mimi.decoder.model if isinstance(m, (StreamingConv1d, StreamingConvTranspose1d, SEANetResnetBlock))]

    def state_shapes(self) -> list[tuple[str, tuple[int, ...]]]:
        shapes = [("upsample", (1, 512, self.mimi.upsample.convtr._kernel_size - self.mimi.upsample.convtr._stride))]
        for index in range(len(self.layers)):
            shapes += [(f"keys{index}", (1, HEADS, WINDOW, HEAD_DIM)), (f"values{index}", (1, HEADS, WINDOW, HEAD_DIM))]
        for index, module in enumerate(self.convs):
            if isinstance(module, StreamingConvTranspose1d):
                shapes.append((f"conv{index}", (1, module.convtr.out_channels, module._kernel_size - module._stride)))
            elif isinstance(module, StreamingConv1d):
                shapes.append((f"conv{index}", (1, module.conv.in_channels, module._effective_kernel_size - module._stride)))
            else:
                first = module.block[1]
                shapes.append((f"conv{index}", (1, first.conv.in_channels, first._effective_kernel_size - first._stride)))
        return shapes

    def rope(self, x: torch.Tensor, positions: torch.Tensor) -> torch.Tensor:
        # x: [1, HEADS, STEPS, HEAD_DIM]
        angles = positions.view(STEPS, 1) * self.freqs.view(1, -1)
        cos, sin = torch.cos(angles), torch.sin(angles)
        pairs = x.reshape(1, HEADS, STEPS, HEAD_DIM // 2, 2)
        real, imaginary = pairs[..., 0], pairs[..., 1]
        return torch.stack([real * cos - imaginary * sin, real * sin + imaginary * cos], dim=-1).reshape(
            1, HEADS, STEPS, HEAD_DIM
        )

    def forward(self, latent: torch.Tensor, frame: torch.Tensor, *states: torch.Tensor):
        states = list(states)
        new_states = []
        x = latent.view(1, LATENT, 1) * self.emb_std.view(1, -1, 1) + self.emb_mean.view(1, -1, 1)
        x = self.mimi.quantizer(x)
        x, partial = convtr_step(self.mimi.upsample.convtr, x, states.pop(0))
        new_states.append(partial)

        # Transformer over STEPS new positions, attending to the window before them.
        start = frame.to(torch.float32) * STEPS
        query_positions = start + torch.arange(STEPS, dtype=torch.float32)
        key_positions = start - WINDOW + torch.arange(WINDOW + STEPS, dtype=torch.float32)
        delta = query_positions.view(STEPS, 1) - key_positions.view(1, -1)
        allowed = (key_positions.view(1, -1) >= 0) & (delta >= 0) & (delta < self.context)
        mask = torch.where(allowed, 0.0, float("-inf")).view(1, 1, STEPS, WINDOW + STEPS)
        h = x.transpose(1, 2)  # [1, STEPS, 512]
        for layer in self.layers:
            attn = layer.self_attn
            past_keys, past_values = states.pop(0), states.pop(0)
            y = layer.norm1(h)
            q, k, v = attn.in_proj(y).reshape(1, STEPS, 3, HEADS, HEAD_DIM).unbind(dim=2)
            q = self.rope(q.transpose(1, 2), query_positions)
            k = self.rope(k.transpose(1, 2), query_positions)
            v = v.transpose(1, 2)
            keys = torch.cat([past_keys, k], dim=2)
            values = torch.cat([past_values, v], dim=2)
            out = F.scaled_dot_product_attention(q, keys, values, attn_mask=mask)
            out = attn.out_proj(out.transpose(1, 2).reshape(1, STEPS, HEADS * HEAD_DIM))
            h = h + layer.layer_scale_1(out)
            h = layer._ff_block(h)
            new_states += [keys[:, :, STEPS:], values[:, :, STEPS:]]
        x = h.transpose(1, 2)

        for module in self.mimi.decoder.model:
            if isinstance(module, StreamingConvTranspose1d):
                x, state = convtr_step(module, x, states.pop(0))
                new_states.append(state)
            elif isinstance(module, StreamingConv1d):
                x, state = conv_step(module, x, states.pop(0))
                new_states.append(state)
            elif isinstance(module, SEANetResnetBlock):
                residual = x
                v = module.block[0](x)
                v, state = conv_step(module.block[1], v, states.pop(0))
                new_states.append(state)
                v = module.block[2](v)
                v = module.block[3].conv(v)  # kernel 1: no state
                x = residual + v
            else:
                x = module(x)
        return (x.view(1, -1), *new_states)
