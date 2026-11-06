"""The search's text embedder (#46): an XLM-RoBERTa encoder run with numpy
from memory-mapped weights, checked against golden outputs of the transformers
implementation on a tiny random model (tools/make_embedder_fixture.py)."""

import json
import shutil
from pathlib import Path

import numpy as np
import pytest

from palaver import embeddings


FIXTURES = Path(__file__).parent / "fixtures" / "tiny_embedder"


def _tiny_model(folder: Path, kind: str = "xlm-roberta") -> dict:
    """Copy a golden tiny model (random weights, made once with transformers
    by tools/make_embedder_fixture.py) into ``folder``; returns its
    reference: the texts and the embeddings transformers gave for them."""
    source = FIXTURES / kind
    if not (source / "expected.json").exists():
        pytest.fail(f"{source} is missing: run tools/make_embedder_fixture.py")
    for name in ("config.json", "sentencepiece.bpe.model", "model.safetensors"):
        shutil.copy(source / name, folder / name)
    return json.loads((source / "expected.json").read_text())


@pytest.mark.parametrize("kind", ["xlm-roberta", "bert"])
def test_the_encoder_matches_transformers(tmp_path: Path, kind: str):
    reference = _tiny_model(tmp_path, kind)
    texts, want = reference["texts"], np.array(reference["embeddings"], dtype=np.float32)

    encoder = embeddings.Encoder(tmp_path, prefix_query="", prefix_passage="")
    got = encoder.passages(texts)  # one padded batch: padding must not change anything
    assert got.shape == (3, 32) and got.dtype == np.float32
    np.testing.assert_allclose(got, want, atol=1e-4)
    np.testing.assert_allclose(np.linalg.norm(got, axis=1), 1.0, atol=1e-5)
    np.testing.assert_allclose(encoder.query("hello world"), want[0], atol=1e-4)


def test_the_encoder_maps_its_weights_instead_of_reading_them(tmp_path: Path):
    _tiny_model(tmp_path)
    weights = embeddings.load_safetensors(tmp_path / "model.safetensors")
    assert all(isinstance(w.base, np.memmap) or isinstance(w, np.memmap) for w in weights.values())


def test_prefixes_go_in_front_of_queries_and_passages(tmp_path: Path):
    _tiny_model(tmp_path)
    encoder = embeddings.Encoder(tmp_path, prefix_query="hello ", prefix_passage="world ")
    plain = embeddings.Encoder(tmp_path, prefix_query="", prefix_passage="")
    np.testing.assert_allclose(encoder.query("cost"), plain.query("hello cost"), atol=1e-6)
    np.testing.assert_allclose(encoder.passages(["cost"])[0], plain.passages(["world cost"])[0], atol=1e-6)


def test_the_model_files_are_found_only_where_they_are(tmp_path: Path, monkeypatch):
    calls = []

    asked = set()

    def download(repo_id, filename, revision, local_files_only):
        asked.add((repo_id, revision))
        calls.append((filename, local_files_only))
        if local_files_only:
            raise FileNotFoundError(filename)
        return str(tmp_path / filename)

    monkeypatch.setattr(embeddings, "_hf_download", download)
    assert embeddings.model_folder(download=False) is None
    assert calls == [("config.json", True)]
    assert embeddings.model_folder(download=True) == tmp_path
    assert {f for f, offline in calls if not offline} == set(embeddings.MODEL_FILES)
    assert asked == {("intfloat/multilingual-e5-small", embeddings.REVISION)}  # the pinned model, every time


def test_the_encoder_stays_in_float32(tmp_path: Path, monkeypatch):
    """float64 would double the memory of a batch (numpy 2 lets a numpy
    float64 scalar promote a float32 array)."""
    _tiny_model(tmp_path)
    seen = []
    norm = embeddings._layer_norm
    monkeypatch.setattr(embeddings, "_layer_norm", lambda x, *a: seen.append(x.dtype) or norm(x, *a))
    embeddings.Encoder(tmp_path).passages(["hello world", "cost"])
    assert set(seen) == {np.dtype(np.float32)}


def test_the_ids_are_the_ones_xlm_r_s_own_tokenizer_gives():
    """On the real vocabulary, when the model is on this Mac (never downloaded
    for a test); transformers' XLMRobertaTokenizer is the reference."""
    transformers = pytest.importorskip("transformers")
    folder = embeddings.model_folder(download=False)
    if folder is None:
        pytest.skip("multilingual-e5-small is not downloaded")
    theirs = transformers.XLMRobertaTokenizer.from_pretrained(str(folder), local_files_only=True)
    ours = embeddings.Encoder(folder)
    for text in ["query: pricing", "passage: Wir müssen noch über die Kosten für das Angebot reden.",
                 "Ähm, also ÖNW-Projekt — 120.000 € inkl. Lizenzen!!  Doppelt  Leerzeichen\nneue Zeile",
                 "日本語のテキスト", "emoji 🎉 test", "", "Straße naïve café façade"]:
        assert ours._ids(text) == theirs(text)["input_ids"], text
    long = "wort " * 2000
    assert ours._ids(long) == theirs(long, truncation=True, max_length=512)["input_ids"]
