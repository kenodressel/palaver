import Accelerate
import CoreAudio
import Foundation
import Testing
@testable import PalaverCapture

// The device matrix (test_device_matrix.py, issue #50): every audio setup Palaver meets, replayed
// offline through the real capture path. Fakes sit only at the operating-system boundary: a fake
// Core Audio (the tap's backend: devices, aggregate, IO callbacks with host-time stamps) and a fake
// AVFoundation (the microphone's backend: default input, sessions delivering raw PCM bytes).
// `ProcessTap`, `AVMic`, `CaptureRecorder` with its rings, decoder, resamplers and writers are the
// production code. Nothing plays sound or opens a microphone.
//
// Each row replays a known signal (a tone per track and clicks at known times) and asserts what
// reaches disk: the content's speed (the tone's pitch), the track's length against the clock, and
// how far each click landed from its true time. A healthy row raises no incident; the rows going
// wrong (a misread rate, a muted microphone, a lost permission, ...) check AudioHealth's incidents.

private let T0 = 1000.0  // host time at the start, seconds
private let STEP = 0.01  // one IO cycle
private let LATENCY = 0.004  // from a buffer's host time to its arrival in the recorder
private let micTone = 300.0, systemTone = 500.0
private let marks = [2.5, 7.5, 12.5, 17.5, 22.5, 27.5, 32.5, 37.5]  // clicks, seconds from the start
private let driftLimit = Double(ptsToleranceFrames) / Double(captureSampleRate)  // 20 ms

/// What is said (mic) or played (system) at host time `start + i / rate` (vectorised: debug builds are slow).
private func signal(_ tone: Double, start: Double, rate: Double, count: Int) -> [Float] {
    guard count > 0 else { return [] }
    var phase = [Double](repeating: 0, count: count)
    var first = 2 * .pi * tone * (start - T0), step = 2 * .pi * tone / rate
    vDSP_vrampD(&first, &step, &phase, 1, vDSP_Length(count))
    var sines = [Double](repeating: 0, count: count)
    var n = Int32(count)
    vvsin(&sines, phase, &n)
    var out = [Float](repeating: 0, count: count)
    vDSP_vdpsp(sines, 1, &out, 1, vDSP_Length(count))
    var gain: Float = 0.2
    vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(count))
    for m in marks {  // the clicks: [m, m + 5 ms)
        let lo = max(0, Int(((T0 + m - start) * rate).rounded(.up)))
        let hi = min(count, Int(((T0 + m + 0.005 - start) * rate).rounded(.up)))
        if lo < hi { for i in lo..<hi { out[i] = 0.9 } }
    }
    return out
}

/// SplitMix64: a seeded stream for the rough link.
private struct Random {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// A Bluetooth-like link: stamps jitter by ±5 ms, 0.5 % of IO cycles are lost, and now and then
/// nothing arrives for 30-80 ms (that audio is lost). Healthy, if not pretty.
private final class Rough {
    static let stalls: [(Double, Double)] = [(4.1, 0.03), (9.3, 0.08), (15.7, 0.05), (24.2, 0.06), (30.8, 0.04), (35.4, 0.07)]
    var random: Random
    init(seed: UInt64) { random = Random(state: seed) }
    func deliver(_ t: Double) -> Double? {
        let rel = t - T0
        if Rough.stalls.contains(where: { rel >= $0.0 && rel < $0.0 + $0.1 }) || random.next() < 0.005 { return nil }
        return t + (random.next() * 2 - 1) * 0.005
    }
}

// MARK: - fake Core Audio

/// An output device, the clock of the tap's aggregate.
private final class Output {
    let uid: String, name: String
    var rate: Double  // what the hardware runs at now
    let channels: Int
    let claims: Double?  // kAudioTapPropertyFormat's rate; nil: the same as `rate`
    var alive = true  // false: no IO cycles (a Bluetooth profile switch)
    let frames: Int?  // frames per IO cycle; nil: 10 ms worth
    let ppm: Double  // the device's clock against host time (+: fast)
    init(_ uid: String, _ name: String, _ rate: Double, channels: Int = 2, claims: Double? = nil, frames: Int? = nil,
         ppm: Double = 0) {
        self.uid = uid
        self.name = name
        self.rate = rate
        self.channels = channels
        self.claims = claims
        self.frames = frames
        self.ppm = ppm
    }
}

private final class FakeCoreAudio: TapBackend {
    final class Aggregate {
        let output: Output
        var handler: TapIOHandler?
        var running = false
        var next: Double?
        init(_ output: Output) { self.output = output }
    }
    var output: Output
    let reportsRate: Bool
    let rough: Rough?
    let tickHz: Double
    var aggregates: [AudioObjectID: Aggregate] = [:]
    var failAggregate: ProcessTapError?
    var cycle: ((Aggregate, Double, Int, Double) -> Void)!
    private var nextID: AudioObjectID = 40

