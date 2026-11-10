// tests/test_models.py: the transcript models and the JSON they keep (key order, omitted keys).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private func dumps(_ v: JSONValue) -> String { PythonJSON.dumps(v) }

@Suite struct ModelsTests {
    @Test func test_word_roundtrip() throws {
        let w = Word(text: "hallo", start: 1.0, end: 1.5)
        #expect(try Word(json: w.json) == w)
        #expect(dumps(w.json) == #"{"text": "hallo", "start": 1.0, "end": 1.5}"#)  // no confidence key
        let sure = Word(text: "welt", start: 0, end: 0.5, confidence: 0.25)
        #expect(dumps(sure.json) == #"{"text": "welt", "start": 0.0, "end": 0.5, "confidence": 0.25}"#)
        #expect(try Word(json: sure.json) == sure)
    }

    @Test func test_segment_with_words_roundtrip() throws {
        let s = Segment(start: 0.0, end: 2.0, text: "hallo welt", speaker: "Timo",
                        words: [Word(text: "hallo", start: 0.1, end: 0.5), Word(text: "welt", start: 0.6, end: 1.9)])
        #expect(try Segment(json: s.json) == s)
        #expect(dumps(s.json) == #"{"start": 0.0, "end": 2.0, "text": "hallo welt", "speaker": "Timo", "words": [{"text": "hallo", "start": 0.1, "end": 0.5}, {"text": "welt", "start": 0.6, "end": 1.9}]}"#)
    }

    @Test func test_segment_without_words() throws {
        let s = Segment(start: 0.0, end: 2.0, text: "hallo welt", speaker: nil, words: [])
        #expect(try Segment(json: s.json) == s)
        #expect(dumps(s.json) == #"{"start": 0.0, "end": 2.0, "text": "hallo welt", "speaker": null, "words": []}"#)
        // No "words" key at all reads as no words, as `d.get("words", [])`.
        let bare = try PythonJSON.parse(Data(#"{"start": 1, "end": 2, "text": "x"}"#.utf8))
        #expect(try Segment(json: bare) == Segment(start: 1, end: 2, text: "x", speaker: nil, words: []))
    }

    @Test func test_speaker_turn_roundtrip() throws {
        let t = SpeakerTurn(speaker: "SPEAKER_01", start: 3.0, end: 5.5)
        #expect(try SpeakerTurn(json: t.json) == t)
        #expect(dumps(t.json) == #"{"speaker": "SPEAKER_01", "start": 3.0, "end": 5.5}"#)
    }

    @Test func test_utterance_roundtrip() throws {
        let u = Utterance(speaker: "Timo", start: 0.0, end: 2.0, text: "hallo welt")
        #expect(try Utterance(json: u.json) == u)
        #expect(dumps(u.json) == #"{"speaker": "Timo", "start": 0.0, "end": 2.0, "text": "hallo welt"}"#)
    }

    @Test func anUtteranceKeepsLabelHeardAndUnsureInOrderAndNeverTheGlossary() throws {
        let u = Utterance(speaker: "Timo Strauß", start: 1, end: 2.5, text: "Contoso", label: "SPEAKER_00",
                          heard: "Kontoso", unsure: ["Contoso"], glossed: [(0, 7, "Kontoso")])
        #expect(dumps(u.json) == #"{"speaker": "Timo Strauß", "start": 1.0, "end": 2.5, "text": "Contoso", "label": "SPEAKER_00", "heard": "Kontoso", "unsure": ["Contoso"]}"#.replacingOccurrences(of: "ß", with: "\\u00df"))
        let back = try Utterance(json: u.json)
        #expect(back.glossed.isEmpty && back.unsure == ["Contoso"] && back.label == "SPEAKER_00" && back.heard == "Kontoso")
        // A null label or heard is as good as none.
        let nulls = try PythonJSON.parse(Data(#"{"speaker": "a", "start": 0, "end": 1, "text": "t", "label": null, "heard": null, "unsure": []}"#.utf8))
        #expect(dumps(try Utterance(json: nulls).json) == #"{"speaker": "a", "start": 0.0, "end": 1.0, "text": "t"}"#)
    }

    @Test func test_segment_speaker_is_mutable() {
        // The merger/CLI assigns speaker to mic segments post-transcription.
        var s = Segment(start: 0.0, end: 1.0, text: "hi", speaker: nil, words: [])
        s.speaker = "Timo"
        #expect(s.speaker == "Timo")
    }

    @Test func numbersAreFloatsWhateverTheFileSaid() throws {
        // `float(d["start"])`: an int in the file is written back as a float; a numeric string is read.
        let d = try PythonJSON.parse(Data(#"{"speaker": "a", "start": 3, "end": "4.5", "text": "t"}"#.utf8))
        #expect(dumps(try Utterance(json: d).json) == #"{"speaker": "a", "start": 3.0, "end": 4.5, "text": "t"}"#)
    }

    @Test func aMissingKeyIsAKeyError() throws {
        let d = try PythonJSON.parse(Data(#"{"start": 1, "end": 2}"#.utf8))
        #expect(throws: ModelError.self) { try Segment(json: d) }
        #expect(throws: ModelError.self) { try Word(json: .array([])) }
    }

    @Test func theUnsureConfidenceIsPythons() {
        #expect(UNSURE_CONFIDENCE == 0.85)
    }
}
