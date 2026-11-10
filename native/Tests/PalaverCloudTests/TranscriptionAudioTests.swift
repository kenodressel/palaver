// The audio side of cloud transcription (transcription.py): silences cut and the times mapped back, chunks that cover
// the recording, stitching by word, segments as Parakeet cuts them, FLAC 16 kHz mono out; and the pending deletions
// (cloud-pending.json) retried.
import AVFoundation
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

/// A 16-bit WAV of `seconds` at `rate`: a 440 Hz tone at 0.3 where `loud` says, near-silence elsewhere.
func toneWav(_ url: URL, seconds: Double, rate: Int = 16_000, loud: [(Double, Double)]) throws {
    let n = Int(seconds * Double(rate))
    var samples = [Int16](repeating: 0, count: n)
    for (a, b) in loud {
        for i in Int(a * Double(rate))..<min(n, Int(b * Double(rate))) {
            samples[i] = Int16(0.3 * 32767 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
        }
    }
    try Wav16.write(samples, rate: rate, to: url)
}

@Suite struct TrimTests {
    @Test func silencesOfTwoSecondsAreCutKeepingHalfASecondEachSide() throws {
        let dir = tempFolder("trim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("system.wav")
        try toneWav(wav, seconds: 20, loud: [(3.0, 5.0), (6.0, 7.0), (12.0, 14.0)])
        // 0–3 s: cut, 0.5 s kept before the speech; 5–6 s: too short to cut; 7–12 s: cut but 0.5 s each side;
        // 14–20 s: cut, 0.5 s kept after the speech.
        let spans = try Trim.speechSpans(wav)
        #expect(spans.count == 2)
        #expect(spans[0] == (2.5, 7.5) && spans[1] == (11.5, 14.5))
        let line = Timeline(spans)
        #expect(line.seconds == 8.0)
        // A time on the trimmed clock maps back to the recording's.
        #expect(line.toSource(0) == 2.5 && line.toSource(4.5) == 7.0 && line.toSource(5.0) == 11.5 && line.toSource(5.5) == 12.0)
        // A word that runs over a cut ends where its part of the recording ends.
        #expect(line.wordToSource(Word(text: "über", start: 4.8, end: 5.4, confidence: 0.9)) == Word(text: "über", start: 7.3, end: 7.5, confidence: 0.9))
        let pieces = line.pieces(4.0, 6.0)
        #expect(pieces.count == 2 && pieces[0] == (6.5, 7.5) && pieces[1] == (11.5, 12.5))
    }

    @Test func aSilentTrackHasNothingToSend() throws {
        let dir = tempFolder("trim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("system.wav")
        try toneWav(wav, seconds: 5, loud: [])
        #expect(try Trim.speechSpans(wav).isEmpty)
        try Wav16.write([], rate: 16_000, to: wav)  // a bare header: the tap delivered nothing
        #expect(try Trim.speechSpans(wav).isEmpty)
    }
}

@Suite struct ChunkTests {
    @Test func chunksCoverTheRecordingAndOverlap() {
        #expect(Chunks.plan(total: 500, maxSeconds: 600).count == 1)
        let chunks = Chunks.plan(total: 1500, maxSeconds: 600)
        #expect(chunks.first?.0 == 0 && chunks.last?.1 == 1500)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(b.0 < a.1 && a.1 - b.0 == 10)  // the next starts before this one ends
            #expect(a.1 - a.0 <= 600)
        }
        // A short service window overlaps a quarter of it at most.
        #expect(Chunks.plan(total: 100, maxSeconds: 20, overlap: 10).dropFirst().first?.0 == 15)
    }

    @Test func aChunkIsFlac16kMonoOfTheTrimmedAudio() throws {
        let dir = tempFolder("chunk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("system.wav")
        try toneWav(wav, seconds: 10, rate: 48_000, loud: [(1.0, 3.0), (7.0, 8.0)])
        let line = Timeline(try Trim.speechSpans(wav))
        let chunk = try Chunks.flac(wav, line: line, start: 0, end: line.seconds)
        #expect(chunk.flac.prefix(4) == Data("fLaC".utf8))
        #expect(abs(chunk.seconds - line.seconds) < 0.01)
        let out = dir.appendingPathComponent("out.flac")
        try chunk.flac.write(to: out)
        let file = try AVAudioFile(forReading: out)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / 16_000 - line.seconds) < 0.01)
        #expect(chunk.flac.count < Int(line.seconds * Chunks.RAW_BYTES_PER_SECOND))  // never larger than 16-bit PCM
    }

    @Test func theTestToneIsTwoSecondsOfFlac() throws {
        let data = try Chunks.tone(seconds: 2)
        #expect(data.prefix(4) == Data("fLaC".utf8) && data.count > 1000)
    }
}

@Suite struct StitchTests {
    private func w(_ t: String, _ s: Double, _ e: Double) -> Word { Word(text: t, start: s, end: e) }

    @Test func overlappingChunksAreStitchedEachWordOnce() {
        // Chunk 1 covers 0–20, chunk 2 15–35: the seam is at 17.5.
        let one = [w("eins", 1, 1.5), w("zwei", 16, 16.4), w("drei", 17.3, 17.9)]
        let two = [w("zwei", 16.05, 16.45), w("drei", 17.32, 17.88), w("vier", 18, 18.5), w("fünf", 30, 30.4)]
        let stitched = Stitch.stitch([(0, 20, one), (15, 35, two)])
        #expect(stitched.map(\.text) == ["eins", "zwei", "drei", "vier", "fünf"])
    }

    @Test func aWordHeardDifferentlyAtTheSeamIsKeptOnce() {
        let one = [w("Hallo", 17.0, 17.45)]
        let two = [w("hallo,", 17.3, 17.75), w("Welt", 17.8, 18.2)]  // past the seam, but the same word
        #expect(Stitch.stitch([(0, 20, one), (15, 35, two)]).map(\.text) == ["Hallo", "Welt"])
    }

    @Test func segmentsAreCutAtSentenceEndsPausesAndFifteenSeconds() {
        let words = [w("Hallo.", 0, 0.5), w("Wie", 0.6, 0.8), w("geht's", 0.9, 1.2), w("dir", 2.5, 2.8)]
            + (0..<20).map { w("la", 4.0 + Double($0), 4.5 + Double($0)) }
        let segments = Stitch.segments(words)
        #expect(segments.map(\.text).prefix(3) == ["Hallo.", "Wie geht's", "dir"])
        #expect(segments.allSatisfy { $0.end - $0.start <= 15 && $0.speaker == nil })
        #expect(segments[1].words.count == 2)
    }
}

@Suite struct PendingTests {
    private func entry(_ pid: String, _ url: String?, until: String? = nil, tries: Int? = nil) -> JSONValue {
        var f: [(String, JSONValue)] = [("provider", .string(pid)), ("host", .string("x")), ("what", .string("transcript")),
                                        ("url", url.map(JSONValue.string) ?? .null), ("since", .string("2026-11-08T10:00:00+01:00"))]
        if let until { f.append(("until", .string(until))) }
        if let tries { f.append(("tries", .int(tries))) }
        return .object(f)
    }

    @Test func aPendingDeletionIsRetriedOnlyAtTheServicesOwnHosts() async {
        let fake = Routes(["DELETE https://api.eu.assemblyai.com/v2/transcript/t1": [.ok("")],
                           "DELETE https://api.soniox.com/v1/files/f1": [.json(404, "{}")]])
        #expect(await TranscriptionPending.delete(entry("assemblyai", "https://api.eu.assemblyai.com/v2/transcript/t1"), key: ASR_KEY, http: fake.client))
        #expect(fake.requests.last?.value(forHTTPHeaderField: "authorization") == ASR_KEY)
        #expect(await TranscriptionPending.delete(entry("soniox", "https://api.soniox.com/v1/files/f1"), key: ASR_KEY, http: fake.client))
        #expect(fake.requests.last?.value(forHTTPHeaderField: "authorization") == "Bearer \(ASR_KEY)")
        let before = fake.requests.count
        // Not a deletion Palaver would send: dropped, nothing sent (a changed file can't send the key elsewhere).
        for url in ["https://evil.example.com/v2/transcript/t1", "https://api.eu.assemblyai.com/v2/upload",
                    "https://api.eu.assemblyai.com/v2/transcript/t1?x=1", "http://api.eu.assemblyai.com/v2/transcript/t1"] {
            #expect(await TranscriptionPending.delete(entry("assemblyai", url), key: ASR_KEY, http: fake.client))
        }
        #expect(await TranscriptionPending.delete(entry("mistral", "https://api.mistral.ai/v1/x"), key: ASR_KEY, http: fake.client))
        #expect(fake.requests.count == before)
        // No key now: kept for later.
        #expect(!(await TranscriptionPending.delete(entry("assemblyai", "https://api.eu.assemblyai.com/v2/transcript/t1"), key: nil, http: fake.client)))
        // Nothing to call: done once its date has passed.
        #expect(await TranscriptionPending.delete(entry("assemblyai", nil, until: "2020-01-01T00:00:00+00:00"), key: ASR_KEY, http: fake.client))
        #expect(!(await TranscriptionPending.delete(entry("assemblyai", nil, until: "2999-01-01T00:00:00+00:00"), key: ASR_KEY, http: fake.client)))
    }

    @Test func retryKeepsWhatIsStillThereAndCountsTheTries() async throws {
        let dir = tempFolder("pending")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Meetings")
        let meeting = root.appendingPathComponent("2026-11-08T10-00-00")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let global = dir.appendingPathComponent("config/cloud-pending.json")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(.array([entry("assemblyai", "https://api.eu.assemblyai.com/v2/transcript/t1"),
                                     entry("soniox", "https://api.eu.soniox.com/v1/transcriptions/j1", tries: 2)]),
                             to: meeting.appendingPathComponent("cloud-pending.json"), indent: 2, ensureAscii: true)
        try PythonJSON.write(.array([entry("soniox", "https://api.eu.soniox.com/v1/files/f9")]), to: global, indent: 2, ensureAscii: true)
        let fake = Routes(["DELETE https://api.eu.assemblyai.com/v2/transcript/t1": [.ok("")],
                           "DELETE https://api.eu.soniox.com/v1/transcriptions/j1": [.json(409, "{}")],
                           "DELETE https://api.eu.soniox.com/v1/files/f9": [.ok("")]])
        let left = await TranscriptionPending.sweep(root: root, global: global, key: { _ in ASR_KEY }, http: fake.client)
        #expect(left == 1)
        #expect(!FileManager.default.fileExists(atPath: global.path))  // all done: the file goes
        let kept = PythonJSON.read(meeting.appendingPathComponent("cloud-pending.json"))?.arrayValue
        #expect(kept?.count == 1 && kept?[0]["url"] == .string("https://api.eu.soniox.com/v1/transcriptions/j1"))
        #expect(kept?[0]["tries"] == .int(3) && kept?[0]["since"] == .string("2026-11-08T10:00:00+01:00"))
    }

    @Test func whatAnAdapterCouldNotDeleteIsAddedToTheFile() throws {
        let dir = tempFolder("pending")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cloud-pending.json")
        try PythonJSON.write(.array([entry("soniox", "https://api.eu.soniox.com/v1/files/old")]), to: file, indent: 2, ensureAscii: true)
        let a = try Transcription.adapter("assemblyai", settings: PyDict([("model", .string("universal-2"))]), key: ASR_KEY,
                                          http: Routes().client)
        a.pending = [entry("assemblyai", "https://api.eu.assemblyai.com/v2/transcript/t2")]
        #expect(TranscriptionPending.keep(a, in: file) == 1 && a.pending.isEmpty)
        #expect(PythonJSON.read(file)?.arrayValue?.compactMap { $0["url"]?.stringValue }
            == ["https://api.eu.soniox.com/v1/files/old", "https://api.eu.assemblyai.com/v2/transcript/t2"])
    }
}
