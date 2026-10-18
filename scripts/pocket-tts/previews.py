"""Renders the voice samples bundled with the app, so voices can be heard before the model is downloaded.

    .venv/bin/python scripts/pocket-tts/previews.py --out Books/Resources/Speech/Previews
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

import scipy.io.wavfile
import torch
from pocket_tts import TTSModel

from convert import LANGUAGE, VOICES

TEXT = "Hi, I'm {name}. The quick brown fox jumps over the lazy dog. Shall we begin the next chapter?"


def display_name(voice: str) -> str:
    return voice.split("_")[0].capitalize()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    torch.manual_seed(0)
    model = TTSModel.load_model(language=LANGUAGE)
    for voice in VOICES:
        audio = model.generate_audio(model.get_state_for_audio_prompt(voice), TEXT.format(name=display_name(voice)))
        with tempfile.NamedTemporaryFile(suffix=".wav") as wav:
            scipy.io.wavfile.write(wav.name, model.sample_rate, audio.numpy())
            subprocess.run(
                ["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", wav.name, str(args.out / f"preview-{voice}.m4a")],
                check=True,
            )


if __name__ == "__main__":
    main()
