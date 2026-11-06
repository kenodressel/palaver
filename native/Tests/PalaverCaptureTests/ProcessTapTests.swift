import CoreAudio
import Foundation
import Testing
@testable import PalaverCapture

/// test_process_tap.py, against a fake Core Audio: no tap, no aggregate, no IO.
@Suite struct ProcessTapTests {
    private func tap(_ backend: FakeTapBackend, ring: CaptureRing = CaptureRing(capacity: 1 << 20),
                     pids: [pid_t] = [1234], poll: Double? = nil, clock: (() -> Double)? = nil,
                     log: LogLines = LogLines()) -> ProcessTap {
        if let clock {
            return ProcessTap(sink: ring, excludedPIDs: { pids }, backend: backend, routePollInterval: poll,
                              clock: clock, log: log.sink)
        }
        return ProcessTap(sink: ring, excludedPIDs: { pids }, backend: backend, routePollInterval: poll, log: log.sink)
    }

    private let teardown20: [Call] = [.stop(20, FakeTapBackend.io), .destroyIO(20, FakeTapBackend.io),
                                      .destroyAggregate(20), .destroyTap(10)]

    @Test func startTranslatesPidsAndWiresAggregateUID() throws {
        let backend = FakeTapBackend()
        let ring = CaptureRing(capacity: 1 << 20)
        let tap = tap(backend, ring: ring, pids: [1234, 4321])
        try tap.start()
        #expect(backend.state.get.excluded == [99])
        #expect(backend.calls.contains(.createAggregate("tap-uid", "BuiltInSpeakerDevice")))
        let chunks = drain(ring)
        #expect(chunks.count == 1)
        #expect(chunks[0].pts == 123_000_000)  // host time → ns, as AudioConvertHostTimeToNanos
        #expect(chunks[0].rate == 48_000)
        #expect(chunks[0].samples.count == 480 && chunks[0].samples.allSatisfy { $0 == 0.5 })
        tap.stop()
        #expect(Array(backend.calls.suffix(4)) == teardown20)
    }

    @Test func excludesOwnAndWorkerPidsAskedAtStart() throws {
        // The app's own pid first (it must translate), then its workers (they may be gone).
        let backend = FakeTapBackend()
        backend.state.with { $0.translateThrows = [777] }
        var asked = 0
        let log = LogLines()
        let tap = ProcessTap(sink: CaptureRing(capacity: 1 << 16), excludedPIDs: { asked += 1; return [500, 777, 500, 0, 501] },
                             backend: backend, routePollInterval: nil, log: log.sink)
        try tap.start()
        #expect(asked == 1)
        #expect(backend.state.get.excluded == [1500, 1501])
        #expect(log.text.contains("excluded PID 777 is not a CoreAudio process"))
        tap.stop()

        let failing = FakeTapBackend()
        failing.state.with { $0.translateThrows = [500] }
        let own = ProcessTap(sink: CaptureRing(capacity: 1 << 16), excludedPIDs: { [500, 501] }, backend: failing,
                             routePollInterval: nil)
        #expect(throws: ProcessTapError.self) { try own.start() }
    }

    @Test func ioCallbackToleratesWhatCoreAudioHandsIt() throws {
        // Python had to return inOutputTime (pyobjc, issue #19); the Swift block returns nothing.
        // What remains: odd buffers never crash and never stop the next one from arriving.
        let backend = FakeTapBackend()
        let ring = CaptureRing(capacity: 1 << 20)
        let tap = tap(backend, ring: ring)
        try tap.start()
        _ = drain(ring)
        let handler = try #require(backend.state.get.handler)
        handler(nil, nil, nil)
        var empty = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        withUnsafePointer(to: &empty) { handler(nil, $0, nil) }
        callIO(handler, [1, 2, 3, 4], channels: 1, host: 0)  // no host time: dropped
        callIO(handler, [0.25, 0.25, 0.25, 0.25], channels: 0, host: 5)  // 0 channels: the tap format's (2)
        let chunks = drain(ring)
        #expect(chunks.count == 1 && chunks[0].samples == [0.25, 0.25] && chunks[0].pts == 5)
        tap.stop()
    }

    @Test func startSucceedsWhileNothingIsPlaying() throws {
        // A tap that is quiet at first must not cost the recording; a quiet one is rebuilt later.
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let tap = tap(backend)
        try tap.start()
        tap.stop()
        #expect(Array(backend.calls.suffix(4)) == teardown20)
    }

