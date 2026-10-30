"""Text embeddings for search by meaning (#46): multilingual-e5-small run
with numpy.

Why this model: it is multilingual (the meetings are German and English, and
"pricing" has to find "Kosten"), built for retrieval, and small: 118 M
parameters, 471 MB on disk, 384 numbers per text. Most of its size is the
vocabulary (250 k tokens × 384); the 12 layers that run are 21 M parameters.

Why numpy: the weights are memory-mapped from the safetensors file, not read.
A query touches the vocabulary rows of its own few tokens and the layers, so
the process holds a few MB of its own; the rest are file pages macOS can drop
at any time. No torch in the menu bar app, and no GPU work next to live
transcription. Indexing a meeting is a few seconds on the CPU, done in the
background (``palaver index``).
"""

from __future__ import annotations

import json
import math
import struct
from pathlib import Path

import numpy as np

MODEL = "intfloat/multilingual-e5-small"
REVISION = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
MODEL_FILES = ("config.json", "sentencepiece.bpe.model", "model.safetensors")
MAX_TOKENS = 512
BATCH = 8  # a batch of 16 long pieces held ~2x the memory, no faster
BOS, EOS, UNK = 0, 2, 3

_DTYPES = {"F32": np.float32, "F16": np.float16, "I64": np.int64}


def _hf_download(repo_id: str, filename: str, revision: str, local_files_only: bool) -> str:
    from huggingface_hub import hf_hub_download

    return hf_hub_download(repo_id, filename, revision=revision, local_files_only=local_files_only)


def model_folder(*, download: bool) -> Path | None:
    """The folder with the model's files; None when they are not on this Mac
    and ``download`` is False (a query never downloads)."""
    try:
        paths = [Path(_hf_download(MODEL, f, REVISION, not download)) for f in MODEL_FILES]
    except Exception:  # not cached, offline, …
        if download:
            raise
        return None
    return paths[0].parent


def load_safetensors(path: Path) -> dict[str, np.ndarray]:
    """The tensors of a safetensors file as read-only views of one memory map."""
    with open(path, "rb") as f:
        size = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(size))
    data = np.memmap(path, dtype=np.uint8, mode="r", offset=8 + size)
    out = {}
    for name, info in header.items():
        if name == "__metadata__":
            continue
        start, end = info["data_offsets"]
        out[name] = data[start:end].view(_DTYPES[info["dtype"]]).reshape(info["shape"])
    return out


def _layer_norm(x: np.ndarray, weight: np.ndarray, bias: np.ndarray, eps: float) -> np.ndarray:
    mean = x.mean(-1, keepdims=True)
    var = ((x - mean) ** 2).mean(-1, keepdims=True)
    return (x - mean) / np.sqrt(var + eps) * weight + bias


def _gelu(x: np.ndarray) -> np.ndarray:
    from scipy.special import erf

    return 0.5 * x * (1.0 + erf(x / math.sqrt(2.0)))


