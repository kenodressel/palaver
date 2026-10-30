"""Tests for comparing transcripts with another transcriber's (#36)."""

from palaver import bench


def test_tokens_ignore_case_punctuation_fillers_and_number_dots():
    assert bench.tokens("Äh, wir zahlen 1.040 Euro — für Databricks!") == ["wir", "zahlen", "1040", "euro", "für", "databricks"]


def test_compare_finds_agreement_gaps_names_and_hallucinations():
    shared = "wir haben heute die migration besprochen und der plan steht soweit fest"
    ours = [(0.0, 10.0, "Timo", f"{shared}."),
            (10.0, 20.0, "Speaker 1", "Dann geht es um Atterkring und Unit zu vierzehn."),
            (20.0, 40.0, "Speaker 1", " ".join(["blabla"] * 15))]
    notion = f"{shared}. Dann geht es um Attakring und Unit 214. 查找。"
    r = bench.compare(ours, notion, known=["Attakring", "Unit 214"], minutes=1)
    assert r["words"] == {"ours": 36, "notion": 21}
    assert 0.4 < r["agreement"] < 0.6  # 17 of 36 words
    assert r["only_ours"][0]["words"] == 15 and r["only_ours"][0]["at"] >= 20
    assert {n["term"]: (n["ours"], n["notion"]) for n in r["names"]} == {"Attakring": (0, 1), "Unit 214": (0, 1)}
    assert r["not_latin"] == {"ours": 0, "notion": 2}
