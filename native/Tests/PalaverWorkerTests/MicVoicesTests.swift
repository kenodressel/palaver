// A call held over a speaker, all of it on the microphone: the microphone is diarized, the voice that sounds like the
// user's own stays the user's lines, the others become speakers. The engine is a fake; the user's earlier call is a
// folder of files; no model, no audio device.
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

private func seg(_ start: Double, _ end: Double, _ text: String) -> String {
    let ws = text.split(separator: " ").enumerated().map { i, w in
        #"{"text": "\#(w)", "start": \#(start + Double(i) * 0.4), "end": \#(start + Double(i + 1) * 0.4)}"#
    }
    return #"{"start": \#(start), "end": \#(end), "text": "\#(text)", "speaker": null, "words": [\#(ws.joined(separator: ", "))]}"#
}

/// An earlier call of Timo's, done: his lines on the microphone, Valerie on the call's track.
private func earlierCall(_ h: Harness, _ name: String) throws -> RecordingPaths {
    let paths = try h.meeting(name, mic: track(20, loud: [(1, 5)]), system: track(20, loud: [(6, 18)], seed: 2), seconds: 20)
    try PythonJSON.write(.array([
        Utterance(speaker: "Timo", start: 1, end: 5, text: "Morning, shall we start with the numbers?").json,
        Utterance(speaker: "SPEAKER_00", start: 6, end: 18, text: "Sure, the quarter went well.").json,
    ]), to: paths.transcriptJson, indent: 2, ensureAscii: true)
    try PythonJSON.write(.array([SpeakerTurn(speaker: "SPEAKER_00", start: 6, end: 18).json]), to: paths.systemTurns, indent: 2, ensureAscii: true)
    return paths
}

/// The speakerphone call: nothing on the call's track; Timo, then Carla through the speaker (far quieter: about -47
/// dBFS, under the microphone's gate), then both in one stretch.
private func speakerphone(_ h: Harness) throws -> RecordingPaths {
    var mic = track(14, loud: [(0.5, 3), (4, 8), (9, 12)])
    for i in 4 * 16_000..<8 * 16_000 { mic[i] = Int16((Double(mic[i]) * 0.02).rounded()) }
    return try h.meeting("2026-11-17T18-46-24", mic: mic, system: [], start: "2026-11-17T18:46:24+01:00", seconds: 14)
}

private let ENGINE = #"""
{"transcribe": {"mic.wav": [\#(seg(0.5, 3, "Hi Carla how are you")), \#(seg(4, 8, "Fine thanks and you there")),
                            \#(seg(9, 12, "yes I agree no wait"))]},
 "diarize": {"mic.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 0.5, "end": 3}, {"speaker": "SPEAKER_01", "start": 4, "end": 8},
                                   {"speaker": "SPEAKER_00", "start": 9, "end": 10}, {"speaker": "SPEAKER_01", "start": 10, "end": 12}],
                         "embeddings": {"SPEAKER_00": [1, 0], "SPEAKER_01": [0, 1]}}},
 "embed": {"mic.wav": {"me": [0.95, 0.1]}}}
