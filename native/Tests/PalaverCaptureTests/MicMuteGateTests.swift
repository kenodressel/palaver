import Foundation
import PalaverCore
import Testing
@testable import PalaverCapture

private func timeline(delay: Double = 1) -> MuteTimeline {
    MuteTimeline(app: .teams, delay: delay, host: { ns(200) }, wall: { Date(timeIntervalSince1970: 1_772_614_800) })
}

private func ones(_ n: Int) -> [Float] { [Float](repeating: 0.5, count: n) }

@Suite struct MicMuteGateTests {
    @Test func aWrittenStretchCanBeSilencedAfterwards() throws {
        let w = try TrackWriter(finalURL: tempDir().appendingPathComponent("m.wav"))
        try w.write([Int16](repeating: 100, count: 1_000), atOffset: 0)
        #expect(w.silence(200..<300) && w.silence(900..<2_000) && w.silence(-5..<0))
        #expect(w.framesWritten == 1_000)
        try w.finalize(toFrames: 1_000)
        let s = try readWav(w.finalURL).samples
        #expect(s[200..<300].allSatisfy { $0 == 0 } && s[900...].allSatisfy { $0 == 0 })
        #expect(s[0..<200].allSatisfy { $0 == 100 } && s[300..<900].allSatisfy { $0 == 100 } && s.count == 1_000)
    }

    @Test func silencesExactlyTheSamplesInAMutedStretch() {
        let t = timeline()
        let gate = MicMuteGate(timeline: t)
        // 48 kHz, 100 ms from 100 s: sample i is at 100 s + i / 48 000.
        let chunk = TimedChunk(pts: ns(100), samples: ones(4_800), rate: 48_000)
        #expect(gate.silence(chunk) == chunk)
        t.set(true, at: ns(100.025))  // sample 1 200
        t.set(false, at: ns(100.05))  // sample 2 400
        let out = gate.silence(chunk).samples
        #expect(out[1_199] == 0.5 && out[1_200] == 0 && out[2_399] == 0 && out[2_400] == 0.5)
        #expect(out.filter { $0 == 0 }.count == 1_200)
        // Between two samples: the next one is the first silenced (24 kHz: 41 666.67 ns apart).
        let t2 = timeline()
        t2.set(true, at: ns(100) + 41_667 + 10_000)  // after sample 1, before sample 2
        let out2 = MicMuteGate(timeline: t2).silence(TimedChunk(pts: ns(100), samples: ones(10), rate: 24_000)).samples
        #expect(out2 == [0.5, 0.5] + [Float](repeating: 0, count: 8))
    }

    @Test func aStretchOverManyChunksSilencesEachPart() {
        let t = timeline()
        let gate = MicMuteGate(timeline: t)
        t.set(true, at: ns(100.015))
        t.set(false, at: ns(100.045))
        let chunks = (0..<4).map { TimedChunk(pts: ns(100) + Int64($0) * 20_000_000, samples: ones(320), rate: 16_000) }
        let out = chunks.flatMap { gate.silence($0).samples }
        #expect(out.firstIndex(of: 0) == 240 && out.lastIndex(of: 0) == 719 && out.filter { $0 == 0 }.count == 480)
    }

    @Test func holdsTheMicForTheDelayThenReleasesInOrder() {
        let t = timeline(delay: 1)
        let gate = MicMuteGate(timeline: t)
        for k in 0..<3 { gate.push(TimedChunk(pts: ns(100) + Int64(k) * 20_000_000, samples: ones(320), rate: 16_000)) }
        #expect(gate.release(now: ns(101.019)).isEmpty)
        #expect(gate.release(now: ns(101.02)).map(\.pts) == [ns(100)])
        // A change that arrives late, within the hold, still cuts the held audio at its own moment.
        t.set(true, at: ns(100.03))
        let rest = gate.release(now: ns(101.5))
        #expect(rest.map(\.pts) == [ns(100.02), ns(100.04)])
        #expect(rest[0].samples.firstIndex(of: 0) == 160 && rest[1].samples.allSatisfy { $0 == 0 })
        gate.push(TimedChunk(pts: ns(100.06), samples: ones(320), rate: 16_000))
        #expect(gate.release(now: ns(100.1), all: true).count == 1 && gate.isEmpty)
    }
}

