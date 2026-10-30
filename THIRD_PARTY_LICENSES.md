# Third-party models

Palaver's releases carry a copy of one model, so it can be downloaded without
a Hugging Face account. Other models are downloaded from their own pages, as
the setup assistant says. Libraries in Palaver's runtime keep their own
license files inside it (`lib/python3.13/site-packages/*.dist-info`), and
the vendored echo-cancellation code is listed in
[`palaver/_vendored/webrtc_aec/THIRD_PARTY.md`](palaver/_vendored/webrtc_aec/THIRD_PARTY.md).

## Hosted with each release

### pyannote speaker-diarization-community-1

- Asset: `palaver-models-pyannote-community-1-<revision>.tar`, installed into
  `~/Library/Application Support/palaver/models/pyannote-community-1/`
- Source: <https://huggingface.co/pyannote/speaker-diarization-community-1>,
  revision `3533c8cf8e369892e6b79ff1bf80f7b0286a54ee`, copied unchanged
- License: [Creative Commons Attribution 4.0 International (CC-BY-4.0)](https://creativecommons.org/licenses/by/4.0/),
  as declared by its authors on the model page. The repository is gated on
  Hugging Face to collect contact details; its license allows passing it on
  with attribution.
- Contents: the pipeline's configuration, the pyannote speaker segmentation
  model, the WeSpeaker speaker-embedding model, and the VBx PLDA parameters
- Attribution: pyannote (Hervé Bredin, Alexis Plaquet and contributors,
  <https://www.pyannote.ai>). Training and tuning made possible thanks to
  GENCI on the Jean Zay supercomputer. The copy includes the model card
  (`README.md`) and a `LICENSE.md` with this notice.
- Please cite:
  - A. Plaquet and H. Bredin, "Powerset multi-class cross entropy loss for
    neural speaker diarization", Proc. INTERSPEECH 2023.
  - H. Wang et al., "Wespeaker: A research and production oriented speaker
    embedding learning toolkit", ICASSP 2023.
  - F. Landini, J. Profant, M. Diez and L. Burget, "Bayesian HMM clustering
    of x-vector sequences (VBx) in speaker diarization: theory,
    implementation and analysis on standard tasks", Computer Speech &
    Language, 2022.

## Downloaded from their own pages

| Model | Used for | Source | License |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (MLX) | transcription | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3), from [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC-BY-4.0 |
| Gemma 4 12B (MLX, 4-bit) | notes and projects, on this Mac | [mlx-community/gemma-4-12B-it-OptiQ-4bit](https://huggingface.co/mlx-community/gemma-4-12B-it-OptiQ-4bit) | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
| Qwen3 30B A3B (MLX, 4-bit), optional | notes and projects, on Macs with enough memory | [mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit](https://huggingface.co/mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit) | Apache-2.0 |
| multilingual-e5-small | search by meaning | [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | MIT |
