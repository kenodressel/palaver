"""Regenerate tests/fixtures/tiny_embedder/ (the golden files of tests/test_embeddings.py).

Needs torch, transformers and sentencepiece, which the runtime no longer
has; run it with any Python that does, from the repository root:

    /path/to/python tools/make_embedder_fixture.py

It trains a 30-piece SentencePiece model, saves two tiny random encoders
(XLM-RoBERTa and BERT-shaped, as multilingual-e5-small is stored) and the
mean-pooled, normalised outputs transformers gives for TEXTS, as
expected.json. The numpy encoder in palaver/embeddings.py must match them.
"""

import json
import sys
import tempfile
from pathlib import Path

import sentencepiece
import torch
import transformers

TEXTS = ["hello world", "pricing the offer a b c d", "cost"]
OUT = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "tiny_embedder"


def build(folder: Path, kind: str) -> list[list[float]]:
    torch.manual_seed(0)
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        corpus = Path(tmp) / "corpus.txt"
        corpus.write_text("\n".join(["hello world", "pricing the offer", "a b c d", "cost and price",
                                      "the offer costs a lot", "world wide pricing"] * 20))
        sentencepiece.SentencePieceTrainer.train(input=str(corpus), model_prefix=str(folder / "sentencepiece.bpe"),
                                                 vocab_size=30, model_type="unigram", minloglevel=2,
                                                 normalization_rule_name="identity")  # no 200 KB charsmap
    sp = sentencepiece.SentencePieceProcessor(model_file=str(folder / "sentencepiece.bpe.model"))
    shape = dict(vocab_size=sp.vocab_size() + 1, hidden_size=32, num_hidden_layers=2, num_attention_heads=4,
                 intermediate_size=64, max_position_embeddings=40)
    if kind == "bert":
        model = transformers.BertModel(transformers.BertConfig(**shape, type_vocab_size=2, pad_token_id=0),
                                       add_pooling_layer=False)
    else:
        model = transformers.XLMRobertaModel(transformers.XLMRobertaConfig(**shape, type_vocab_size=1, pad_token_id=1),
                                             add_pooling_layer=False)
    model.eval()
    model.save_pretrained(folder)
    for stale in folder.glob("sentencepiece.bpe.vocab"):
        stale.unlink()
    want = []
    with torch.no_grad():
        for text in TEXTS:
            ids = torch.tensor([[0] + [i + 1 if i else 3 for i in sp.encode(text)] + [2]])
            out = model(input_ids=ids, attention_mask=torch.ones_like(ids)).last_hidden_state[0].mean(0)
            want.append((out / out.norm()).tolist())
    return want


if __name__ == "__main__":
    for kind in ("xlm-roberta", "bert"):
        want = build(OUT / kind, kind)
        (OUT / kind / "expected.json").write_text(json.dumps({"texts": TEXTS, "embeddings": want}))
        print(kind, "written", file=sys.stderr)