    init(_ output: Output, reportsRate: Bool, rough: Rough?, tickHz: Double) {
        self.output = output
        self.reportsRate = reportsRate
        self.rough = rough
        self.tickHz = tickHz
        cycle = { [unowned self] in self.realCycle($0, $1, $2, $3) }
    }

    func translatePID(_ pid: pid_t) throws -> AudioObjectID? { 1 }
    func createProcessTap(excluding processes: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) { (7, "tap-uid") }
    func readTapFormat(_ tap: AudioObjectID) throws -> TapFormat {
        TapFormat(sampleRate: output.claims ?? output.rate, channels: output.channels)
    }
    func deviceSampleRate(_ device: AudioObjectID) throws -> Double? { reportsRate ? aggregates[device]?.output.rate : nil }
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        if let failAggregate { throw failAggregate }
        nextID += 1
        aggregates[nextID] = Aggregate(output)
        return nextID
    }
    func createIOProc(_ device: AudioObjectID, handler: @escaping TapIOHandler) throws -> IOProcToken {
        aggregates[device]?.handler = handler
        return IOProcToken(raw: UInt(device))
    }
    func startDevice(_ device: AudioObjectID, _ proc: IOProcToken) throws { aggregates[device]?.running = true }
    func stopDevice(_ device: AudioObjectID, _ proc: IOProcToken) { aggregates[device]?.running = false }
    func destroyIOProc(_ device: AudioObjectID, _ proc: IOProcToken) {}
    func destroyAggregateDevice(_ device: AudioObjectID) { aggregates[device] = nil }
    func destroyProcessTap(_ tap: AudioObjectID) {}
    func defaultOutputUID() throws -> String { output.uid }
    func defaultOutputName() throws -> String? { output.name }
    func hostTimeToNanos(_ hostTime: UInt64) -> Int64 { Int64((Double(hostTime) / tickHz * 1e9).rounded()) }

    private func deliver(_ agg: Aggregate, at: Double, stamp: Double, count: Int, rate: Double) {
        let mono = signal(systemTone, start: at, rate: rate, count: count)
        let channels = agg.output.channels
        var frames = [Float](repeating: 0, count: count * channels)  // interleaved
        for i in 0..<count { for c in 0..<channels { frames[i * channels + c] = mono[i] } }
        if let handler = agg.handler {
            callIO(handler, frames, channels: UInt32(agg.output.channels), host: UInt64((stamp * tickHz).rounded()))
        }
    }

    func realCycle(_ agg: Aggregate, _ at: Double, _ n: Int, _ rate: Double) {
        deliver(agg, at: at, stamp: at, count: n, rate: rate)
    }

    /// One IO cycle of every running aggregate whose clock device is still the default output.
    func render(_ t: Double, _ dt: Double) {
        for agg in Array(aggregates.values) {
            let out = agg.output
            guard agg.running, out === output, out.alive else { agg.next = nil; continue }
            if let frames = out.frames {  // whole cycles of the device's own clock
                let rate = out.rate * (1 + out.ppm * 1e-6)
                var next = agg.next ?? t
                while next < t + dt - 1e-12 {
                    cycle(agg, next, frames, rate)
                    next += Double(frames) / rate
                }
                agg.next = next
                continue
            }
            var stamp = t
            if let rough {
                guard let s = rough.deliver(t) else { continue }
                stamp = s
            }
            deliver(agg, at: t, stamp: stamp, count: Int((out.rate * dt).rounded()), rate: out.rate)
        }
    }
}

// MARK: - fake AVFoundation