class Encoder:
    """An XLM-RoBERTa encoder, mean-pooled and normalized (as E5 is used).
    multilingual-e5-small is stored as a BERT model: XLM-R's vocabulary, but
    positions counted from 0, where XLM-R counts from its padding id + 1."""

    def __init__(self, folder: Path, *, prefix_query: str = "query: ", prefix_passage: str = "passage: "):
        import sentencepiece

        config = json.loads((Path(folder) / "config.json").read_text())
        self.heads = config["num_attention_heads"]
        self.layers = config["num_hidden_layers"]
        self.eps = config.get("layer_norm_eps", 1e-12)
        self.pad = config.get("pad_token_id", 1)
        self.first_position = self.pad + 1 if config.get("model_type") in ("xlm-roberta", "roberta") else 0
        self.max_tokens = min(MAX_TOKENS, config["max_position_embeddings"] - self.first_position)
        self.w = {k.removeprefix("roberta."): v for k, v in load_safetensors(Path(folder) / "model.safetensors").items()}
        # SentencePiece, as XLM-R was trained: ~60 MB, where the tokenizers
        # library takes ~300 MB for the same 250 k pieces.
        self.pieces = sentencepiece.SentencePieceProcessor(model_file=str(Path(folder) / "sentencepiece.bpe.model"))
        self.prefix_query, self.prefix_passage = prefix_query, prefix_passage

    def query(self, text: str) -> np.ndarray:
        return self._encode([self.prefix_query + text])[0]

    def passages(self, texts: list[str]) -> np.ndarray:
        """One row per text; batches of similar length, so little padding."""
        texts = [self.prefix_passage + t for t in texts]
        out = np.zeros((len(texts), self.w["embeddings.word_embeddings.weight"].shape[1]), np.float32)
        order = sorted(range(len(texts)), key=lambda i: len(texts[i]))
        for at in range(0, len(order), BATCH):
            rows = order[at:at + BATCH]
            out[rows] = self._encode([texts[i] for i in rows])
        return out

    def _ids(self, text: str) -> list[int]:
        """XLM-R's ids: <s> pieces </s>, the SentencePiece ids one up
        (fairseq's order puts <s> <pad> </s> <unk> first), its unknown → 3."""
        pieces = self.pieces.encode(text)[:self.max_tokens - 2]
        return [BOS] + [p + 1 if p else UNK for p in pieces] + [EOS]

    def _encode(self, texts: list[str]) -> np.ndarray:
        encoded = [self._ids(t) for t in texts]
        width = max(len(e) for e in encoded)
        ids = np.full((len(texts), width), self.pad, np.int64)
        mask = np.zeros((len(texts), width), np.float32)
        for i, e in enumerate(encoded):
            ids[i, :len(e)] = e
            mask[i, :len(e)] = 1.0
        w = self.w
        positions = np.where(mask > 0, np.cumsum(mask, axis=1) - 1 + self.first_position, self.pad).astype(np.int64)
        x = (w["embeddings.word_embeddings.weight"][ids] + w["embeddings.position_embeddings.weight"][positions]
             + w["embeddings.token_type_embeddings.weight"][0]).astype(np.float32)
        x = _layer_norm(x, w["embeddings.LayerNorm.weight"], w["embeddings.LayerNorm.bias"], self.eps)
        batch, width, hidden = x.shape
        size = hidden // self.heads
        blocked = (1.0 - mask)[:, None, None, :] * -1e9

        def dense(v: np.ndarray, name: str) -> np.ndarray:
            return v @ w[name + ".weight"].T + w[name + ".bias"]

        def split(v: np.ndarray) -> np.ndarray:
            return v.reshape(batch, width, self.heads, size).transpose(0, 2, 1, 3)

        for n in range(self.layers):
            p = f"encoder.layer.{n}."
            q, k, v = (split(dense(x, p + "attention.self." + name)) for name in ("query", "key", "value"))
            scores = q @ k.transpose(0, 1, 3, 2) / math.sqrt(size) + blocked
            scores = np.exp(scores - scores.max(-1, keepdims=True))
            scores /= scores.sum(-1, keepdims=True)
            context = (scores @ v).transpose(0, 2, 1, 3).reshape(batch, width, hidden)
            x = _layer_norm(x + dense(context, p + "attention.output.dense"),
                            w[p + "attention.output.LayerNorm.weight"], w[p + "attention.output.LayerNorm.bias"],
                            self.eps)
            inner = _gelu(dense(x, p + "intermediate.dense"))
            x = _layer_norm(x + dense(inner, p + "output.dense"),
                            w[p + "output.LayerNorm.weight"], w[p + "output.LayerNorm.bias"], self.eps)
        pooled = (x * mask[..., None]).sum(1) / mask.sum(1, keepdims=True)
        return (pooled / np.linalg.norm(pooled, axis=1, keepdims=True)).astype(np.float32)