"""#

private func lines(_ paths: RecordingPaths) -> [String] {
    (readJSON(paths.transcriptJson)?.arrayValue ?? []).map { "\($0["speaker"]?.stringValue ?? ""): \($0["text"]?.stringValue ?? "")" }
}

@Suite struct MicVoicesTests {
    @Test func aSpeakerphoneCallTellsTheOtherVoiceOnTheMicrophoneFromTheUsers() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        _ = try earlierCall(h, "2026-11-10T09-00-00")
        let paths = try speakerphone(h)
        let engine = fake(ENGINE)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(lines(paths) == ["Timo: Hi Carla how are you", "SPEAKER_01: Fine thanks and you there", "Timo: yes I agree",
                                 "SPEAKER_01: no wait"])
        #expect(engine.calls.contains("embed mic.wav") && engine.calls.contains("diarize mic.wav"))
        // The others are the meeting's speakers, to name and recognize; the user's turns are the microphone's.
        #expect(readJSON(paths.systemTurns)?.arrayValue?.compactMap { $0["speaker"]?.stringValue } == ["SPEAKER_01", "SPEAKER_01"])
        guard case .object(let voices)? = readJSON(paths.speakerEmbeddings) else { Issue.record("no voices"); return }
        #expect(voices.map(\.0) == ["SPEAKER_01"])
        #expect(readJSON(paths.micTurns)?.arrayValue?.compactMap { $0["speaker"]?.stringValue } == ["me", "me"])
        #expect(MicVoices.othersWav(paths) == paths.micWav)
        #expect(OwnVoice.load(h.stores).map(\.meeting) == ["2026-11-10T09-00-00"])
        #expect(h.said.contains("Told 1 other voice apart from yours on the microphone"))
        #expect(events(paths).contains("mic_voices"))
        // The meeting is no call of the user's own voice alone: it teaches the own voice nothing.
        #expect(!OwnVoice.isOwnCall(paths))
    }

    @Test func withoutTheUsersVoiceKnownTheMicrophoneStaysTheirs() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try speakerphone(h)
        let engine = fake(ENGINE)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(Set(lines(paths).map { $0.split(separator: ":")[0] }) == ["Timo"])
        #expect(!engine.calls.contains("diarize mic.wav"))
        #expect(!FileManager.default.fileExists(atPath: paths.micTurns.path))
        #expect(MicVoices.othersWav(paths) == paths.systemWav)
    }

    @Test func aCallWithSomeoneOnItsTrackLeavesTheMicrophoneAlone() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        _ = try earlierCall(h, "2026-11-10T09-00-00")
        let paths = try h.meeting("2026-11-17T10-00-00", mic: track(14, loud: [(0.5, 3)]), system: track(14, loud: [(4, 12)], seed: 2),
                                  start: "2026-11-17T10:00:00+01:00", seconds: 14)
        let engine = fake(#"""
        {"transcribe": {"mic.wav": [\#(seg(0.5, 3, "Hi Carla"))], "system.wav": [\#(seg(4, 12, "Hello Timo good to see you"))]},
         "diarize": {"system.wav": {"turns": [{"speaker": "SPEAKER_00", "start": 4, "end": 16}], "embeddings": {"SPEAKER_00": [0, 1]}}}}
        """#)
        #expect(try await Pipeline.process(paths.folder, h.setup(engine), notes: false) == 0)
        #expect(!engine.calls.contains("diarize mic.wav") && !engine.calls.contains("embed mic.wav"))
        #expect(!FileManager.default.fileExists(atPath: paths.micTurns.path))
    }

    @Test func theUserIsEveryVoiceAlikeToTheirOwnAndOnlyThose() throws {
        let voices = PyDict<[Double]>([("SPEAKER_00", [1, 0]), ("SPEAKER_01", [0, 1]), ("SPEAKER_02", [0.8, 0.6])])
        #expect(try MicVoices.ownerLabels(voices, profile: [[1, 0]]) == ["SPEAKER_00", "SPEAKER_02"])  // 0.8: split in two
        #expect(try MicVoices.ownerLabels(voices, profile: []) == [])
        #expect(try MicVoices.ownerLabels(PyDict([("SPEAKER_00", [0.6, 0.8])]), profile: [[1, 0]]) == [])  // 0.6: someone else
    }

    @Test func aSegmentWithoutWordsGoesWholeAndNothingSplitsWithoutTheUsersTurns() {
        let segs = [Segment(start: 0, end: 2, text: "mine", speaker: "Timo"), Segment(start: 3, end: 5, text: "theirs", speaker: "Timo")]
        let mine = [SpeakerTurn(speaker: "me", start: 0, end: 2)], others = [SpeakerTurn(speaker: "SPEAKER_00", start: 3, end: 5)]
        let split = MicVoices.split(segs, owner: mine, others: others)
        #expect(split.mine.map(\.text) == ["mine"])
        #expect(split.theirs.map(\.text) == ["theirs"] && split.theirs[0].speaker == nil)
        #expect(MicVoices.split(segs, owner: [], others: others).mine == segs)
    }

    @Test func theOwnVoiceEmbedsEachCallOnceAndPassesOverOthers() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        _ = try earlierCall(h, "2026-11-10T09-00-00")
        let room = try earlierCall(h, "2026-11-11T09-00-00")
        try SharedMic.setLane(room, SharedMic.MIC, true)  // the microphone was a room: not the user's voice alone
        _ = try earlierCall(h, "2026-11-12T09-00-00")
        var asked: [String] = []
        func profile() async throws -> [[Double]] {
            try await OwnVoice.profile(outputDir: h.config.outputDir, stores: h.stores, excluding: "2026-11-12T09-00-00") { wav, spans in
                asked.append(wav.deletingLastPathComponent().lastPathComponent)
                #expect(spans == [1.0..<5.0])
                return [1, 0]
            }
        }
        #expect(try await profile() == [[1, 0]])
        #expect(asked == ["2026-11-10T09-00-00"])
        #expect(try await profile() == [[1, 0]])
        #expect(asked == ["2026-11-10T09-00-00"])  // kept: not embedded again
    }
}