private final class Input {
    let uid: String, name: String
    var rate: Double
    let layout: String  // "float32" mono, "int16x2" interleaved, "float32x2planar"
    let muted: Bool
    let level: Float  // a quiet speaker: the signal scaled down
    init(_ uid: String, _ name: String, _ rate: Double, layout: String = "float32", muted: Bool = false, level: Float = 1) {
        self.level = level
        self.uid = uid
        self.name = name
        self.rate = rate
        self.layout = layout
        self.muted = muted
    }
}

private final class FakeAVFoundation: MicBackend {
    static let authorized = 3, denied = 2
    final class Session: MicSession {
        let device: Input, sink: CaptureRing
        var running = false
        init(_ device: Input, _ sink: CaptureRing) {
            self.device = device
            self.sink = sink
        }
        func start() throws { running = true }
        func stop() { running = false }
    }
    var devices: [String: Input] = [:]
    var defaultUID: String?
    var status = FakeAVFoundation.authorized
    var delivering = true
    let rough: Rough?
    var sessions: [Session] = []
    var render: ((Double, Double) -> Void)!

    init(_ inputs: [Input], rough: Rough?) {
        for d in inputs { devices[d.uid] = d }
        defaultUID = inputs.first?.uid
        self.rough = rough
        render = { [unowned self] in self.realRender($0, $1) }
    }

    func defaultInputUID() throws -> String {
        try AVMicError.checkAuthorization(status)  // the real status → error mapping
        guard let defaultUID else { throw AVMicError("no microphone available") }
        return defaultUID
    }
    func openSession(uid: String, sink: CaptureRing) throws -> MicSession {
        let session = Session(devices[uid]!, sink)
        sessions.append(session)
        return session
    }
    func deviceName(uid: String) -> String? { devices[uid]?.name }

    func realRender(_ t: Double, _ dt: Double) {
        guard delivering else { return }
        for s in sessions where s.running {
            var stamp = t
            if let rough {
                guard let st = rough.deliver(t) else { continue }
                stamp = st
            }
            let d = s.device
            let n = Int((d.rate * dt).rounded())
            var x = signal(micTone, start: t, rate: d.rate, count: n)
            if d.muted || status != Self.authorized { x = [Float](repeating: 0, count: n) } else if d.level != 1 { x = x.map { $0 * d.level } }
            let pts = Int64((stamp * 1e9).rounded())
            switch d.layout {
            case "int16x2":  // signed integer, packed, interleaved
                let pcm = x.flatMap { v -> [Int16] in let i = Int16(max(-32_768, min(32_767, v * 32_767))); return [i, i] }
                _ = pcm.withUnsafeBytes {
                    s.sink.push(pts: pts, format: PCMFormat(sampleRate: d.rate, formatFlags: 0x4 | 0x8, channels: 2,
                                                            bitsPerChannel: 16), bytes: $0)
                }
            case "float32x2planar":  // float, packed, non-interleaved
                _ = (x + x).withUnsafeBytes {
                    s.sink.push(pts: pts, format: PCMFormat(sampleRate: d.rate, formatFlags: 0x1 | 0x8 | 0x20, channels: 2,
                                                            bitsPerChannel: 32), bytes: $0)
                }
            default:
                _ = x.withUnsafeBytes {
                    s.sink.push(pts: pts, format: PCMFormat(sampleRate: d.rate, formatFlags: 0x1 | 0x8, channels: 1,
                                                            bitsPerChannel: 32), bytes: $0)
                }
            }
        }
    }
}

// MARK: - the recorder, stepped by the test

private typealias Event = (FakeCoreAudio, FakeAVFoundation) -> Void

private struct Run {
    let rec: CaptureRecorder
    let mic: [Int16]
    let system: [Int16]
    let devices: (mic: String?, output: String?)  // as the status showed them before the stop
    let statuses: [CaptureStatus]
    let problems: [AudioIncident]
    let hints: [[String]]  // as the status showed them each second ("silent/mic")
    let events: [String]  // session.log events written ("audio_problem/stalled/mic")
    let problemsFile: URL
    let tap: ProcessTap
    let av: AVMic
}

