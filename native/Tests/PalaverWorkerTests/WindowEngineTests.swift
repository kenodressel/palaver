// The stream's sliding-window engine (tests/test_stream_engine.py): a scripted transcribe, no model.
import Darwin
import FluidAudio
import Foundation
import PalaverCore
@testable import PalaverDomain
import PalaverEngine
@testable import PalaverWorker
import Testing

private let SR = 16_000
private typealias Word = PalaverDomain.Word

private func audio(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(SR))) }

private func w(_ text: String, _ start: Double, _ end: Double, _ confidence: Double? = nil) -> Word {
    Word(text: text, start: start, end: end, confidence: confidence)
}

private func texts(_ words: [Word]) -> [String] { words.map(\.text) }

/// A transcribe that returns the next preset word list per call.
private final class Scripted: @unchecked Sendable {
    private var passes: [[Word]]
    init(_ passes: [[Word]]) { self.passes = passes }
    func callAsFunction(_ audio: [Float]) async throws -> [Word] { passes.isEmpty ? [] : passes.removeFirst() }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A ramp whose first sample says where the pass begins (seconds / 100).
private func ramp(_ seconds: Int) -> [Float] { (0..<seconds * SR).map { Float(Double($0) / Double(SR) / 100) } }

private func tok(_ t: String, _ s: Double, _ e: Double, _ c: Float) -> TokenTiming {
    TokenTiming(token: t, tokenId: 0, startTime: s, endTime: e, confidence: c)
}

/// Remembers how many samples each recognition got.
private final class Heard: Recognizer, @unchecked Sendable {
    var samples: [Int] = []
    let tokens: [TokenTiming]
    init(_ tokens: [TokenTiming]) { self.tokens = tokens }
    func recognize(_ samples: [Float]) async throws -> [TokenTiming] {
        self.samples.append(samples.count)
        return tokens
    }
}

@Suite struct WindowEngineTests {
    @Test func test_words_settle_when_two_passes_agree() async throws {
        let s = Scripted([[w("Wann", 0, 0.3), w("ist", 0.4, 0.6)], [w("Wann", 0, 0.3), w("ist", 0.4, 0.6), w("der", 0.7, 0.9)]])
        let engine = WindowEngine { try await s($0) }
        var (settled, draft) = try await engine.add(audio(1))
        #expect(settled.isEmpty && texts(draft) == ["Wann", "ist"])
        (settled, draft) = try await engine.add(audio(1))
        #expect(texts(settled) == ["Wann", "ist"])
        #expect(texts(draft) == ["der"])
    }

    @Test func test_words_settle_by_age_without_agreement() async throws {
        let s = Scripted([[w("Hallo", 0, 0.3)], [w("Hello", 0, 0.3)]])
        let engine = WindowEngine { try await s($0) }
        _ = try await engine.add(audio(1))
        let (settled, draft) = try await engine.add(audio(3.5))  // fed 4.5: the word ended > 3 s ago
        #expect(texts(settled) == ["Hello"] && draft.isEmpty)
    }

