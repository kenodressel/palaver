// The transcript merger (merger.py, test_merger.py).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct MergerTests {
    private func seg(_ start: Double, _ end: Double, _ text: String, speaker: String? = nil, words: [Word] = []) -> Segment {
        Segment(start: start, end: end, text: text, speaker: speaker, words: words)
    }

    private func w(_ text: String, _ start: Double, _ end: Double, _ confidence: Double? = nil) -> Word {
        Word(text: text, start: start, end: end, confidence: confidence)
    }

    @Test func test_assign_speakers_single_turn() {
        let s = seg(0.0, 2.0, "hallo welt", words: [w("hallo", 0.1, 0.5), w("welt", 1.5, 1.9)])
        let assigned = Merger.assignSpeakersToWords([s], [SpeakerTurn(speaker: "SPEAKER_00", start: 0.0, end: 2.0)])
        #expect(assigned.allSatisfy { $0.speaker == "SPEAKER_00" })
    }

    @Test func test_assign_speakers_split_between_turns() {
        let s = seg(0.0, 4.0, "hallo das bist du",
                    words: [w("hallo", 0.0, 0.5), w("das", 1.0, 1.5), w("bist", 2.5, 3.0), w("du", 3.2, 3.8)])
        let turns = [SpeakerTurn(speaker: "SPEAKER_00", start: 0.0, end: 2.0), SpeakerTurn(speaker: "SPEAKER_01", start: 2.0, end: 4.0)]
        #expect(Merger.assignSpeakersToWords([s], turns).map(\.speaker) == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01", "SPEAKER_01"])
    }

    @Test func test_assign_speakers_word_outside_any_turn_falls_back_to_nearest() {
        let s = seg(0.0, 5.0, "x y z", words: [w("x", 0.5, 0.8), w("y", 2.5, 2.8), w("z", 4.5, 4.8)])
        let turns = [SpeakerTurn(speaker: "SPEAKER_00", start: 0.0, end: 1.0), SpeakerTurn(speaker: "SPEAKER_01", start: 4.0, end: 5.0)]
        // y at 2.5: 1.5 from both turns; the earlier one.
        #expect(Merger.assignSpeakersToWords([s], turns).map(\.speaker) == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01"])
    }

    @Test func test_merge_single_track_mic_only() {
        let utterances = Merger.merge(mic: [seg(0.0, 2.0, "hallo", speaker: "Timo")], system: [], turns: [])
        #expect(utterances == [Utterance(speaker: "Timo", start: 0.0, end: 2.0, text: "hallo")])
    }

    @Test func test_merge_interleaves_by_start_time() {
        let mic = [seg(0.0, 1.0, "hi", speaker: "Timo"), seg(5.0, 6.0, "bye", speaker: "Timo")]
        let system = seg(2.0, 3.5, "hallo", words: [w("hallo", 2.0, 3.5)])
        let utterances = Merger.merge(mic: mic, system: [system], turns: [SpeakerTurn(speaker: "SPEAKER_00", start: 2.0, end: 3.5)])
        #expect(utterances.map(\.start) == [0.0, 2.0, 5.0])
        #expect(utterances.map(\.speaker) == ["Timo", "SPEAKER_00", "Timo"])
    }

    @Test func test_merge_groups_consecutive_same_speaker_words_into_one_utterance() {
        let system = seg(0.0, 4.0, "a b c d", words: [w("a", 0.0, 0.5), w("b", 1.0, 1.5), w("c", 2.5, 3.0), w("d", 3.5, 3.9)])
        let turns = [SpeakerTurn(speaker: "SPEAKER_00", start: 0.0, end: 2.0), SpeakerTurn(speaker: "SPEAKER_01", start: 2.0, end: 4.0)]
        let utterances = Merger.merge(mic: [], system: [system], turns: turns)
        #expect(utterances.count == 2)
        #expect(utterances[0] == Utterance(speaker: "SPEAKER_00", start: 0.0, end: 1.5, text: "a b"))
        #expect(utterances[1] == Utterance(speaker: "SPEAKER_01", start: 2.5, end: 3.9, text: "c d"))
    }

    @Test func test_merge_empty_inputs() {
        #expect(Merger.merge(mic: [], system: [], turns: []).isEmpty)
    }

    @Test func test_merge_system_segment_without_words_uses_segment_level_overlap() {
        let turns = [SpeakerTurn(speaker: "SPEAKER_00", start: 4.0, end: 9.0), SpeakerTurn(speaker: "SPEAKER_01", start: 9.0, end: 12.0)]
        let utterances = Merger.merge(mic: [], system: [seg(5.0, 10.0, "hallo welt")], turns: turns)
        #expect(utterances.count == 1)
        #expect(utterances.first?.speaker == "SPEAKER_00")  // 4 s overlap against 1 s
        #expect(utterances.first?.text == "hallo welt")
    }

    @Test func test_merge_drops_empty_text_utterances() {
        let mic = [seg(0.0, 1.0, "", speaker: "Timo"), seg(2.0, 3.0, "Yeah.", speaker: "Timo")]
        let out = Merger.merge(mic: mic, system: [seg(1.0, 2.0, "  ")], turns: [SpeakerTurn(speaker: "SPEAKER_00", start: 0.0, end: 5.0)])
        #expect(out.map(\.text) == ["Yeah."])
    }

    @Test func test_utterances_keep_the_words_the_transcriber_was_unsure_of() throws {
        let mic = [seg(0.0, 1.0, "Wir lösen Tini ab", words: [w("Wir", 0.0, 0.2, 0.99), w("lösen", 0.2, 0.5, 0.97),
                                                              w("Tini", 0.5, 0.7, 0.41), w("ab", 0.7, 1.0, 0.9)])]
        let system = [seg(2.0, 3.0, "Mit Zini?", words: [w("Mit", 2.0, 2.3, 0.95), w("Zini?", 2.3, 3.0, 0.62)])]
        let out = Merger.merge(mic: mic, system: system, turns: [SpeakerTurn(speaker: "SPEAKER_00", start: 2.0, end: 3.0)])
        try #require(out.count == 2)
        #expect(out[0].unsure == ["Tini"] && out[1].unsure == ["Zini?"])
        #expect(try Utterance(json: out[0].json) == out[0])
        #expect(Utterance(speaker: "A", start: 0, end: 1, text: "sure").json["unsure"] == nil)
    }

    @Test func aMicSegmentWithAnEmptySpeakerIsTheUsers() {
        // `s.speaker or "User"`: an empty name counts as none.
        #expect(Merger.merge(mic: [seg(0, 1, " Hallo ", speaker: "")], system: [], turns: []).map(\.speaker) == ["User"])
    }

}