/// The real health monitor, which also keeps the statuses it was shown.
private final class StatusLog: CaptureMonitor, @unchecked Sendable {
    var statuses: [CaptureStatus] = []
    let events = Locked<[String]>([])
    let inner: AudioHealthMonitor
    let file: URL
    init(dir: URL) {
        file = dir.appendingPathComponent("audio_problems.json")
        let events = events
        inner = AudioHealthMonitor(problemsURL: file, events: { _, name, fields in
            let kind = fields.first { $0.0 == "kind" }?.1 as? String ?? ""
            let track = fields.first { $0.0 == "track" }?.1 as? String ?? ""
            events.with { $0.append("\(name)/\(kind)/\(track)") }
        })
    }
    func begin(now: Double) throws { try inner.begin(now: now) }
    func chunk(_ track: CaptureTrack, now: Double, pts: Int64, samples: [Float], rate: Double) throws {
        try inner.chunk(track, now: now, pts: pts, samples: samples, rate: rate)
    }
    func reanchor(_ track: CaptureTrack, now: Double, drift: Double) throws -> Bool {
        try inner.reanchor(track, now: now, drift: drift)
    }
    func check(_ status: CaptureStatus) throws { statuses.append(status); try inner.check(status) }
    func close(now: Double) throws { try inner.close(now: now) }
}

private func run(_ output: Output, _ mics: [Input], seconds: Double = 40, events: [(Double, Event)] = [],
                 reportsRate: Bool = true, setup: Event? = nil, rough: Bool = false, tickHz: Double = 1e9) throws -> Run {
    let ca = FakeCoreAudio(output, reportsRate: reportsRate, rough: rough ? Rough(seed: 1) : nil, tickHz: tickHz)
    let av = FakeAVFoundation(mics, rough: rough ? Rough(seed: 2) : nil)
    setup?(ca, av)
    var now = T0
    var tap: ProcessTap!
    var mic: AVMic!
    let dir = tempDir()
    let monitor = StatusLog(dir: dir)
    var hints: [[String]] = []
    let sources = CaptureSources(
        systemTap: { ring in
            tap = ProcessTap(sink: ring, excludedPIDs: { [1] }, backend: ca, routePollInterval: nil, clock: { now })
            return tap
        },
        mic: { ring in
            mic = AVMic(sink: ring, backend: av, routePollInterval: nil)
            return mic
        },
        screenCapture: { _, _ in FakeScreenCapture(mic: CaptureRing(capacity: 64), system: CaptureRing(capacity: 64), failures: 99) })
    let rec = CaptureRecorder(micURL: dir.appendingPathComponent("mic_raw.wav"),
                              systemURL: dir.appendingPathComponent("system.wav"), sources: sources, monitor: monitor,
                              clock: { now + LATENCY }, log: { _ in }, debug: { _ in }, sleep: { _ in },
                              ringCapacity: 1 << 20, runsWriterThread: false)
    try rec.start()
    var pending = events.sorted { $0.0 < $1.0 }
    let steps = Int((seconds / STEP).rounded())
    for k in 0..<steps {
        let t = T0 + Double(k) * STEP
        now = t
        while let first = pending.first, Double(k) * STEP >= first.0 - 1e-9 {
            pending.removeFirst()
            first.1(ca, av)
        }
        if k > 0, k % 100 == 0 {  // the route watchers poll once a second
            tap.checkRoute()
            mic.checkRoute()
            hints.append(monitor.inner.hints.map { "\($0.kind)/\($0.track)" })
        }
        ca.render(t, STEP)
        av.render(t, STEP)
        while rec.drainOnce() {}
        rec.checkHealth()
    }
    now = T0 + seconds
    let devices = (rec.micDevice, rec.systemDevice)
    try rec.stop()
    return Run(rec: rec, mic: try readWav(dir.appendingPathComponent("mic_raw.wav")).samples,
               system: try readWav(dir.appendingPathComponent("system.wav")).samples,
               devices: devices, statuses: monitor.statuses, problems: monitor.inner.problems, hints: hints,
               events: monitor.events.get, problemsFile: monitor.file, tap: tap, av: mic)
}

