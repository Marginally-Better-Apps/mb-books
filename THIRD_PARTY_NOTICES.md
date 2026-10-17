# Third-party notices

MB Books' listening feature uses the components below. Everything runs on the device; the voice models and
voices are downloaded once, from pinned URLs, and verified by SHA-256 before use.

| Component | Use | License | Where it comes from |
| --- | --- | --- | --- |
| [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) (english_2026-09) by Kyutai | Natural voice model, converted to Core ML by `scripts/pocket-tts/convert.py` (transformer weights quantized to 8 bits) | CC BY 4.0 | Downloaded on request |
| Pocket TTS tokenizer by Kyutai | Turns text into the model's tokens | CC BY 4.0 | Bundled (`Books/Resources/Speech/pocket-tokenizer.json`) |
| [Kyutai TTS voices](https://huggingface.co/kyutai/tts-voices) by Kyutai | Voice prompts, precomputed for Pocket TTS; bundled samples rendered with them | CC0 and CC BY 4.0, per voice below | Downloaded on request; samples bundled |
| [CSTR VCTK Corpus](https://datashare.ed.ac.uk/handle/10283/3443) by the Centre for Speech Technology Research, University of Edinburgh (Veaux, Yamagishi, MacDonald) | Recordings behind the voices Anna, Azelma, Charles, Eponine, Eve, Fantine, George, Jane, Mary, Michael, Paul, and Vera | CC BY 4.0 | Via Kyutai TTS voices |
| Alba MacKenna's recordings | The voice Alba | CC BY 4.0 | Via Kyutai TTS voices |
| [Voice-Zero](https://github.com/OwenTyme/voice-zero) (LibriVox narrators Bill Boerst, Caro Davy, Peter Yearsley, Stuart Bell) | The voices Bill, Caro, Peter, and Stuart | CC0 | Via Kyutai TTS voices |

Voices from non-commercial datasets (Expresso and EARS) are not used. No GPL components are used; natural voices
are English only.

The Pocket TTS model files were modified from Kyutai's release: converted to Core ML, with the transformer's
weights quantized to 8 bits and its sampling loop restructured for Core ML. The voices are Kyutai's precomputed
voice states, stored in half precision.

## Creative Commons Attribution 4.0 International (CC BY 4.0)

Applies to Pocket TTS, its tokenizer, and the voices from VCTK and Alba MacKenna.
Full legal code: https://creativecommons.org/licenses/by/4.0/legalcode

You are free to share and adapt the material for any purpose, even commercially, provided you give appropriate
credit, provide a link to the license, and indicate if changes were made.

## Creative Commons Zero (CC0 1.0)

Applies to the Voice-Zero voices. Legal code: https://creativecommons.org/publicdomain/zero/1.0/legalcode