    @Test func startFailureCleansUp() {
        let backend = FakeTapBackend()
        backend.state.with { $0.failStart = true }
        let tap = tap(backend)
        #expect(throws: ProcessTapError("AudioDeviceStart failed", osStatus: -1)) { try tap.start() }
        #expect(Array(backend.calls.suffix(4)) == teardown20)
    }

    @Test func stopIsIdempotent() throws {
        let backend = FakeTapBackend()
        let tap = tap(backend)
        try tap.start()
        tap.stop()
        let after = backend.calls
        tap.stop()
        #expect(backend.calls == after)
        #expect(throws: Never.self) { try tap.start() }  // and it starts again
        tap.stop()
    }

    @Test func permissionDeniedMapsText() throws {
        // process_tap.py:408-423, the texts the status and the log show.
        #expect(ProcessTapError.forStatus("process tap creation failed", kAudioHardwareIllegalOperationError).message
            == "permission denied - System Settings -> Privacy -> System Audio Recording")
        #expect(ProcessTapError.forStatus("process tap creation failed", kAudioHardwareUnsupportedOperationError).message
            == "requires macOS 14.4+ and an audio output device")
        #expect(ProcessTapError.forStatus("aggregate device creation failed", 1_852_797_029).message
            == "permission denied - System Settings -> Privacy -> System Audio Recording")  // 'nope' is the illegal-operation code
        #expect(ProcessTapError.forStatus("aggregate device creation failed", 2_003_329_396).message
            == "aggregate device creation failed: OSStatus 2003329396 ('what')")
        #expect(ProcessTapError.forStatus("IO proc registration failed", -50).message
            == "IO proc registration failed: OSStatus -50")
        #expect(ProcessTapError.forStatus("x", 7).osStatus == 7)
    }

    @Test func outputChangeRebuildsTap() throws {
        // The aggregate's clock is the default output at creation; AirPods connecting must rebuild it.
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let log = LogLines()
        let tap = tap(backend, poll: 0.01, log: log)
        try tap.start()
        backend.state.with {
            $0.nextAggregate = 21
            $0.outputUID = "AirPods-UID"
        }
        #expect(waitFor { backend.calls.contains(.createAggregate("tap-uid", "AirPods-UID")) })
        #expect(waitFor { backend.calls.contains(.start(21, FakeTapBackend.io)) })
        let calls = backend.calls
        let teardown = try #require(calls.firstIndex(of: .destroyAggregate(20)))
        let rebuild = try #require(calls.firstIndex(of: .createAggregate("tap-uid", "AirPods-UID")))
        #expect(teardown < rebuild)
        #expect(log.text.contains("default output changed (BuiltInSpeakerDevice → AirPods-UID); rebuilding system audio tap"))
        tap.stop()
        #expect(Array(backend.calls.suffix(4)) == [.stop(21, FakeTapBackend.io), .destroyIO(21, FakeTapBackend.io),
                                                   .destroyAggregate(21), .destroyTap(10)])
    }

    @Test func chunksCarryTheDevicesRateNotTheTaps() throws {
        // AirPods in a call run at 24 kHz while the tap still says 48 kHz.
        let backend = FakeTapBackend()
        backend.state.with { $0.deviceRate = 24_000 }
        let ring = CaptureRing(capacity: 1 << 20)
        let tap = tap(backend, ring: ring)
        try tap.start()
        #expect(drain(ring).map(\.rate) == [24_000])
        tap.stop()
    }

    @Test func followsARateChangeOnTheSameOutput() throws {
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let log = LogLines()
        let tap = tap(backend, poll: 0.01, log: log)
        try tap.start()
        backend.state.with { $0.deviceRate = 24_000 }
        #expect(waitFor { tap.sourceRate == 24_000 })
        #expect(backend.aggregates == 1)
        #expect(log.text.contains("system audio rate 48000 Hz → 24000 Hz"))
        tap.stop()
    }

    @Test func routeWatcherStopsWithTap() throws {
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let tap = tap(backend, poll: 0.01)
        try tap.start()
        tap.stop()
        let calls = backend.calls
        backend.state.with { $0.outputUID = "AirPods-UID" }
        #expect(!waitFor(0.1) { backend.calls != calls })
    }

    @Test func routeWatcherSurvivesRebuildErrors() throws {
        // The old aggregate is already gone: a failing rebuild has to keep retrying, and says "device".
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let log = LogLines()
        let tap = tap(backend, poll: 0.01, log: log)
        try tap.start()
        backend.state.with {
            $0.aggregateFailures = 1
            $0.nextAggregate = 21
            $0.outputUID = "AirPods-UID"
        }
        #expect(waitFor { backend.calls.contains(.start(21, FakeTapBackend.io)) })
        #expect(log.text.contains("rebuilding system audio tap failed; retrying"))
        #expect(waitFor { tap.problem == nil })
        tap.stop()
    }

    @Test func failedRebuildIsADeviceProblemRetriedEveryTick() throws {
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let log = LogLines()
        let tap = tap(backend, clock: { 0 }, log: log)
        try tap.start()
        backend.state.with {
            $0.aggregateFailures = 3
            $0.aggregateError = ProcessTapError.forStatus("aggregate device creation failed", 1_852_797_029)
            $0.outputUID = "Headphones"
        }
        tap.checkRoute()
        #expect(tap.problem == "device")
        tap.checkRoute()
        tap.checkRoute()
        #expect(tap.problem == "device" && backend.aggregates == 1)
        #expect(log.all.filter { $0.hasPrefix("rebuilding system audio tap failed") }.count == 1)  // said once
        backend.state.with { $0.nextAggregate = 22 }
        tap.checkRoute()
        #expect(tap.problem == nil && backend.aggregates == 2)
        #expect(log.text.contains("system audio tap rebuilt; recording again"))
        tap.stop()
    }

    // MARK: - quiet rebuilds, with a stepped clock

    private func quietTap(_ backend: FakeTapBackend, _ now: Locked<Double>, ring: CaptureRing = CaptureRing(capacity: 1 << 20),
                          log: LogLines = LogLines()) throws -> ProcessTap {
        let tap = ProcessTap(sink: ring, excludedPIDs: { [1234] }, backend: backend, routePollInterval: nil,
                             clock: { now.get }, log: log.sink)
        try tap.start()
        return tap
    }

    @Test func quietTapAfterTheAirPodsSwitchToACallIsRebuilt() throws {
        // A Slack call on AirPods: built at 48 kHz, the call took them to 24 kHz a second later and
        // the tap delivered nothing. Built on a device already at 24 kHz, it records.
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let now = Locked(0.0), ring = CaptureRing(capacity: 1 << 20), log = LogLines()
        let tap = try quietTap(backend, now, ring: ring, log: log)
        now.with { $0 = 1 }
        backend.state.with { $0.deviceRate = 24_000 }
        tap.checkRoute()
        #expect(tap.sourceRate == 24_000 && backend.aggregates == 1)
        now.with { $0 = 4.9 }
        tap.checkRoute()
        #expect(backend.aggregates == 1)

        now.with { $0 = 5 }
        backend.state.with {
            $0.deliver = true
            $0.nextAggregate = 21
        }
        tap.checkRoute()
        #expect(backend.aggregates == 2 && backend.calls.contains(.destroyAggregate(20)))
        #expect(drain(ring).map(\.rate) == [24_000])
        #expect(log.text.contains("system audio tap delivered nothing for 5 s; rebuilding it"))
        for second in 6..<30 {
            now.with { $0 = Double(second) }
            backend.buffer()
            tap.checkRoute()
        }
        #expect(backend.aggregates == 2)
        #expect(log.text.contains("system audio tap delivers again"))
        tap.stop()
    }

    @Test func nothingDeliveredRebuildsWithBackoff() throws {
        // A quiet meeting on an output that delivers nothing while nothing plays is not rebuilt every
        // few seconds: 5 s, then twice as long each time, at most 60 s.
        let backend = FakeTapBackend()
        backend.state.with { $0.deliver = false }
        let now = Locked(0.0)
        let tap = try quietTap(backend, now)
        var rebuilt: [Double] = []
        for tick in 1...400 {
            now.with { $0 = Double(tick) / 2 }
            let before = backend.aggregates
            tap.checkRoute()
            if backend.aggregates > before { rebuilt.append(now.get) }
        }
        #expect(rebuilt == [5, 15, 35, 75, 135, 195])
        tap.stop()
    }

    @Test func aTapThatDeliversIsNeverRebuilt() throws {
        let backend = FakeTapBackend()
        let now = Locked(0.0)
        let tap = try quietTap(backend, now)
        for tick in 1..<200 {
            now.with { $0 = Double(tick) / 10 }
            backend.buffer()
            tap.checkRoute()
        }
        #expect(backend.aggregates == 1)
        tap.stop()
    }

    @Test func formatsOSStatusLikePython() {
        #expect(formatOSStatus(1_852_797_029) == "1852797029 ('nope')")
        #expect(formatOSStatus(-10_863) == "-10863")
        #expect(formatOSStatus(1) == "1")
    }
}
