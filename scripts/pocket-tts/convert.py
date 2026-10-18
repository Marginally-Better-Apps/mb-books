"""Converts Kyutai's Pocket TTS (english_2026-09) to the Core ML models and voice files the app downloads.

    python3.13 -m venv .venv && .venv/bin/pip install "torch==2.7.0" "coremltools==9.0" pocket-tts
    .venv/bin/python scripts/pocket-tts/convert.py --out build/pocket-tts

Weights and voices are CC BY 4.0 (credit Kyutai); voices from non-commercial datasets are left out.
"""

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from pocket_tts import TTSModel

from mimi import LATENT as MIMI_LATENT, MimiDecoderStep
from flowlm import LATENT, PREFILL, Generate, Prefill, StatefulFlowLM

LANGUAGE = "english_2026-09"
# Kyutai's voices licensed for commercial use (CC0 and CC BY 4.0), best first by automatic naturalness score.
# Left out: cosette (Expresso) and jean (EARS) are non-commercial; javert and marius reproduce noisy recordings.
VOICES = [
    "george", "mary", "jane", "eve", "anna", "eponine", "vera", "michael", "fantine", "azelma",
    "bill_boerst", "caro_davy", "peter_yearsley", "alba", "charles", "paul", "stuart_bell",
]
CACHE_LENGTH = 512


def states(core: StatefulFlowLM) -> list:
    return [
        ct.StateType(wrapped_type=ct.TensorType(shape=core.k_cache.shape, dtype=np.float16), name="k_cache"),
        ct.StateType(wrapped_type=ct.TensorType(shape=core.v_cache.shape, dtype=np.float16), name="v_cache"),
    ]


def convert_flowlm(model: TTSModel, out: Path, precision: str) -> None:
    core = StatefulFlowLM(model.flow_lm, CACHE_LENGTH).eval()
    position = torch.tensor([137], dtype=torch.int32)
    with torch.no_grad():
        prefill = torch.jit.trace(Prefill(core).eval(), (torch.zeros(1, PREFILL, dtype=torch.int32), position))
        generate = torch.jit.trace(Generate(core).eval(), (torch.zeros(1, 1, LATENT), torch.zeros(1, LATENT), position))
    states = [
        ct.StateType(wrapped_type=ct.TensorType(shape=core.k_cache.shape, dtype=np.float16), name="k_cache"),
        ct.StateType(wrapped_type=ct.TensorType(shape=core.v_cache.shape, dtype=np.float16), name="v_cache"),
    ]
    common = dict(
        states=states,
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
        skip_model_load=True,
    )
    functions = {
        "prefill": ct.convert(
            prefill,
            inputs=[
                ct.TensorType(name="token_ids", shape=(1, PREFILL), dtype=np.int32),
                ct.TensorType(name="position", shape=(1,), dtype=np.int32),
            ],
            outputs=[ct.TensorType(name="bos_latent", dtype=np.float32)],
            **common,
        ),
        "generate": ct.convert(
            generate,
            inputs=[
                ct.TensorType(name="latent", shape=(1, 1, LATENT), dtype=np.float32),
                ct.TensorType(name="noise", shape=(1, LATENT), dtype=np.float32),
                ct.TensorType(name="position", shape=(1,), dtype=np.int32),
            ],
            outputs=[
                ct.TensorType(name="next_latent", dtype=np.float32),
                ct.TensorType(name="eos_logit", dtype=np.float32),
                ct.TensorType(name="alignment", dtype=np.float32),
            ],
            **common,
        ),
    }
    scratch = out / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    descriptor = ct.utils.MultiFunctionDescriptor()
    for name, function in functions.items():
        if precision == "int8":
            config = ct.optimize.coreml.OptimizationConfig(
                global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel")
            )
            function = ct.optimize.coreml.linear_quantize_weights(function, config)
        function.save(scratch / f"{name}.mlpackage")
        descriptor.add_function(str(scratch / f"{name}.mlpackage"), "main", name)
    # The two functions share their weights in the saved package.
    descriptor.default_function_name = "generate"
    ct.utils.save_multifunction(descriptor, str(out / "FlowLM.mlpackage"))


def convert_mimi(model: TTSModel, out: Path) -> None:
    step = MimiDecoderStep(model.mimi, model.flow_lm.emb_mean, model.flow_lm.emb_std).eval()
    shapes = step.state_shapes()
    example = (torch.zeros(1, 1, MIMI_LATENT), torch.tensor([0], dtype=torch.int32), *[torch.zeros(s) for _, s in shapes])
    with torch.no_grad():
        traced = torch.jit.trace(step, example)
    mimi_ml = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="latent", shape=(1, 1, MIMI_LATENT), dtype=np.float32),
            ct.TensorType(name="frame", shape=(1,), dtype=np.int32),
            *[ct.TensorType(name=name, shape=shape, dtype=np.float32) for name, shape in shapes],
        ],
        outputs=[ct.TensorType(name="audio", dtype=np.float32)]
        + [ct.TensorType(name=f"new_{name}", dtype=np.float32) for name, _ in shapes],
        minimum_deployment_target=ct.target.iOS18,
        # Streaming state feeds back every frame; fp16 lets errors compound into audible artifacts.
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
        skip_model_load=True,
    )
    mimi_ml.save(out / "Mimi.mlpackage")


def export_voices(model: TTSModel, out: Path) -> None:
    """Each voice is the FlowLM cache after its audio prompt: a little-endian UInt32 length, then fp16 keys and
    values per layer, each [HEADS, length, HEAD_DIM], the layout of the app's cache state."""
    folder = out / "voices"
    folder.mkdir(parents=True, exist_ok=True)
    for name in VOICES:
        state = model.get_state_for_audio_prompt(name)
        length = int(state["transformer.layers.0.self_attn"]["offset"][0])
        data = bytearray(np.uint32(length).tobytes())
        for layer in range(len(model.flow_lm.transformer.layers)):
            cache = state[f"transformer.layers.{layer}.self_attn"]["cache"][:, 0, :length]  # [2, length, H, D]
            for kv in cache:
                data += kv.permute(1, 0, 2).contiguous().numpy().astype("<f2").tobytes()
        (folder / f"{name}.bin").write_bytes(bytes(data))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--precision", choices=["fp16", "int8"], default="int8")
    parser.add_argument("--only", choices=["flowlm", "mimi", "voices"])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    model = TTSModel.load_model(language=LANGUAGE)
    if args.only in (None, "flowlm"):
        convert_flowlm(model, args.out, args.precision)
    if args.only in (None, "mimi"):
        convert_mimi(model, args.out)
    if args.only in (None, "voices"):
        export_voices(model, args.out)


if __name__ == "__main__":
    main()
