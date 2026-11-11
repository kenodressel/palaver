import Foundation
import Testing
@testable import PalaverCapture

/// The tests of test_capture_recorder.py's streaming writer, through `TrackAligner` with synthetic chunks.
@Suite struct AlignerTests {
    @Test func producesAlignedWavs() throws {
        let r = try drive(tempDir(), mic: chunked(sine(32_000), 100, 320),
                          system: chunked(sine(32_000, freq: 880), 100, 320))
        #expect(r.mic.samples.count == 32_000 && r.system.samples.count == 32_000)
        #expect(longestZeroRun(r.mic.samples[...]) < 5)
        #expect(r.mic.dataSize == 64_000 && r.system.dataSize == 64_000)
    }

    @Test func resamples48kMicTo16k() throws {
        // ScreenCaptureKit and AVCapture deliver the device's native rate.
        let r = try drive(tempDir(), mic: chunked(sine(96_000, sr: 48_000), 100, 512, rate: 48_000),
                          system: chunked(sine(32_000, freq: 880), 100, 320))
        let m = r.mic.samples
        #expect(abs(m.count - 32_000) <= 2)
        #expect(abs(dominantFreq(m[...]) - 440) < 2)
        #expect(longestZeroRun(m[100..<(m.count - 100)]) < 5)
        #expect(r.aligner.micRate == 48_000 && r.aligner.systemRate == 16_000)
    }

    @Test func followsRateChangeMidTrack() throws {
        // Switching input device mid-meeting (AirPods connect) changes the mic's rate; the timeline stays continuous.
        let first = chunked(sine(48_000, sr: 48_000), 100, 512, rate: 48_000)
        let second = chunked(sine(24_000, sr: 24_000), 101, 240, rate: 24_000)
        let r = try drive(tempDir(), mic: first + second, system: chunked(sine(32_000, freq: 880), 100, 320))
        let m = r.mic.samples
        #expect(abs(m.count - 32_000) <= 4)
        #expect(abs(dominantFreq(m[0..<16_000]) - 440) < 2)
        #expect(abs(dominantFreq(m[16_000...]) - 440) < 2)
        #expect(longestZeroRun(m[100..<(m.count - 100)]) < 5)
        #expect(r.aligner.micRate == 24_000)
    }

    @Test func jitterWithinToleranceWritesContiguous() throws {
        // Sub-millisecond jitter (as in Python's test) and jitter just inside 20 ms: no chunk dropped or padded.
        for frames in [[-1.4, -0.6, 0.6, 1.4], [-300, -120, 150, 310]] {
            var mic = chunked(sine(32_000), 100, 320)
            for i in mic.indices.dropFirst() { mic[i].pts += Int64(frames[i % frames.count] * 62_500) }
            let r = try drive(tempDir(), mic: mic, system: chunked(sine(32_000, freq: 880), 100, 320))
            #expect(r.mic.samples.count == 32_000)
            #expect(longestZeroRun(r.mic.samples[...]) < 5)
            #expect(r.mic.samples == PCM.int16(sine(32_000)[...]))  // every sample in its place
        }
    }

    @Test func gapZeroPads() throws {
        // A real 500 ms delivery gap stays silence, so later audio keeps its wall-clock position.
        let r = try drive(tempDir(), mic: chunked(sine(16_000), 100, 320) + chunked(sine(16_000), 101.5, 320),
                          system: chunked(sine(40_000, freq: 880), 100, 320))
        let m = r.mic.samples
        #expect(m.count == 40_000)
        #expect(maxAbs(m[16_000..<24_000]) == 0)
        #expect(meanAbs(m[24_000..<24_160]) > 1_000)
    }

    @Test func overlapTrims() throws {
        // A chunk that starts 1000 frames before the track's end: only the part after the end is written.
        // One entirely inside what is on disk is dropped.
        let base = sine(16_000)
        let late = [Float](repeating: 0.5, count: 3_200)
        let inside = [Float](repeating: -0.5, count: 600)
        let mic = chunked(base, 100, 320) + [TimedChunk(pts: ns(100) + 15_000 * 62_500, samples: late),
                                              TimedChunk(pts: ns(100) + 17_000 * 62_500, samples: inside)]
        let r = try drive(tempDir(), mic: mic, system: chunked(sine(16_000, freq: 880), 100, 320))
        let m = r.mic.samples
        #expect(m.count == 16_000 + 2_200)
        #expect(Array(m[0..<16_000]) == PCM.int16(base[...]))
        #expect(m[16_000...].allSatisfy { $0 == 16_383 })
    }

