// Transcript cleanup filters (cleanup.py, test_cleanup.py), and their numbers against Python's (goldens "pipeline").
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct CleanupTests {
    private static let SR = 16_000

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(start: start, end: end, text: text, speaker: nil, words: [])
    }

    /// A silent WAV with sine bursts at (start, end, amplitude), as the Python tests write it (float, then PCM_16).
    @discardableResult
    private func wav(_ url: URL, _ regions: [(Double, Double, Double)], seconds: Double = 10.0) throws -> URL {
        var x = [Int16](repeating: 0, count: Int(seconds * Double(Self.SR)))
        for (start, end, amp) in regions {
            for t in Int(start * Double(Self.SR))..<Int(end * Double(Self.SR)) {
                let v = Float(amp * sin(2 * Double.pi * 220 * Double(t) / Double(Self.SR)))
                x[t] = Int16((v * 32767).rounded())
            }
        }
        try Wav16.write(x, rate: Self.SR, to: url)
        return url
    }

    @Test func test_drop_silent_segments_removes_hallucinations_on_silence() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let track = try wav(temp.url.appendingPathComponent("track.wav"), [(1.0, 2.0, 0.2), (5.0, 6.0, 0.003)])  // -17, -53 dBFS
        let segs = [seg(1.0, 2.0, "Real words here."), seg(5.0, 6.0, "Thank you."), seg(8.0, 9.0, "Yeah.")]
        let kept = try Cleanup.dropSilentSegments(segs, wav: track, minPeakDbfs: -35.0)
        #expect(kept.map(\.text) == ["Real words here."])
    }

    @Test func test_drop_silent_segments_uses_loudest_frame() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let track = try wav(temp.url.appendingPathComponent("track.wav"), [(3.0, 3.2, 0.2)])
        #expect(try Cleanup.dropSilentSegments([seg(1.0, 6.0, "Okay.")], wav: track, minPeakDbfs: -35.0).count == 1)
    }

    @Test func test_drop_silent_segments_handles_segment_past_end() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let track = try wav(temp.url.appendingPathComponent("track.wav"), [], seconds: 2.0)
        #expect(try Cleanup.dropSilentSegments([seg(5.0, 6.0, "ghost")], wav: track, minPeakDbfs: -35.0).isEmpty)
    }

    @Test func test_drop_bleed_duplicates_removes_mic_copies_of_remote_speech() {
        let mic = [seg(10.0, 13.0, "I believe that one feedback from my side"), seg(20.0, 22.0, "Let me share my screen now"),
                   seg(30.0, 30.5, "Yeah.")]
        let system = [seg(9.5, 13.5, "I believe that one feedback from my side for you guys"), seg(29.8, 30.6, "Yeah.")]
        // Short acknowledgements are kept even when the remote side says the same.
        #expect(Cleanup.dropBleedDuplicates(mic, system).map(\.text) == ["Let me share my screen now", "Yeah."])
    }

    @Test func test_drop_bleed_duplicates_ignores_same_words_at_other_times() {
        let mic = [seg(100.0, 103.0, "we should ship the release today")]
        #expect(Cleanup.dropBleedDuplicates(mic, [seg(10.0, 13.0, "we should ship the release today")]) == mic)
    }

    @Test func test_drop_bleed_duplicates_when_mic_merges_several_remote_segments() {
        let mic = [seg(5.0, 15.0, "Die nehmen jetzt viel einfach aus Timos Erfahrungen und "
                                  + "Timos Blueprints, nachdem aber deren Flow ein anderer ist")]
        let system = [seg(4.8, 8.0, "die nehmen jetzt viel einfach aus Timos Erfahrungen"), seg(8.1, 11.0, "und Timos Blueprints,"),
                      seg(11.2, 15.2, "nachdem aber deren Flow ein anderer ist,")]
        #expect(Cleanup.dropBleedDuplicates(mic, system).isEmpty)
    }

    @Test func test_own_speech_sharing_only_common_words_is_kept() {
        let mic = [seg(5.0, 9.0, "ich glaube das ist für den Kunden nicht so wichtig")]
        let system = [seg(3.0, 6.0, "das ist ja auch nicht so einfach für uns"), seg(6.5, 10.0, "ich glaube wir müssen den Plan anpassen")]
        #expect(Cleanup.dropBleedDuplicates(mic, system) == mic)
    }

    @Test func test_short_own_sentence_with_two_shared_pairs_is_kept() {
        let mic = [seg(10.0, 11.5, "Ja, ich habe es mitbekommen.")]
        let system = [seg(9.0, 12.0, "habe ich ich habe es dann versucht ein bisschen zu proben, aber")]
        #expect(Cleanup.dropBleedDuplicates(mic, system) == mic)
    }

    /// A segment with one word every `step` seconds from `start`.
    private func timed(_ start: Double, _ text: String, step: Double = 0.4) -> Segment {
        let words = Py.split(text).enumerated().map { i, w in
            Word(text: w, start: start + Double(i) * step, end: start + Double(i + 1) * step)
        }
        return Segment(start: start, end: words.last!.end, text: text, speaker: nil, words: words)
    }

    /// (mic.wav, mic_raw.wav) of 20 s.
    private func tracks(_ folder: URL, _ raw: [(Double, Double, Double)], _ out: [(Double, Double, Double)]) throws -> (URL, URL) {
        (try wav(folder.appendingPathComponent("mic.wav"), out, seconds: 20.0),
         try wav(folder.appendingPathComponent("mic_raw.wav"), raw, seconds: 20.0))
    }

    @Test func test_drop_echo_catches_garbled_echo_of_remote_speech() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let system = [timed(2.0, "you can have your health insurance claim after the initial processing")]
        let mic = [timed(2.05, "you can have your health and shooting job after the initial process")]
        #expect(Cleanup.dropBleedDuplicates(mic, system) == mic)  // what slipped through before
        let (out, raw) = try tracks(temp.url, [(2, 7, 0.1)], [(2, 7, 0.1)])  // AEC removed nothing
        #expect(try Cleanup.dropEcho(mic, system, micWav: out, micRawWav: raw).isEmpty)
    }

    @Test func test_drop_echo_keeps_the_user_repeating_remote_words_later() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let system = [timed(2.0, "we should ship the release today")]
        let mic = [timed(5.0, "we should ship the release today")]
        let (out, raw) = try tracks(temp.url, [(5, 8, 0.1)], [(5, 8, 0.1)])
        #expect(try Cleanup.dropEcho(mic, system, micWav: out, micRawWav: raw) == mic)
    }

    @Test func test_drop_echo_when_aec_removed_most_of_what_the_mic_heard() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let mic = [timed(3.0, "think those are not three"), timed(10.0, "that is my point")]
        let (out, raw) = try tracks(temp.url, [(3, 5, 0.1), (10, 12, 0.1)], [(3, 5, 0.02), (10, 12, 0.1)])
        #expect(try Cleanup.dropEcho(mic, [], micWav: out, micRawWav: raw) == [mic[1]])
    }

    @Test func test_drop_echo_short_words_said_at_once_need_audio_evidence() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let system = [timed(2.0, "Genau."), timed(10.0, "Ja.")]
        let mic = [timed(2.1, "Genau."), timed(10.1, "Ja.")]
        let (out, raw) = try tracks(temp.url, [(2, 3, 0.1), (10, 11, 0.1)], [(2, 3, 0.1), (10, 11, 0.05)])
        #expect(try Cleanup.dropEcho(mic, system, micWav: out, micRawWav: raw) == [mic[0]])
    }

    @Test func test_drop_echo_without_the_raw_mic_uses_text_only() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let system = [timed(2.0, "you can have your health insurance claim after the initial processing")]
        let mic = [timed(2.05, "you can have your health and shooting job after the initial process"), timed(10.0, "that is my point")]
        let out = try wav(temp.url.appendingPathComponent("track.wav"), [(2, 7, 0.01), (10, 12, 0.1)], seconds: 20.0)
        #expect(try Cleanup.dropEcho(mic, system, micWav: out, micRawWav: temp.url.appendingPathComponent("missing.wav")) == [mic[1]])
    }

    @Test func test_echoes_remote_needs_half_and_three_words() {
        let remote = [Word(text: "wann", start: 10.0, end: 10.2), Word(text: "ist", start: 10.2, end: 10.3),
                      Word(text: "der", start: 10.3, end: 10.4), Word(text: "go-live", start: 10.4, end: 10.9)]
        let echo = Segment(start: 10.05, end: 10.9, text: "wann ist der go-live", words: [
            Word(text: "wann", start: 10.05, end: 10.2), Word(text: "ist", start: 10.2, end: 10.3),
            Word(text: "der", start: 10.3, end: 10.4), Word(text: "go-live", start: 10.4, end: 10.9)])
        let mine = Segment(start: 10.0, end: 10.9, text: "ich glaube im März", words: [
            Word(text: "ich", start: 10.0, end: 10.2), Word(text: "glaube", start: 10.2, end: 10.4),
            Word(text: "im", start: 10.4, end: 10.5), Word(text: "März", start: 10.5, end: 10.9)])
        let short = Segment(start: 10.0, end: 10.3, text: "wann ist", words: [
            Word(text: "wann", start: 10.0, end: 10.2), Word(text: "ist", start: 10.2, end: 10.3)])
        #expect(Cleanup.echoesRemote(echo, remote))
        #expect(!Cleanup.echoesRemote(mine, remote))
        #expect(!Cleanup.echoesRemote(short, remote))  // fewer than three aligned words
    }

    // MARK: - Against Python

    private func signal(_ name: String) throws -> [Int16] {
        let hex = Array(try #require(Goldens.load("pipeline")["signals"]?[name]?.stringValue).utf8)
        func nibble(_ c: UInt8) -> UInt16 { UInt16(c <= 57 ? c - 48 : c - 87) }
        var out = [Int16](repeating: 0, count: hex.count / 4)
        for k in out.indices {
            let i = 4 * k
            let lo = nibble(hex[i]) << 4 | nibble(hex[i + 1]), hi = nibble(hex[i + 2]) << 4 | nibble(hex[i + 3])
            out[k] = Int16(bitPattern: lo | hi << 8)
        }
        return out
    }

    /// The loudest frame to the float32 bit, and the gate's answer at thresholds on both sides of it (where the
    /// threshold's own float32 rounding decides).
    @Test func theSilenceGateIsNumpysToTheBit() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("track.wav")
        var got: [JSONValue] = []
        for c in try Goldens.cases("pipeline", "silent") {
            let (rate, channels) = (try Goldens.int(c[1]), try Goldens.int(c[2]))
            try Wav16.write(try signal(c[0].stringValue!), rate: rate, channels: channels, to: url)
            let s = Segment(start: c[3].doubleValue!, end: c[4].doubleValue!, text: "x")
            let level = try Cleanup.loudestFrame(try Cleanup.Track(url), s)
            let kept: [JSONValue] = try c[6].arrayValue!.map { k in
                let db = k.arrayValue![0].doubleValue!
                return .array([.double(db), .bool(!(try Cleanup.dropSilentSegments([s], wav: url, minPeakDbfs: db)).isEmpty)])
            }
            got.append(.array([c[0], c[1], c[2], c[3], c[4], level.map { .double(Double($0)) } ?? .null, .array(kept)]))
        }
        Goldens.expectEach(got, "pipeline", "silent")
    }

    @Test func whatAecRemovedIsNumpysToTheBit() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let (rawURL, outURL) = (temp.url.appendingPathComponent("mic_raw.wav"), temp.url.appendingPathComponent("mic.wav"))
        var got: [JSONValue] = []
        for c in try Goldens.cases("pipeline", "removed") {
            let rate = try Goldens.int(c[2])
            try Wav16.write(try signal(c[0].stringValue!), rate: rate, to: rawURL)
            try Wav16.write(try signal(c[1].stringValue!), rate: rate, to: outURL)
            let db = try Cleanup.aecRemovedDb(raw: try Cleanup.Track(rawURL), out: try Cleanup.Track(outURL), sr: rate,
                                              seg: Segment(start: c[3].doubleValue!, end: c[4].doubleValue!, text: "x"))
            got.append(.array([c[0], c[1], c[2], c[3], c[4], .double(db)]))
        }
        Goldens.expectEach(got, "pipeline", "removed")
    }

    @Test func bleedComparesWordsAsPythonDoes() throws {
        var got: [JSONValue] = []
        for c in try Goldens.cases("pipeline", "bleed") {
            let mic = try c[0].arrayValue!.map { try Segment(json: $0) }
            let system = try c[1].arrayValue!.map { try Segment(json: $0) }
            let kept = Cleanup.dropBleedDuplicates(mic, system)
            got.append(.array([c[0], c[1], .array(mic.indices.filter { i in kept.contains(mic[i]) }.map { .int($0) })]))
        }
        Goldens.expectEach(got, "pipeline", "bleed")
    }

    @Test func alignedWordsAsPythonCountsThem() throws {
        var got: [JSONValue] = []
        for c in try Goldens.cases("pipeline", "aligned") {
            let mic = try Segment(json: c[0])
            let remote = try c[1].arrayValue!.map { try Word(json: $0) }.filter { !Cleanup.norm($0.text).isEmpty }
            let (words, aligned) = Cleanup.alignedWords(mic, remote)
            got.append(.array([c[0], c[1], .int(words), .int(aligned), .bool(Cleanup.echoesRemote(mic, remote))]))
        }
        Goldens.expectEach(got, "pipeline", "aligned")
    }

    @Test func aTimeThatIsNoNumberIsAnErrorNotATrap() throws {
        let temp = TempFolder("cleanup"); defer { temp.remove() }
        let track = try wav(temp.url.appendingPathComponent("track.wav"), [], seconds: 1.0)
        #expect(throws: Cleanup.TimeError.self) {
            try Cleanup.dropSilentSegments([seg(.nan, 1, "x")], wav: track, minPeakDbfs: -35)
        }
        #expect(throws: Cleanup.TimeError.self) {
            try Cleanup.dropEcho([seg(0, .infinity, "x")], [], micWav: track, micRawWav: track)
        }
        #expect(throws: (any Error).self) { try Cleanup.dropEcho([], [], micWav: temp.url.appendingPathComponent("none.wav"), micRawWav: track) }
    }
}
