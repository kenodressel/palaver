import Foundation
import Testing
@testable import PalaverCapture

/// The source and fallback tests of test_capture_recorder.py, with fake sources (no device is opened).
private final class Rig: @unchecked Sendable {
    var taps: [FakeSource] = []
    var mics: [FakeSource] = []
    var screens: [FakeScreenCapture] = []
    let log = LogLines()
    let debug = LogLines()
    let dir = tempDir()
    var sleeps: [Double] = []
    var rec: CaptureRecorder!

    init(tapFails: Bool = false, micFails: Bool = false, screenFailures: Int = 0, monitor: CaptureMonitor? = nil,
         writerThread: Bool = true, clock: (() -> Double)? = nil, ringCapacity: Int = 1 << 20) {
        let sources = CaptureSources(
            systemTap: { [self] ring in
                taps.append(FakeSource(ring: ring, error: tapFails ? ProcessTapError("tap denied", osStatus: -1) : nil))
                return taps.last!
            },
            mic: { [self] ring in
                mics.append(FakeSource(ring: ring, error: micFails ? AVMicError("microphone access denied", isPermission: true) : nil))
                return mics.last!
            },
            screenCapture: { [self] mic, system in
                screens.append(FakeScreenCapture(mic: mic, system: system, failures: screenFailures))
                return screens.last!
            })
        rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"),
                              systemURL: dir.appendingPathComponent("system.wav"), sources: sources, monitor: monitor,
                              clock: clock ?? monotonicSeconds, log: log.sink, debug: debug.sink,
                              sleep: { [self] in sleeps.append($0) }, ringCapacity: ringCapacity, runsWriterThread: writerThread)
    }

    var screenCalls: [[Bool]] { screens.flatMap { $0.calls.map { [$0.mic, $0.system] } } }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
    func wav(_ name: String) throws -> Wav { try readWav(dir.appendingPathComponent(name)) }
}

/// Records what the health monitor is shown; throws when told to.
final class RecordingMonitor: CaptureMonitor, @unchecked Sendable {
    let statuses = Locked<[CaptureStatus]>([])
    let chunks = Locked(0)
    let begins = Locked<[Double]>([])
    var fails = false
    struct Boom: Error {}
    func begin(now: Double) throws { begins.with { $0.append(now) } }
    func chunk(_ track: CaptureTrack, now: Double, pts: Int64, samples: [Float], rate: Double) throws {
        if fails { throw Boom() }
        chunks.with { $0 += 1 }
    }
    func reanchor(_ track: CaptureTrack, now: Double, drift: Double) throws -> Bool {
        if fails { throw Boom() }
        return false
    }
    func check(_ status: CaptureStatus) throws {
        if fails { throw Boom() }
        statuses.with { $0.append(status) }
    }
    func close(now: Double) throws { if fails { throw Boom() } }
}

@Suite struct CaptureRecorderTests {
    @Test func defaultSourcesNeedNoScreenCapture() throws {
        // Mic via AVCaptureSession + system audio via the process tap: no Screen Recording permission.
        let rig = Rig()
        try rig.rec.start()
        #expect(rig.rec.micSource == "avcapture" && rig.rec.systemSource == "process-tap")
        #expect(rig.screens.isEmpty && rig.rec.missing.isEmpty)
        let signal = sine(96_000, sr: 48_000)
        for i in stride(from: 0, to: signal.count, by: 480) {
            let pts = ns(100) + Int64((Double(i) / 48_000 * 1e9).rounded())
            push(rig.taps[0].ring, pts: pts, Array(signal[i..<i + 480]), rate: 48_000)
            push(rig.mics[0].ring, pts: pts, Array(signal[i..<i + 480]), rate: 48_000)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let lengths = try #require(try rig.rec.stop())
        #expect(rig.taps[0].stopped && rig.mics[0].stopped)
        for name in ["mic_raw.wav", "system.wav"] {
            let x = try rig.wav(name).samples
            #expect(abs(x.count - 32_000) <= 2)
            #expect(abs(dominantFreq(x[8_000..<16_000]) - 440) < 2)  // half a second: Goertzel is slow in debug
        }
        #expect(abs(lengths.mic - 32_000) <= 2 && abs(lengths.system - 32_000) <= 2)
        #expect(!rig.exists("mic_raw.wav.part") && !rig.exists("system.wav.part"))
    }

    @Test func fallsBackToSCStreamForFailedSource() throws {
        let micRig = Rig(micFails: true)
        try micRig.rec.start()
        try micRig.rec.stop()
        #expect(micRig.screenCalls == [[true, false]])
        #expect(micRig.rec.micSource == "scstream" && micRig.rec.systemSource == "process-tap" && micRig.rec.missing.isEmpty)
        #expect(micRig.log.text.contains(
            "warning: microphone via AVCaptureSession unavailable (microphone access denied); trying ScreenCaptureKit."))
        #expect(micRig.screens[0].stopped)