/// The recorder with fake sources, its writer pumped by the test in simulated time.
@Suite struct MutedRecordingTests {
    @Test func theMicIsSilentWhileMutedAndTheOthersAreKept() throws {
        let dir = tempDir()
        let now = Locked(100.0)
        var mics: [FakeSource] = [], taps: [FakeSource] = []
        let sources = CaptureSources(
            systemTap: { taps.append(FakeSource(ring: $0, error: nil)); return taps.last! },
            mic: { mics.append(FakeSource(ring: $0, error: nil)); return mics.last! },
            screenCapture: { FakeScreenCapture(mic: $0, system: $1, failures: 0) })
        let t = timeline(delay: 10)  // Teams' hold
        let rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"), systemURL: dir.appendingPathComponent("system.wav"),
                                  sources: sources, monitor: nil, clock: { now.get }, log: { _ in }, debug: { _ in },
                                  sleep: { _ in }, ringCapacity: 1 << 20, runsWriterThread: false, mute: t)
        try rec.start()
        let signal = sine(16_000 * 14)  // 14 s
        let micPart = dir.appendingPathComponent("mic_raw.wav.part"), systemPart = dir.appendingPathComponent("system.wav.part")
        var atEight: (mic: Int, system: Int, written: Double?) = (0, 0, nil)
        for k in 0..<700 {
            let pts = ns(100) + Int64(k) * 20_000_000
            push(mics[0].ring, pts: pts, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
            push(taps[0].ring, pts: pts, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
            now.with { $0 = 100 + Double(k + 1) * 0.02 }  // the chunk's end
            if k == 399 {  // 8 s in: muted from 1 s to 2 s and from 13 s on, told in one late batch
                t.set(true, at: ns(101))
                t.set(false, at: ns(102))
            }
            while rec.drainOnce() {}
            if k == 399 {
                atEight = (try readWav(micPart).samples.count, try readWav(systemPart).samples.count,
                           rec.currentStatus(now.get).written[.mic])
            }
        }
        t.set(true, at: ns(113))  // told just before the stop: the held audio still gets it
        // At 8 s the system track is on disk while the mic is held; the health check counts the held mic.
        #expect(atEight.mic == 0 && atEight.system == 128_000)
        #expect(abs((atEight.written ?? 0) - 8) < 0.001)
        let lengths = try #require(try rec.stop())
        #expect(lengths.mic == 224_000 && lengths.system == 224_000)
        let mic = try readWav(dir.appendingPathComponent("mic_raw.wav")).samples
        let system = try readWav(dir.appendingPathComponent("system.wav")).samples
        #expect(mic[16_000..<32_000].allSatisfy { $0 == 0 } && mic[208_000...].allSatisfy { $0 == 0 })
        #expect(mic[15_990..<16_000].contains { $0 != 0 } && mic[32_000..<32_010].contains { $0 != 0 })
        #expect(meanAbs(mic[0..<16_000]) > 1_000 && meanAbs(mic[32_000..<208_000]) > 1_000)
        #expect(meanAbs(system[16_000..<32_000]) > 1_000 && longestZeroRun(system[...]) < 10)
    }

    @Test func aMuteToldLaterThanTheHoldSilencesWhatWasWritten() throws {
        let dir = tempDir()
        let now = Locked(100.0)
        let log = LogLines()
        var mics: [FakeSource] = [], taps: [FakeSource] = []
        let sources = CaptureSources(
            systemTap: { taps.append(FakeSource(ring: $0, error: nil)); return taps.last! },
            mic: { mics.append(FakeSource(ring: $0, error: nil)); return mics.last! },
            screenCapture: { FakeScreenCapture(mic: $0, system: $1, failures: 0) })
        let t = timeline(delay: 1)
        let rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"), systemURL: dir.appendingPathComponent("system.wav"),
                                  sources: sources, monitor: nil, clock: { now.get }, log: log.sink, debug: { _ in },
                                  sleep: { _ in }, ringCapacity: 1 << 20, runsWriterThread: false, mute: t)
        try rec.start()
        let signal = sine(16_000 * 5)
        let micPart = dir.appendingPathComponent("mic_raw.wav.part")
        var atFour: [Int16] = []
        for k in 0..<250 {
            let pts = ns(100) + Int64(k) * 20_000_000
            push(mics[0].ring, pts: pts, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
            push(taps[0].ring, pts: pts, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
            now.with { $0 = 100 + Double(k + 1) * 0.02 }
            if k == 199 {  // 4 s in, 3 s after the hold let 1-2 s through: muted then, told only now
                t.set(true, at: ns(101))
                t.set(false, at: ns(102))
            }
            while rec.drainOnce() {}
            if k == 199 { atFour = try readWav(micPart).samples }
        }
        #expect(atFour.count == 48_000 && atFour[16_000..<32_000].allSatisfy { $0 == 0 })
        #expect(meanAbs(atFour[0..<16_000]) > 1_000 && meanAbs(atFour[32_000...]) > 1_000)
        #expect(log.all.contains("silenced 1.0 s of microphone already written: Teams told the mute late"))
        try rec.stop()
        let mic = try readWav(dir.appendingPathComponent("mic_raw.wav")).samples
        #expect(mic.count == 80_000 && mic[16_000..<32_000].allSatisfy { $0 == 0 } && meanAbs(mic[32_000...]) > 1_000)
    }

    @Test func aMuteToldAfterTheStopSilencesTheFinishedTrack() throws {
        let dir = tempDir()
        var mics: [FakeSource] = [], taps: [FakeSource] = []
        let sources = CaptureSources(
            systemTap: { taps.append(FakeSource(ring: $0, error: nil)); return taps.last! },
            mic: { mics.append(FakeSource(ring: $0, error: nil)); return mics.last! },
            screenCapture: { FakeScreenCapture(mic: $0, system: $1, failures: 0) })
        let t = timeline(delay: 30)  // only Teams' log is followed
        let log = LogLines()
        let rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"), systemURL: dir.appendingPathComponent("system.wav"),
                                  sources: sources, monitor: nil, clock: { 103 }, log: log.sink, debug: { _ in },
                                  sleep: { _ in }, ringCapacity: 1 << 20, runsWriterThread: false, mute: t)
        try rec.start()
        let signal = sine(48_000)
        for k in 0..<150 {
            push(mics[0].ring, pts: ns(100) + Int64(k) * 20_000_000, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
            push(taps[0].ring, pts: ns(100) + Int64(k) * 20_000_000, Array(signal[k * 320..<(k + 1) * 320]), rate: 16_000)
        }
        try rec.stop()
        rec.silenceAfterStop()  // nothing told yet
        #expect(rec.lateSilenced.isEmpty)
        t.set(true, at: ns(101))  // the log, after the stop
        t.set(false, at: ns(102))
        rec.silenceAfterStop()
        let mic = try readWav(dir.appendingPathComponent("mic_raw.wav")).samples
        #expect(mic.count == 48_000 && mic[16_000..<32_000].allSatisfy { $0 == 0 })
        #expect(meanAbs(mic[0..<16_000]) > 1_000 && meanAbs(mic[32_000...]) > 1_000)
        #expect(rec.lateSilenced.count == 1 && abs(rec.lateSilenced[0].lowerBound - 1) < 1e-6 && abs(rec.lateSilenced[0].upperBound - 2) < 1e-6)
        #expect(log.all.contains("silenced 1.0 s of microphone after the stop: Teams told the mute late"))
    }

    @Test func aShorterHoldLetsTheHeldAudioGoInOrder() {
        let t = timeline(delay: 30)
        let gate = MicMuteGate(timeline: t)
        for k in 0..<5 { gate.push(TimedChunk(pts: ns(100) + Int64(k) * 20_000_000, samples: ones(320), rate: 16_000)) }
        #expect(gate.release(now: ns(102)).isEmpty)
        t.delay = 1  // the button can be read now
        #expect(gate.release(now: ns(102)).map(\.pts) == (0..<5).map { ns(100) + Int64($0) * 20_000_000 })
    }

    @Test func withoutAMuteSourceNothingIsHeld() throws {
        let dir = tempDir()
        var mics: [FakeSource] = [], taps: [FakeSource] = []
        let sources = CaptureSources(
            systemTap: { taps.append(FakeSource(ring: $0, error: nil)); return taps.last! },
            mic: { mics.append(FakeSource(ring: $0, error: nil)); return mics.last! },
            screenCapture: { FakeScreenCapture(mic: $0, system: $1, failures: 0) })
        let rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"), systemURL: dir.appendingPathComponent("system.wav"),
                                  sources: sources, monitor: nil, clock: { 100 }, log: { _ in }, debug: { _ in },
                                  sleep: { _ in }, ringCapacity: 1 << 20, runsWriterThread: false)
        try rec.start()
        push(mics[0].ring, pts: ns(100), sine(320), rate: 16_000)
        push(taps[0].ring, pts: ns(100), sine(320), rate: 16_000)
        while rec.drainOnce() {}
        #expect(try readWav(dir.appendingPathComponent("mic_raw.wav.part")).samples.count == 320)
        try rec.stop()
    }
}