/// The strongest frequency of a Hann-windowed window (Python's `_pitch`: rfft argmax), via vDSP.
private func pitch(_ x: ArraySlice<Int16>) -> Double {
    let log2n = 14, n = 1 << 14  // 16 384 ≥ one second at 16 kHz, zero-padded: 0.98 Hz bins
    let m = min(x.count, n)
    var window = [Float](repeating: 0, count: m)
    vDSP_hann_window(&window, vDSP_Length(m), Int32(vDSP_HANN_DENORM))
    var input = [Float](repeating: 0, count: n)
    for i in 0..<m { input[i] = Float(x[x.startIndex + i]) * window[i] }
    var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    var power = [Float](repeating: 0, count: n / 2)
    let fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)!
    re.withUnsafeMutableBufferPointer { rb in
        im.withUnsafeMutableBufferPointer { ib in
            var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            input.withUnsafeBufferPointer { ip in
                ip.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
            fft.forward(input: split, output: &split)
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
        }
    }
    power[0] = 0  // DC and Nyquist, packed
    let peak = power.indices.max { power[$0] < power[$1] }!
    return Double(peak) * Double(captureSampleRate) / Double(n)
}

private func clicks(_ x: [Int16]) -> [Double] {
    var found: [Double] = []
    var last = -Int.max / 2
    for (i, v) in x.enumerated() where Double(v) > 0.6 * 32_767 {
        if i - last > captureSampleRate / 10 { found.append(Double(i) / Double(captureSampleRate)) }
        last = i
    }
    return found
}

// MARK: - the matrix

private let speakers = { Output("BuiltInSpeakerDevice", "MacBook Pro Speakers", 48_000) }
private let builtinMic = { Input("BuiltInMicrophoneDevice", "MacBook Pro Microphone", 48_000) }
private func airpods() -> Output { Output("AirPods-Out", "AirPods Pro", 48_000, claims: 48_000) }

/// The call opens the AirPods' mic (A2DP → HFP): the output drops to 24 kHz (the tap's format still
/// says 48) after a short silence, and the AirPods become the default input.
private let airpodsJoinCall: Event = { ca, av in
    ca.output.rate = 24_000
    ca.output.alive = false
    av.defaultUID = "AirPodsMic"
}
private let airpodsAudioBack: Event = { ca, _ in ca.output.alive = true }
private let switchToHeadphones: Event = { ca, _ in
    ca.output = Output("BuiltInHeadphoneOutputDevice", "External Headphones", 44_100)
}
/// Audio MIDI Setup: the same devices switch from 48 to 44.1 kHz.
private let rateChange: Event = { ca, av in
    ca.output.rate = 44_100
    for d in av.devices.values { d.rate = 44_100 }
}

private struct Row {
    var output: Output
    var mics: [Input]
    var rates: (mic: Double, system: Double)  // at the end, before resampling
    var names: (mic: String, output: String)  // at the end
    var events: [(Double, Event)] = []
    var unsettled: [(Double, Double)] = []  // following a change: not checked for pitch
    var rough = false
    var tickHz = 1e9
}

private let matrix: [String: () -> Row] = [
    "built-in speakers": {
        Row(output: speakers(), mics: [builtinMic()], rates: (48_000, 48_000),
            names: ("MacBook Pro Microphone", "MacBook Pro Speakers"))
    },
    "wired headphones": {
        Row(output: Output("BuiltInHeadphoneOutputDevice", "External Headphones", 44_100), mics: [builtinMic()],
            rates: (48_000, 44_100), names: ("MacBook Pro Microphone", "External Headphones"))
    },
    "AirPods, A2DP to HFP mid-call": {
        Row(output: airpods(), mics: [builtinMic(), Input("AirPodsMic", "AirPods Pro", 24_000)], rates: (24_000, 24_000),
            names: ("AirPods Pro", "AirPods Pro"), events: [(20.0, airpodsJoinCall), (20.3, airpodsAudioBack)],
            unsettled: [(20, 21)])
    },
    "external interface at 44.1 kHz": {
        Row(output: Output("Scarlett", "Scarlett 2i2", 44_100, claims: 48_000),
            mics: [Input("ScarlettIn", "Scarlett 2i2", 44_100, layout: "int16x2")], rates: (44_100, 44_100),
            names: ("Scarlett 2i2", "Scarlett 2i2"))
    },
    "external interface at 96 kHz": {
        Row(output: Output("UltraLite", "UltraLite-mk5", 96_000, channels: 4, claims: 48_000),
            mics: [Input("UltraLiteIn", "UltraLite-mk5", 96_000, layout: "float32x2planar")], rates: (96_000, 96_000),
            names: ("UltraLite-mk5", "UltraLite-mk5"))
    },
    "output switched mid-call": {
        Row(output: speakers(), mics: [builtinMic()], rates: (48_000, 44_100),
            names: ("MacBook Pro Microphone", "External Headphones"), events: [(20.0, switchToHeadphones)],
            unsettled: [(20, 21)])
    },
    "sample rate changed mid-call": {
        Row(output: speakers(), mics: [builtinMic()], rates: (44_100, 44_100),
            names: ("MacBook Pro Microphone", "MacBook Pro Speakers"), events: [(20.0, rateChange)], unsettled: [(20, 21)])
    },
    "1024-frame cycles, 24 MHz host ticks, device clock 20 ppm slow": {
        Row(output: Output("BuiltInSpeakerDevice", "MacBook Pro Speakers", 48_000, frames: 1024, ppm: -20),
            mics: [builtinMic()], rates: (48_000, 48_000), names: ("MacBook Pro Microphone", "MacBook Pro Speakers"),
            tickHz: 24e6)
    },
    "2048-frame cycles, 24 MHz host ticks, device clock 20 ppm fast": {
        Row(output: Output("BuiltInSpeakerDevice", "MacBook Pro Speakers", 48_000, frames: 2048, ppm: 20),
            mics: [builtinMic()], rates: (48_000, 48_000), names: ("MacBook Pro Microphone", "MacBook Pro Speakers"),
            tickHz: 24e6)
    },
    "Bluetooth-like link: jitter, lost cycles, short stalls": {
        Row(output: Output("Headset", "Northwind Headset", 48_000), mics: [Input("HeadsetMic", "Northwind Headset", 16_000)],
            rates: (16_000, 48_000), names: ("Northwind Headset", "Northwind Headset"), rough: true)
    },
]