        let tapRig = Rig(tapFails: true)
        try tapRig.rec.start()
        try tapRig.rec.stop()
        #expect(tapRig.screenCalls == [[false, true]])
        #expect(tapRig.rec.systemSource == "scstream" && tapRig.rec.micSource == "avcapture" && tapRig.rec.missing.isEmpty)
        #expect(tapRig.log.text.contains("warning: system audio tap unavailable (tap denied); falling back to "
            + "ScreenCaptureKit system audio, which other recorders running in parallel can starve."))
    }

    @Test func fallbackFillsTheRingOfTheFailedTrack() throws {
        let rig = Rig(micFails: true)
        try rig.rec.start()
        let screen = try #require(rig.screens.first)
        push(screen.mic, pts: ns(100), sine(16_000), rate: 16_000)
        push(rig.taps[0].ring, pts: ns(100), sine(16_000, freq: 880), rate: 16_000)
        Thread.sleep(forTimeInterval: 0.1)
        let lengths = try #require(try rig.rec.stop())
        #expect(lengths.mic == 16_000 && lengths.system == 16_000)
    }

    @Test func recordsSystemAudioAloneWhenNoMicSourceWorks() throws {
        // Losing one track must not throw away the other.
        let rig = Rig(micFails: true, screenFailures: 99)
        try rig.rec.start()
        #expect(rig.rec.missing == ["microphone"] && rig.rec.systemSource == "process-tap" && rig.rec.micSource == nil)
        #expect(rig.taps[0].started)
        #expect(rig.log.text.contains("⚠ recording without the microphone: SCStream startCapture failed"))
        try rig.rec.stop()
        #expect(rig.exists("system.wav"))
    }

    @Test func recordsMicAloneWhenNoSystemSourceWorks() throws {
        let rig = Rig(tapFails: true, screenFailures: 99)
        try rig.rec.start()
        #expect(rig.rec.missing == ["system audio"] && rig.rec.micSource == "avcapture")
        #expect(rig.log.text.contains("⚠ recording without system audio (the other participants): SCStream startCapture failed"))
        try rig.rec.stop()
        #expect(rig.mics[0].stopped)
    }

    @Test func bothFailRaises() throws {
        let rig = Rig(tapFails: true, micFails: true, screenFailures: 99)
        #expect(throws: CaptureError("neither the microphone nor system audio can be recorded: SCStream startCapture failed")) {
            try rig.rec.start()
        }
        #expect(!rig.exists("mic_raw.wav") && rig.exists("mic_raw.wav.part"))  // aborted, left as .part
        #expect(try rig.rec.stop() == nil)
        // Not left half-started: the next start tries again (and fails the same way here).
        #expect(throws: CaptureError("neither the microphone nor system audio can be recorded: SCStream startCapture failed")) {
            try rig.rec.start()
        }
    }

    @Test func retriesTransientSCStreamStartFailure() throws {
        // "Stream failed to start microphone" (-3820), then it works seconds later.
        let rig = Rig(micFails: true, screenFailures: 2)
        try rig.rec.start()
        try rig.rec.stop()
        #expect(rig.screenCalls == [[true, false], [true, false], [true, false]])
        #expect(rig.rec.micSource == "scstream")
        #expect(rig.log.all.filter { $0.contains("retrying") }.count == 2)
        #expect(rig.log.text.contains("warning: SCStream startCapture failed; retrying in 2 s (1/2)"))
        #expect(rig.sleeps == [2, 2])
    }

    @Test func givesUpOnSCStreamAfterRepeatedFailures() throws {
        let rig = Rig(micFails: true, screenFailures: 99)
        try rig.rec.start()
        #expect(rig.screenCalls.count == CaptureRecorder.screenCaptureStartAttempts)
        #expect(rig.rec.missing == ["microphone"])
        try rig.rec.stop()
    }

    @Test func doubleStartRaises() throws {
        let rig = Rig()
        try rig.rec.start()
        #expect(throws: CaptureError("CaptureRecorder already started")) { try rig.rec.start() }
        try rig.rec.stop()
    }

    @Test func knowsTheNativeRateAndTheDevices() throws {
        // For the menu's "mic AirPods (24 kHz)" (issue #47).
        let rig = Rig(writerThread: false)
        try rig.rec.start()
        #expect(rig.rec.micRate == nil && rig.rec.systemRate == nil && rig.rec.micDevice == nil)
        rig.mics[0].deviceName = "AirPods"
        rig.taps[0].deviceName = "AirPods Pro"
        push(rig.mics[0].ring, pts: ns(100), sine(480, sr: 24_000), rate: 24_000)
        push(rig.taps[0].ring, pts: ns(100), sine(960, sr: 48_000), rate: 48_000)
        while rig.rec.drainOnce() {}
        #expect(rig.rec.micRate == 24_000 && rig.rec.systemRate == 48_000)
        #expect(rig.rec.micDevice == "AirPods" && rig.rec.systemDevice == "AirPods Pro")
        try rig.rec.stop()
    }

    @Test func abortLeavesThePartFiles() throws {
        let rig = Rig(writerThread: false)
        try rig.rec.start()
        push(rig.mics[0].ring, pts: ns(100), sine(16_000), rate: 16_000)
        push(rig.taps[0].ring, pts: ns(100), sine(16_000), rate: 16_000)
        rig.rec.abort()
        #expect(rig.taps[0].stopped && rig.mics[0].stopped)
        #expect(!rig.exists("mic_raw.wav") && rig.exists("mic_raw.wav.part"))
        let part = try readWav(rig.dir.appendingPathComponent("mic_raw.wav.part"))
        #expect(part.samples.count == 16_000 && part.dataSize == 32_000)  // drained, header patched
    }

    @Test func aFullRingDropsBuffersAndSaysSoOnceAMinute() throws {
        // The writer fell seconds behind: the callbacks drop instead of blocking or allocating.
        let now = Locked(0.0)
        let rig = Rig(writerThread: false, clock: { now.get }, ringCapacity: 4_096)
        try rig.rec.start()
        let chunk = sine(320)  // 1 280 bytes + a 40-byte header: three fit
        for k in 0..<5 { push(rig.mics[0].ring, pts: ns(100) + Int64(k) * 20_000_000, chunk, rate: 16_000) }
        rig.rec.drainOnce()
        #expect(rig.log.all.filter { $0.hasPrefix("⚠ capture buffer full") } == ["⚠ capture buffer full: 2 microphone buffers dropped"])
        for k in 5..<10 { push(rig.mics[0].ring, pts: ns(100) + Int64(k) * 20_000_000, chunk, rate: 16_000) }  // 1 fits
        while rig.rec.drainOnce() {}
        #expect(rig.log.all.filter { $0.hasPrefix("⚠ capture buffer full") }.count == 1)  // within the minute
        now.with { $0 = 61 }
        rig.rec.drainOnce()  // nothing new dropped: the count still comes out once the minute is over
        #expect(rig.log.all.filter { $0.hasPrefix("⚠ capture buffer full") }.last == "⚠ capture buffer full: 4 microphone buffers dropped")
        rig.rec.drainOnce()
        #expect(rig.log.all.filter { $0.hasPrefix("⚠ capture buffer full") }.count == 2)
        try rig.rec.stop()
    }

    // MARK: - the mic stall watchdog (#18)

    @Test func warnsWhenMicStopsDeliveringAndWhenItResumes() throws {
        let now = Locked(1000.0)
        let rig = Rig(writerThread: false, clock: { now.get })
        try rig.rec.start()
        push(rig.mics[0].ring, pts: ns(100), sine(320), rate: 16_000)
        rig.rec.drainOnce()
        now.with { $0 += 29 }
        rig.rec.checkMicStall()
        #expect(rig.log.all.isEmpty)
        now.with { $0 += 2 }
        rig.rec.checkMicStall()
        rig.rec.checkMicStall()  // no repeat within the reminder interval
        #expect(rig.log.all.filter { $0.contains("no microphone audio for 31 s") }.count == 1)
        #expect(rig.log.text.contains("⚠ no microphone audio for 31 s — ScreenCaptureKit may have stopped delivering "
            + "(display sleep, device change?)."))
        rig.log.clear()
        now.with { $0 += 60 }
        rig.rec.checkMicStall()
        #expect(rig.log.text.contains("no microphone audio for 91 s"))
        rig.log.clear()
        push(rig.mics[0].ring, pts: ns(191), sine(320), rate: 16_000)
        rig.rec.drainOnce()
        #expect(rig.log.text.contains("microphone audio resumed after 91 s."))
        try rig.rec.stop()
    }

    @Test func warnsWhenMicNeverDelivers() throws {
        // A source can start without its mic output ever delivering: the watchdog counts from the start.
        let now = Locked(0.0)
        let rig = Rig(writerThread: false, clock: { now.get })
        try rig.rec.start()
        now.with { $0 = 31 }
        rig.rec.checkMicStall()
        #expect(rig.log.text.contains("no microphone audio for 31 s"))
        try rig.rec.stop()
    }

    @Test func noStallWarningWhenTheMicrophoneIsMissing() throws {
        let now = Locked(0.0)
        let rig = Rig(micFails: true, screenFailures: 99, writerThread: false, clock: { now.get })
        try rig.rec.start()
        rig.log.clear()
        now.with { $0 = 100 }
        rig.rec.checkMicStall()
        #expect(rig.log.all.isEmpty)
        try rig.rec.stop()
    }

    // MARK: - health hooks and write failures

    @Test func theMonitorSeesChunksStatusAndStalls() throws {
        let now = Locked(0.0)
        let monitor = RecordingMonitor()
        let rig = Rig(monitor: monitor, writerThread: false, clock: { now.get })
        try rig.rec.start()
        rig.taps[0].problem = "device"
        push(rig.mics[0].ring, pts: ns(100), sine(16_000), rate: 16_000)
        push(rig.taps[0].ring, pts: ns(100), sine(16_000), rate: 16_000)
        while rig.rec.drainOnce() {}
        rig.rec.checkHealth()
        now.with { $0 = 0.1 }
        rig.rec.checkHealth()  // within 0.25 s: not asked again
        now.with { $0 = 31 }
        rig.rec.checkHealth()
        let statuses = monitor.statuses.get
        #expect(statuses.count == 2 && monitor.chunks.get == 2)
        #expect(statuses[0].written == [.mic: 1, .system: 1] && statuses[0].startPts == ns(100))
        #expect(statuses[0].access == [.system: "device"])
        #expect(!statuses[0].micStalled && !statuses[0].systemStalled)
        #expect(statuses[1].micStalled && statuses[1].systemStalled)
        try rig.rec.stop()
    }

    @Test func aFailingHealthMonitorNeverStopsTheRecording() throws {
        // Whatever the monitor throws, the audio reaches disk; failures are debug lines, and the
        // log says once that the warnings are off.
        let now = Locked(0.0)
        let monitor = RecordingMonitor()
        monitor.fails = true
        let rig = Rig(monitor: monitor, writerThread: false, clock: { now.get })
        try rig.rec.start()
        for k in 0..<100 {
            let pts = ns(100) + Int64(k) * 10_000_000
            push(rig.mics[0].ring, pts: pts, sine(160), rate: 16_000)
            push(rig.taps[0].ring, pts: pts, sine(160), rate: 16_000)
            now.with { $0 = Double(k) / 100 }
            while rig.rec.drainOnce() {}
            rig.rec.checkHealth()
        }
        let lengths = try #require(try rig.rec.stop())
        #expect(lengths.mic == 16_000 && lengths.system == 16_000)
        #expect(rig.debug.all.filter { $0.hasPrefix("health monitor failed") }.count == 1)
        #expect(rig.log.all.filter { $0 == "Audio health checks failed; warnings are off for this recording" }.count == 1)
    }

    @Test func aDiskWriteErrorIsReportedAndTheRecordingGoesOn() throws {
        // Python's writer thread died on an OSError and the queues grew in silence. Here the error
        // is logged once, shown to the monitor, and later chunks still land at their true offset.
        let now = Locked(0.0)
        let monitor = RecordingMonitor()
        let rig = Rig(monitor: monitor, writerThread: false, clock: { now.get })
        let full = Locked(false)
        rig.rec.makeWriter = { url in
            try TrackWriter(finalURL: url, io: TrackWriter.FileIO(
                pwrite: { fd, buf, n, off in
                    if full.get, off > 44 { errno = ENOSPC; return -1 }
                    return Darwin.pwrite(fd, buf, n, off)
                },
                ftruncate: { Darwin.ftruncate($0, $1) }))
        }
        try rig.rec.start()
        func second(_ s: Int) {
            push(rig.mics[0].ring, pts: ns(100 + Double(s)), sine(16_000), rate: 16_000)
            push(rig.taps[0].ring, pts: ns(100 + Double(s)), sine(16_000), rate: 16_000)
            while rig.rec.drainOnce() {}
        }
        second(0)
        full.with { $0 = true }
        second(1)
        second(2)
        #expect(rig.rec.writeFailures.keys.sorted { $0.rawValue < $1.rawValue } == [.mic, .system])
        #expect(rig.log.all.filter { $0.hasPrefix("⚠ cannot write the microphone track:") }.count == 1)
        #expect(rig.log.text.contains("No space left on device"))
        now.with { $0 = 1 }
        rig.rec.checkHealth()
        #expect(monitor.statuses.get.last?.writeFailures.count == 2)
        full.with { $0 = false }
        second(3)
        #expect(rig.rec.writeFailures.isEmpty)
        #expect(rig.log.text.contains("writing the microphone track works again"))
        let lengths = try #require(try rig.rec.stop())
        #expect(lengths.mic == 64_000 && lengths.system == 64_000)  // seconds 1-2 zero-padded, 3 at its place
        let mic = try rig.wav("mic_raw.wav").samples
        #expect(mic[16_000..<48_000].allSatisfy { $0 == 0 } && maxAbs(mic[48_000...]) > 9_000)
    }

    // MARK: - the real monitor on the recorder (Task 6 carry-forwards)

    @Test func aFullRingBecomesADroppedIncident() throws {
        // The writer fell behind: buffers were thrown away. Counted per track in the status, an
        // incident for the health monitor, and it ends after 5 s without a new loss.
        let now = Locked(0.0)
        let events = Locked<[String]>([])
        let monitor = AudioHealthMonitor(problemsURL: nil, events: { _, name, f in
            events.with { $0.append(name + "/" + ((f.first { $0.0 == "kind" }?.1 as? String) ?? "")) }
        })
        let rig = Rig(monitor: monitor, writerThread: false, clock: { now.get }, ringCapacity: 4_096)
        try rig.rec.start()
        for k in 0..<20 { push(rig.mics[0].ring, pts: ns(100) + Int64(k) * 10_000_000, sine(160), rate: 16_000) }
        while rig.rec.drainOnce() {}
        now.with { $0 = 1 }
        rig.rec.checkHealth()
        let dropped = rig.rec.currentStatus(1).dropped
        #expect(dropped[.mic]! > 0 && dropped[.system] == nil)
        #expect(events.get == ["audio_problem/dropped"])
        #expect(monitor.openProblems.map(\.kind) == ["dropped"] && monitor.openProblems[0].track == "mic")
        for t in 2...8 {
            now.with { $0 = Double(t) }
            rig.rec.checkHealth()
        }
        #expect(events.get == ["audio_problem/dropped", "audio_problem_over/dropped"])
        try rig.rec.stop()
    }

    @Test func aDiskWriteErrorBecomesAWriteIncident() throws {
        let now = Locked(0.0)
        let events = Locked<[String]>([])
        let monitor = AudioHealthMonitor(problemsURL: nil, events: { _, name, f in
            events.with { $0.append(name + "/" + ((f.first { $0.0 == "kind" }?.1 as? String) ?? "") + "/"
                                    + ((f.first { $0.0 == "track" }?.1 as? String) ?? "")) }
        })
        let rig = Rig(monitor: monitor, writerThread: false, clock: { now.get })
        let full = Locked(false)
        rig.rec.makeWriter = { url in
            try TrackWriter(finalURL: url, io: TrackWriter.FileIO(
                pwrite: { fd, buf, n, off in
                    if full.get, off > 44 { errno = ENOSPC; return -1 }
                    return Darwin.pwrite(fd, buf, n, off)
                },
                ftruncate: { Darwin.ftruncate($0, $1) }))
        }
        try rig.rec.start()
        func second(_ s: Int) {
            push(rig.mics[0].ring, pts: ns(100 + Double(s)), sine(16_000), rate: 16_000)
            push(rig.taps[0].ring, pts: ns(100 + Double(s)), sine(16_000), rate: 16_000)
            while rig.rec.drainOnce() {}
        }
        second(0)
        full.with { $0 = true }
        second(1)
        now.with { $0 = 1 }
        rig.rec.checkHealth()
        #expect(events.get == ["audio_problem/write/mic", "audio_problem/write/system"])
        full.with { $0 = false }
        second(3)
        now.with { $0 = 2 }
        rig.rec.checkHealth()
        #expect(events.get.suffix(2) == ["audio_problem_over/write/mic", "audio_problem_over/write/system"])
        try rig.rec.stop()
    }

    @Test func theRecorderStartsTheMonitorAfresh() throws {
        let monitor = RecordingMonitor()
        let rig = Rig(monitor: monitor, writerThread: false, clock: { 5 })
        try rig.rec.start()
        #expect(monitor.begins.get == [5])
        try rig.rec.stop()
    }
}

