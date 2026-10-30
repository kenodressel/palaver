"""The search's text embedder (#46): an XLM-RoBERTa encoder run with numpy
from memory-mapped weights, checked against the transformers implementation
on a tiny random model."""

import json
from pathlib import Path

import numpy as np
import pytest

from palaver import embeddings


def _tiny_model(folder: Path, kind: str = "xlm-roberta"):
    torch = pytest.importorskip("torch")
    transformers = pytest.importorskip("transformers")
    import sentencepiece

    torch.manual_seed(0)
    corpus = folder / "corpus.txt"
    corpus.write_text("\n".join(["hello world", "pricing the offer", "a b c d", "cost and price",
                                  "the offer costs a lot", "world wide pricing"] * 20))
    sentencepiece.SentencePieceTrainer.train(input=str(corpus), model_prefix=str(folder / "sentencepiece.bpe"),
                                             vocab_size=30, model_type="unigram", minloglevel=2)
    sp = sentencepiece.SentencePieceProcessor(model_file=str(folder / "sentencepiece.bpe.model"))
    shape = dict(vocab_size=sp.vocab_size() + 1, hidden_size=32, num_hidden_layers=2, num_attention_heads=4,
                 intermediate_size=64, max_position_embeddings=40)
    if kind == "bert":  # as multilingual-e5-small is stored: BERT positions, XLM-R's vocabulary
        model = transformers.BertModel(transformers.BertConfig(**shape, type_vocab_size=2, pad_token_id=0),
                                       add_pooling_layer=False)
    else:
        model = transformers.XLMRobertaModel(transformers.XLMRobertaConfig(**shape, type_vocab_size=1, pad_token_id=1),
                                             add_pooling_layer=False)
    model.eval()
    model.save_pretrained(folder)

    def ids(text):  # XLM-R's ids, written out apart from the encoder's
        return [0] + [i + 1 if i else 3 for i in sp.encode(text)] + [2]

    return torch, model, ids


@pytest.mark.parametrize("kind", ["xlm-roberta", "bert"])
def test_the_encoder_matches_transformers(tmp_path: Path, kind: str):
    torch, model, ids_of = _tiny_model(tmp_path, kind)
    texts = ["hello world", "pricing the offer a b c d", "cost"]
    with torch.no_grad():
        want = []
        for text in texts:
            ids = torch.tensor([ids_of(text)])
            out = model(input_ids=ids, attention_mask=torch.ones_like(ids)).last_hidden_state[0].mean(0)
            want.append((out / out.norm()).numpy())

    encoder = embeddings.Encoder(tmp_path, prefix_query="", prefix_passage="")
    got = encoder.passages(texts)  # one padded batch: padding must not change anything
    assert got.shape == (3, 32) and got.dtype == np.float32
    np.testing.assert_allclose(got, np.stack(want), atol=1e-4)
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