    @Test func keepsMicBeforeLateSystem() throws {
        // Both files share sample 0 = the earlier track's first PTS; the late track is padded at the front.
        let r = try drive(tempDir(), mic: chunked(sine(80_000), 100, 320),
                          system: chunked(sine(32_000, freq: 880), 103, 320))
        let m = r.mic.samples, s = r.system.samples
        #expect(m.count == 80_000 && s.count == 80_000)
        #expect(meanAbs(m[0..<160]) > 1_000)
        #expect(maxAbs(s[0..<48_000]) == 0)
        #expect(meanAbs(s[48_000..<48_160]) > 1_000)
        #expect(r.aligner.startPts == ns(100))
    }

    @Test func lateStartingMicIsPadded() throws {
        let r = try drive(tempDir(), mic: chunked(sine(32_000, freq: 880, amp: 0.5), 101, 512),
                          system: chunked(sine(48_000), 100, 320))
        let m = r.mic.samples
        #expect(m.count == 48_000 && r.system.samples.count == 48_000)
        #expect(maxAbs(m[0..<16_000]) == 0)
        #expect(meanAbs(m[16_000..<16_160]) > 1_000)
    }

    @Test func writesMicWhenSystemNeverArrives() throws {
        let r = try drive(tempDir(), mic: chunked(sine(80_000), 100, 320), system: [])
        #expect(r.mic.samples.count == 80_000 && r.system.samples.isEmpty)
        #expect(r.system.header == TrackWriter.wavHeader(dataBytes: 0))
    }

    @Test func singleTrackLeavesPhaseAAfterTwoSeconds() throws {
        // One track alone reaches disk after a bounded wait instead of piling up in memory.
        let dir = tempDir()
        let a = try TrackAligner(mic: TrackWriter(finalURL: dir.appendingPathComponent("m.wav")),
                                 system: TrackWriter(finalURL: dir.appendingPathComponent("s.wav")))
        for c in chunked(sine(80_000), 100, 320) {
            try a.handle(c, track: .mic)
            let elapsed = Double(c.pts - ns(100)) / 1e9
            #expect((a.startPts != nil) == (elapsed >= 2), "at \(elapsed) s")
        }
        #expect(a.mic.framesWritten == 80_000)
        #expect(a.startPts == ns(100))
        try a.finish()
    }

    @Test func phaseAIsWrittenInPtsOrder() throws {
        // Chunks held before start_pts is fixed are written sorted by PTS.
        let c = chunked(sine(960), 100, 320)
        let r = try drive(tempDir(), mic: [c[1], c[0], c[2]], system: [])
        #expect(r.mic.samples == PCM.int16(sine(960)[...]))
    }

    @Test func eachTrackKeepsOwnLength() throws {
        // System audio stopped early (issue #18): the mic keeps its full length, the system track its own.
        let r = try drive(tempDir(), mic: chunked(sine(80_000, freq: 880), 100, 320),
                          system: chunked(sine(16_000), 100, 320))
        #expect(r.mic.samples.count == 80_000)
        #expect(r.system.samples.count == 16_000)
    }

    @Test func finishWithoutSamplesWritesEmptyWavs() throws {
        let r = try drive(tempDir(), mic: [], system: [])
        #expect(r.mic.samples.isEmpty && r.system.samples.isEmpty && r.aligner.startPts == nil)
    }

    @Test func abortLeavesBothPartFiles() throws {
        let dir = tempDir()
        let a = try TrackAligner(mic: TrackWriter(finalURL: dir.appendingPathComponent("m.wav")),
                                 system: TrackWriter(finalURL: dir.appendingPathComponent("s.wav")))
        for (m, s) in zip(chunked(sine(16_000), 100, 320), chunked(sine(8_000), 100, 320)) {
            try a.handle(m, track: .mic)
            try a.handle(s, track: .system)
        }
        a.abort()
        try a.handle(chunked(sine(320), 101, 320)[0], track: .mic)  // ignored
        #expect(try readWav(a.mic.partURL).dataSize == 16_000)
        #expect(try readWav(a.system.partURL).dataSize == 16_000)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("m.wav").path))
    }