// MARK: task 8: a writer stuck in a write does not hold stop() for ever

@Suite struct StuckWriterTests {
    @Test func stopGivesUpOnAStuckWriterAndLeavesThePartFiles() throws {
        let rig = Rig()
        let gate = DispatchSemaphore(value: 0)
        let blocked = Locked(false)
        // Data writes block until the gate opens (a hung disk); the header (offset 0) goes through.
        let io = TrackWriter.FileIO(pwrite: { fd, buf, n, off in
            if off >= TrackWriter.headerSize {
                blocked.with { $0 = true }
                gate.wait()
                gate.signal()
            }
            return Darwin.pwrite(fd, buf, n, off)
        }, ftruncate: { Darwin.ftruncate($0, $1) })
        rig.rec.makeWriter = { try TrackWriter(finalURL: $0, io: io) }
        rig.rec.writerStopTimeout = 0.5
        try rig.rec.start()
        let signal = sine(48_000, sr: 48_000)
        for i in stride(from: 0, to: signal.count, by: 480) {
            let pts = ns(100) + Int64((Double(i) / 48_000 * 1e9).rounded())
            push(rig.taps[0].ring, pts: pts, Array(signal[i..<i + 480]), rate: 48_000)
            push(rig.mics[0].ring, pts: pts, Array(signal[i..<i + 480]), rate: 48_000)
        }
        #expect(waitFor(5) { blocked.with { $0 } })
        let started = Date()
        #expect(throws: CaptureError.self) { try rig.rec.stop() }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(rig.log.text.contains("leaving the .part files for `process` to recover"))
        #expect(rig.exists("mic_raw.wav.part") && rig.exists("system.wav.part"))
        #expect(!rig.exists("mic_raw.wav") && !rig.exists("system.wav"))
        gate.signal()  // the disk answers: the abandoned writers patch their headers
        #expect(waitFor(5) {
            guard let d = try? Data(contentsOf: rig.dir.appendingPathComponent("mic_raw.wav.part")), d.count > 44 else { return false }
            let size = d[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Int(size) == d.count - 44
        })
    }
}
