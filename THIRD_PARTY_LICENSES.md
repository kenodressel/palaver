# Third-party models

Palaver's releases carry no model. The speech engine and the other models are
downloaded from their own pages, as the setup assistant says. Libraries in
Palaver's runtime keep their own license files inside it
(`lib/python3.13/site-packages/*.dist-info`), and the vendored
echo-cancellation code is listed in
[`palaver/_vendored/webrtc_aec/THIRD_PARTY.md`](palaver/_vendored/webrtc_aec/THIRD_PARTY.md).

## In the app

### FluidAudio

`palaver-engine`, the Swift helper in Palaver.app that transcribes and finds
speakers, is built with [FluidAudio](https://github.com/FluidInference/FluidAudio)
0.18.2 (Fluid Inference), licensed under the
[Apache License 2.0](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE).
Its own third-party components keep their licenses
(NemoTextProcessing, fastcluster and VBx among them: see its
`ThirdPartyLicenses` folder).

## Downloaded from their own pages

| Model | Used for | Source | License |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (Core ML) | transcription, by the engine | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), converted from [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (NVIDIA) | CC-BY-4.0 |
| Speaker diarization (Core ML) | who spoke when, by the engine | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), converted from [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) (pyannote; WeSpeaker embeddings, VBx clustering) | CC-BY-4.0 for the Community-1 artifacts, as the repository's [NOTICE.md](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md) scopes it |
| Gemma 4 12B (MLX, 4-bit) | notes and projects, on this Mac | [mlx-community/gemma-4-12B-it-OptiQ-4bit](https://huggingface.co/mlx-community/gemma-4-12B-it-OptiQ-4bit) | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
| Qwen3 30B A3B (MLX, 4-bit), optional | notes and projects, on Macs with enough memory | [mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit](https://huggingface.co/mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit) | Apache-2.0 |
| multilingual-e5-small | search by meaning | [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | MIT |