    @Test func resampledTrackDoesNotAccumulateSmallPtsJumps() throws {
        // Losing single 10 ms IO cycles (each below the tolerance) must not drift: losses add up, so
        // placement follows the accumulated PTS. A real 25-min meeting drifted by > 100 ms this way.
        var reports: [(CaptureTrack, Double)] = []
        let chunks = chunked(sine(480_000, sr: 48_000), 100, 480, rate: 48_000)
        var kept = chunks.enumerated().filter { $0.offset % 10 != 9 }.map(\.element)
        for i in kept.indices where kept[i].pts == ns(109) { kept[i].samples = [Float](repeating: 0.9, count: 480) }
        let r = try drive(tempDir(), mic: kept, system: [], onReanchor: { reports.append(($0, $1)); return false })
        let found = r.mic.samples.firstIndex { Double($0) > 0.8 * 32_767 }!
        #expect(abs(found - 9 * 16_000) <= 320 + 16, "marker at \(found)")
        #expect(!reports.isEmpty && reports.allSatisfy { $0.0 == .mic })
    }

    @Test func reanchorJumpWithinToleranceIsFollowed() throws {
        // A re-anchor at 20.01 ms drift: the jump rounds to 320 frames, which Python's writer absorbed as
        // jitter (the track then stayed 20 ms early until the next re-anchor, and the errors added up).
        // An anchor is placed at its PTS: the marker after the jump lands exactly where its stamp says.
        var reanchors = 0
        var mic = chunked(sine(48_000, sr: 48_000), 100, 480, rate: 48_000)
        let jumped = chunked([Float](repeating: 0.9, count: 480) + sine(47_520, sr: 48_000), 101.020_01, 480, rate: 48_000)
        mic += jumped
        let r = try drive(tempDir(), mic: mic, system: [], onReanchor: { _, _ in reanchors += 1; return false })
        #expect(reanchors == 1)
        let found = r.mic.samples.firstIndex { Double($0) > 0.8 * 32_767 }!
        #expect(abs(found - (16_000 + 320)) <= 1, "marker at \(found)")
        #expect(maxAbs(r.mic.samples[(16_000 + 5)..<(16_000 + 315)]) == 0)  // the 20 ms gap, zero-padded
    }

    @Test func resampledFirstChunkNearStartIsPlacedAtItsOffset() throws {
        // The mic (48 kHz) starts 10 ms (160 frames, inside the 320 tolerance) after the system track.
        // Python appended it at frame 0, 10 ms early; its first chunk is an anchor, so it lands at 160.
        let system = chunked(sine(16_000), 100, 320)
        let mic = chunked([Float](repeating: 0.9, count: 48_000), 100.01, 480, rate: 48_000)
        let r = try drive(tempDir(), mic: mic, system: system)
        let m = r.mic.samples
        #expect(maxAbs(m[0..<160]) == 0)
        #expect(m[160...].prefix(10).allSatisfy { Double($0) > 0.5 * 32_767 })
        #expect(abs(m.count - (160 + 16_000)) <= 1)
    }

    @Test func droppedAnchorPassesToTheNextChunk() throws {
        // A switch to a 16 kHz device whose first chunk lies wholly inside what is on disk: the next
        // chunk anchors instead, so its 200-frame overlap is trimmed rather than appended as jitter.
        let first = chunked(sine(48_000, sr: 48_000), 100, 480, rate: 48_000)  // 16 000 frames
        let inside = TimedChunk(pts: ns(100.9), samples: [Float](repeating: -0.5, count: 320))
        let next = TimedChunk(pts: ns(100) + 15_800 * 62_500, samples: (0..<1_000).map { Float($0) / 2_000 })
        let r = try drive(tempDir(), mic: first + [inside, next], system: chunked(sine(16_000), 100, 320))
        #expect(r.mic.samples.count == 16_800)
        #expect(Array(r.mic.samples[16_000...]) == PCM.int16(next.samples[200...]))
    }

    @Test func frameOffsetRoundsHalfToEven() {
        #expect(TrackAligner.frameOffset(0) == 0)
        #expect(TrackAligner.frameOffset(62_500 * 3 / 2) == 2)  // 1.5 → 2
        #expect(TrackAligner.frameOffset(62_500 * 5 / 2) == 2)  // 2.5 → 2
        #expect(TrackAligner.frameOffset(-62_500 * 3 / 2) == -2)
        #expect(TrackAligner.frameOffset(62_500 * 16_000 * 3_600) == 57_600_000)
    }
}