@Suite struct DeviceMatrixTests {
    @Test(arguments: matrix.keys.sorted())
    func deviceMatrix(_ name: String) throws {
        let row = matrix[name]!()
        let r = try run(row.output, row.mics, events: row.events, rough: row.rough, tickHz: row.tickHz)
        let seconds = 40.0

        // Duration against the clock.
        for track in [r.mic, r.system] {
            #expect(abs(Double(track.count) / 16_000 - seconds) <= 0.05, "\(name): \(Double(track.count) / 16_000) s")
        }
        // Speed: the tone keeps its pitch everywhere but right after a change (the watchers poll once
        // a second) or a stall.
        let stalls = row.rough ? Rough.stalls.map { ($0.0, $0.0 + $0.1) } : []
        for (track, tone, label) in [(r.mic, micTone, "mic"), (r.system, systemTone, "system")] {
            for second in 1..<Int(seconds) - 1 {
                if (row.unsettled + stalls).contains(where: { Double(second) >= $0.0 - 1 && Double(second) < $0.1 + 1 }) {
                    continue
                }
                let window = track[second * 16_000..<min(track.count, (second + 1) * 16_000)]
                let got = pitch(window)
                #expect(abs(got - tone) <= tone * 0.01, "\(name): \(label) \(tone) Hz at \(second) s: \(got) Hz")
            }
        }
        // Drift: each click lands within 20 ms of when it happened, on both tracks.
        for (track, label) in [(r.mic, "mic"), (r.system, "system")] {
            let found = clicks(track)
            #expect(found.count == marks.count, "\(name): \(label) clicks \(found)")
            for (got, want) in zip(found, marks) {
                #expect(abs(got - want) <= driftLimit, "\(name): \(label) click at \(got) s, played at \(want) s")
            }
        }
        // The status knows the rates and the devices; no source reported a problem.
        #expect(r.rec.micRate == row.rates.mic && r.rec.systemRate == row.rates.system, "\(name)")
        #expect(r.devices.mic == row.names.mic && r.devices.output == row.names.output, "\(name): \(r.devices)")
        #expect(r.statuses.allSatisfy { $0.access.isEmpty && $0.writeFailures.isEmpty && !$0.micStalled && !$0.systemStalled },
                "\(name)")
        // Health: no warning on a healthy setup.
        #expect(r.problems.isEmpty, "\(name): \(r.problems)")
        #expect(r.hints.allSatisfy { $0.isEmpty }, "\(name)")
        #expect(r.events.isEmpty, "\(name): \(r.events)")
        #expect(!FileManager.default.fileExists(atPath: r.problemsFile.path), "\(name)")
    }

    @Test func lostIOCyclesAreGapsNotAWrongSpeed() throws {
        // 5 % of 512-frame cycles lost, with exact stamps: each loss is a jump of exactly one cycle.
        var random = Random(state: 5)
        let r = try run(Output("BuiltInSpeakerDevice", "MacBook Pro Speakers", 48_000, frames: 512), [builtinMic()],
                        setup: { ca, _ in
                            let cycle = ca.cycle!
                            ca.cycle = { agg, at, n, rate in if random.next() >= 0.05 { cycle(agg, at, n, rate) } }
                        }, tickHz: 24e6)
        #expect(abs(Double(r.system.count) / 16_000 - 40) <= 0.05)
        let found = clicks(r.system)
        #expect(found.count == marks.count)
        for (got, want) in zip(found, marks) { #expect(abs(got - want) <= driftLimit) }
        #expect(r.problems.isEmpty, "\(r.problems)")
    }

    @Test func lostMicrophonePermissionIsAnAccessProblem() throws {
        // The authorization status turns to denied (System Settings): the real status-to-error mapping
        // makes it "access", seen at the next route poll; the track goes on (silent).
        let r = try run(speakers(), [builtinMic()], seconds: 30, events: [(15.0, { _, av in av.status = FakeAVFoundation.denied })])
        let first = try #require(r.statuses.first { $0.access[.mic] != nil })
        #expect(first.access == [.mic: "access"])
        #expect(first.now >= T0 + 15 && first.now <= T0 + 16.1)
        #expect(r.av.problem == "access")
        #expect(abs(Double(r.mic.count) / 16_000 - 30) <= 0.05)
        // Opened only once it lasted 4 s, dated from when it was seen.
        #expect(r.problems.map { "\($0.kind)/\($0.track)" } == ["access/mic"])
        #expect(abs(r.problems[0].start - 15.0) <= 0.3)
        #expect(r.events == ["audio_problem/access/mic"])  // the stop ends it without an "over" line, as in Python
    }

    @Test func aTapThatCannotBeRebuiltIsADeviceProblem() throws {
        // kAudioHardwareIllegalOperationError on the rebuild: not proof of a lost permission, so "device".
        let refused: Event = { ca, av in
            switchToHeadphones(ca, av)
            ca.failAggregate = ProcessTapError("aggregate device creation failed", osStatus: 1_852_797_029)
        }
        let r = try run(speakers(), [builtinMic()], seconds: 30, events: [(15.0, refused)])
        let first = try #require(r.statuses.first { $0.access[.system] != nil })
        #expect(first.access == [.system: "device"])
        #expect(first.now >= T0 + 15 && first.now <= T0 + 16.1)
        #expect(abs(Double(r.mic.count) / 16_000 - 30) <= 0.05)  // the microphone records on
        #expect(abs(Double(r.system.count) / 16_000 - 15) <= 0.05)  // the system track ends where the tap was lost
        #expect(r.problems.map { "\($0.kind)/\($0.track)" } == ["device/system"])
        #expect(abs(r.problems[0].start - 15.0) <= 0.3)
    }

    @Test func noMicrophoneForASecondWhileAirPodsSwitchEndsWell() throws {
        let gone: Event = { ca, av in
            airpodsJoinCall(ca, av)
            av.defaultUID = nil  // between the two microphones
        }
        let r = try run(airpods(), [builtinMic(), Input("AirPodsMic", "AirPods Pro", 24_000)],
                        events: [(20.0, gone), (20.3, airpodsAudioBack), (21.5, { _, av in av.defaultUID = "AirPodsMic" })])
        #expect(r.statuses.contains { $0.access == [.mic: "device"] })  // said while it lasted (health opens after 4 s)
        #expect(r.statuses.last?.access.isEmpty == true && r.av.problem == nil)
        #expect(r.devices.mic == "AirPods Pro")
        #expect(r.problems.isEmpty, "\(r.problems)")
        for track in [r.mic, r.system] {
            #expect(abs(Double(track.count) / 16_000 - 40) <= 0.05)
            let found = clicks(track)
            #expect(found.count == marks.count)
            for (got, want) in zip(found, marks) { #expect(abs(got - want) <= driftLimit) }
        }
    }

    // MARK: detect, don't trust: the same rows going wrong

    private func kinds(_ r: Run) -> [String] { r.problems.map { "\($0.kind)/\($0.track)" } }

    @Test func airpodsWithATapThatTrustsItsFormatWarnOfTheWrongSpeed() throws {
        // The 2026-10-29 bug: the tap's format said 48 kHz while AirPods ran at 24 kHz.
        let r = try run(airpods(), [builtinMic(), Input("AirPodsMic", "AirPods Pro", 24_000)],
                        events: [(20.0, airpodsJoinCall), (20.3, airpodsAudioBack)], reportsRate: false)
        let speed = r.problems.filter { $0.kind == "speed" }
        #expect(speed.map(\.track) == ["system"])
        #expect(speed[0].start >= 20.0 && speed[0].start <= 28.0, "\(speed[0].start)")
        #expect(abs(speed[0].end! - 40.0) <= 0.5)  // still wrong when it stopped
        #expect(!r.problems.contains { $0.track == "mic" })
        #expect(r.events.contains("audio_problem/speed/system"))
    }

    @Test(arguments: [(1024, -20.0), (1024, 20.0), (2048, 0.0), (2048, -20.0), (2048, 20.0)])
    func theAirpodsMisreadWarnsWithLongIOCyclesAndHostTicks(_ frames: Int, _ ppm: Double) throws {
        // A 2x misread with 20-ms-plus cycles sat on the old continuity bound: it never warned.
        let out = Output("AirPods-Out", "AirPods Pro", 48_000, claims: 48_000, frames: frames, ppm: ppm)
        let r = try run(out, [builtinMic(), Input("AirPodsMic", "AirPods Pro", 24_000)],
                        events: [(20.0, airpodsJoinCall), (20.3, airpodsAudioBack)], reportsRate: false, tickHz: 24e6)
        #expect(kinds(r) == ["speed/system"], "\(frames) \(ppm): \(r.problems)")
        #expect(r.problems[0].start >= 20.0 && r.problems[0].start <= 28.0)
    }

    @Test func aMutedMicrophoneWhileTheOthersTalkIsOnlyAHint() throws {
        // A soft line in the status, no warning; kept on the meeting page only because it stayed muted to the end.
        let r = try run(speakers(), [Input("BuiltInMicrophoneDevice", "MacBook Pro Microphone", 48_000, muted: true)], seconds: 75)
        let shown = r.hints.enumerated().filter { !$0.element.isEmpty }.map { $0.offset + 1 }
        #expect(!shown.isEmpty && shown[0] >= 60 && shown[0] <= 62, "\(shown)")
        #expect(r.hints.last == ["silent/mic"])
        #expect(r.problems.map { "\($0.kind)/\($0.track)/\($0.end!)" } == ["silent/mic/75.0"])
        #expect(r.events.isEmpty)  // never a warning line
        // And it is in the file beside the audio, for the meeting page.
        let kept = try String(contentsOf: r.problemsFile, encoding: .utf8)
        #expect(kept.contains("\"kind\": \"silent\"") && kept.contains("\"end\": 75.0"))
    }

    @Test func aQuietParticipantIsNotAWarning() throws {
        // Someone who only listens still has a noise floor: not silence.
        let r = try run(speakers(), [Input("BuiltInMicrophoneDevice", "MacBook Pro Microphone", 48_000, level: 0.001)], seconds: 75)
        #expect(r.problems.isEmpty && r.hints.allSatisfy { $0.isEmpty }, "\(r.problems)")
    }

    @Test func aMicrophoneThatStopsDeliveringIsAWarning() throws {
        let r = try run(speakers(), [builtinMic()], seconds: 50, events: [(10.0, { _, av in av.delivering = false })])
        let stalled = r.problems.filter { $0.kind == "stalled" }
        #expect(stalled.map(\.track) == ["mic"])
        #expect(stalled[0].start >= 39.0 && stalled[0].start <= 41.0, "\(stalled[0].start)")
    }

    @Test func aTrackOutOfStepWithTheClockIsALengthWarningNotASpeedOne() throws {
        // Stamps that keep pace with the samples but not with the clock: the source delivers 54 s of
        // audio a minute. Its speed is right; its length is not.
        let r = try run(speakers(), [builtinMic()], seconds: 60, setup: { _, av in
            let render = av.render!
            av.render = { t, dt in render(T0 + (t - T0) * 0.9, dt * 0.9) }
        })
        #expect(kinds(r) == ["length/mic"], "\(r.problems)")
    }
}