    @Test func test_words_leaving_the_window_are_not_lost() async throws {
        let truth = (0..<28).map { (Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        let calls = Box(0)
        // The text changes every pass, so no two passes ever agree.
        let engine = WindowEngine { audio in
            calls.value += 1
            let begin = Py.round(Double(audio[0]) * 100, 2)
            let end = begin + Double(audio.count) / Double(SR)
            return truth.enumerated().filter { $0.element.0 >= begin - 0.01 && $0.element.1 <= end }
                .map { w("w\($0.offset)-\(calls.value)", $0.element.0 - begin, $0.element.1 - begin) }
        }
        let r = ramp(15)
        var settled: [Word] = []
        for step in 0..<15 {
            settled += try await engine.add(Array(r[step * SR..<(step + 1) * SR])).settled
        }
        let starts = settled.map(\.start)
        #expect(Set(starts).count == starts.count)
        #expect(starts == truth.filter { $0.1 <= 15.0 - 3.0 }.map(\.0))
    }

    @Test func test_times_are_from_the_track_start() async throws {
        let seen = Box((seconds: 0.0, calls: 0))
        let engine = WindowEngine { audio in
            seen.value = (Double(audio.count) / Double(SR), seen.value.calls + 1)
            return [w("spät\(seen.value.calls)", 8.0, 8.4)]  // never agrees
        }
        var draft: [Word] = []
        for _ in 0..<20 { draft = try await engine.add(audio(1)).draft }
        #expect(seen.value.seconds == 10.0)  // only the last window is transcribed
        #expect(draft == [w("spät20", 18.0, 18.4)])  // begin 10.0 + 8.0
    }

    @Test func test_dictionary_applies_to_words() async throws {
        let s = Scripted([[w("Tini", 0, 0.3)]])
        let engine = WindowEngine({ try await s($0) }, dictionary: TranscriberDictionary(replacements: PyDict([("Tini", "Zini")])))
        #expect(texts(try await engine.add(audio(1)).draft) == ["Zini"])
    }

    @Test func test_flush_settles_the_draft() async throws {
        let s = Scripted([[w("Ende", 0, 0.3)]])
        let engine = WindowEngine { try await s($0) }
        _ = try await engine.add(audio(1))
        #expect(texts(engine.flush()) == ["Ende"])
        #expect(engine.flush().isEmpty)
    }

    @Test func test_fed_audio_stays_bounded() async throws {
        let engine = WindowEngine { _ in [] }
        for _ in 0..<60 { _ = try await engine.add(audio(1)) }
        #expect(engine.bufferedSamples <= 11 * SR)
    }

    @Test func test_a_late_engine_reports_times_from_the_track_start() async throws {
        let seen = Box(0.0)
        let engine = WindowEngine { audio in
            seen.value = Double(audio.count) / Double(SR)
            return [w("spät", 8.0, 8.4)]
        }
        engine.startAt(50.0)
        let (_, draft) = try await engine.add(audio(10))
        #expect(seen.value == 10.0)
        #expect(draft == [w("spät", 58.0, 58.4)])
    }

    @Test func test_a_draft_settles_once_when_a_jump_passes_the_window() async throws {
        // The .part files stop growing in silence: when audio resumes, one add gets the whole gap and its window
        // begins after the old draft.
        let truth: [(String, Double, Double)] = [("Was", 2.0, 2.3), ("kostet", 2.4, 2.8), ("das?", 2.9, 3.3), ("Gut", 28.0, 28.4)]
        let engine = WindowEngine { audio in
            let begin = Py.round(Double(audio[0]) * 100, 3)
            let end = begin + Double(audio.count) / Double(SR)
            return truth.filter { $0.1 >= begin - 0.01 && $0.2 <= end }.map { w($0.0, $0.1 - begin, $0.2 - begin) }
        }
        let r = ramp(40)
        var settled: [Word] = [], draft: [Word] = [], pos = 0
        for n in [SR, SR, SR, SR / 2] {
            let got = try await engine.add(Array(r[pos..<pos + n]))
            settled += got.settled
            draft = got.draft
            pos += n
        }
        #expect(texts(draft).contains("das?"))  // not settled yet
        settled += try await engine.add(Array(r[pos..<pos + 26 * SR])).settled  // 25 s of silence and "Gut" in one go
        pos += 26 * SR
        for _ in 0..<5 {
            settled += try await engine.add(Array(r[pos..<pos + SR])).settled
            pos += SR
        }
        #expect(texts(settled).filter { $0 == "das?" }.count == 1)
        #expect(Array(texts(settled).prefix(3)) == ["Was", "kostet", "das?"])
        #expect(settled.map(\.start) == settled.map(\.start).sorted())
    }

    @Test func test_load_engines_share_one_engine() async throws {
        let engine = fake(#"{"windows": [{"text": "ja", "start": 0.1, "end": 0.3}]}"#)
        let (system, mic) = StreamWorker.loadEngines(engine)
        // Both windows go to the one engine (its calls run one at a time); its dictionary is applied there, once.
        #expect(system !== mic)
        #expect(texts(try await system.add(audio(1)).draft) == ["ja"])
        #expect(texts(try await mic.add(audio(1)).draft) == ["ja"])
    }

    @Test func test_window_transcriber_sends_base64_float32() async throws {
        let t = Temp(); defer { t.remove() }
        let heard = Heard([tok("▁cloud", 0.0, 0.1, 0.9)])
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"), recognizer: { heard })
        let words = try await engine.transcribeWindow([Float](repeating: 0, count: 16_000))
        #expect(heard.samples == [16_000])
        #expect(words.map { [$0.text, "\($0.start)", "\($0.end)", "\($0.confidence ?? -1)"] } == [["cloud", "0.0", "0.1", "0.9"]])
    }

    @Test func test_how_long_a_word_waits_depends_on_how_sure_the_model_is() async throws {
        // Measured on recorded meetings: unsure words (below 0.85) differ from the final transcript 50–100 % of the
        // time, so they wait for more context; sure ones (0.95 and up) settle sooner.
        for (text, confidence, settlesAfter) in [("Budget", 0.98, 2.5), ("Tini", 0.6, 6.5)] {
            let s = Scripted((0..<20).map { [w(text + "\($0)", 0, 0.3, confidence)] })
            let engine = WindowEngine { try await s($0) }
            _ = try await engine.add(audio(1))
            var fed = 1.0, settled: [Word] = []
            while settled.isEmpty {
                settled = try await engine.add(audio(0.5)).settled
                fed += 0.5
            }
            #expect(fed == settlesAfter, "\(text)")
        }
    }

    @Test func test_word_confidence_is_its_least_sure_piece() async throws {
        let t = Temp(); defer { t.remove() }
        let engine = InProcessEngine(version: "t", modelsDir: t.file("models"),
                                     recognizer: { Heard([tok(" Bud", 0.0, 0.2, 0.99), tok("get", 0.2, 0.4, 0.7)]) })
        let words = try await engine.transcribeWindow([Float](repeating: 0, count: 16_000))
        #expect(words.map(\.text) == ["Budget"] && words.map(\.confidence) == [0.7])
        #expect(try Word(json: words[0].json) == words[0])
        #expect(Word(text: "x", start: 0, end: 1).json["confidence"] == nil)  // none known: not stored
    }

    @Test func test_memory_meter_reads_the_process_tree_and_keeps_the_peak() {
        // The model lives in this process now (the in-process engine), so the stream's memory is its own footprint.
        let mb = 1_048_576
        let expected: [Int] = [700 * mb, 1300 * mb, 900 * mb]
        var readings = expected
        var asked: [Int32] = []
        let meter = MemoryMeter(pid: 4242) { pid in asked.append(pid); return readings.removeFirst() }
        let got: [Int] = [meter(), meter(), meter()]
        #expect(got == expected)
        #expect(asked == [4242, 4242, 4242] && meter.peakMB == 1300)
        #expect(MemoryMeter()() > 0)  // this test process, through proc_pid_rusage
    }
}
