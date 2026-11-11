import Foundation
@testable import PalaverCapture

// Synthetic audio only: no device, no sound.

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("palaver-capture-\(getpid())-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func sine(_ n: Int, freq: Double = 440, sr: Double = 16_000, amp: Double = 0.3) -> [Float] {
    (0..<n).map { Float(amp * sin(2 * .pi * freq * Double($0) / sr)) }
}

/// Seconds → host-time nanoseconds.
func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

/// `signal` split into `size`-sample chunks with contiguous PTS (the Python tests' `_chunked`).
func chunked(_ signal: [Float], _ pts0: Double, _ size: Int, rate: Double = 16_000) -> [TimedChunk] {
    stride(from: 0, to: signal.count, by: size).map { i in
        TimedChunk(pts: ns(pts0) + Int64((Double(i) / rate * 1e9).rounded()),
                   samples: Array(signal[i..<min(signal.count, i + size)]), rate: rate)
    }
}

struct Wav {
    let header: [UInt8]
    let samples: [Int16]
    var dataSize: UInt32 { u32(40) }
    var riffSize: UInt32 { u32(4) }
    var sampleRate: UInt32 { u32(24) }
    private func u32(_ at: Int) -> UInt32 { header[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
}

/// A 44-byte-header PCM16 WAV, as the writer makes it (the samples after the header, whatever the header says).
func readWav(_ url: URL) throws -> Wav {
    let data = try Data(contentsOf: url)
    let header = [UInt8](data.prefix(44))
    let body = data.dropFirst(44)
    let samples = body.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) }
    return Wav(header: header, samples: samples)
}

/// Frames of a long WAV, in blocks, without holding the file in memory.
func scanWav(_ url: URL, block: Int = 1 << 20, _ body: (_ start: Int, _ samples: [Int16]) -> Void) throws {
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    try fh.seek(toOffset: 44)
    var start = 0
    while let data = try fh.read(upToCount: block * 2), !data.isEmpty {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        body(start, samples)
        start += samples.count
    }
}

func dominantFreq(_ x: ArraySlice<Int16>, sr: Double = 16_000) -> Double {
    // Goertzel scan, 1 Hz steps from 50 to 2000 Hz: enough for the test tones.
    let v = x.map(Double.init)
    var best = (f: 0.0, p: -1.0)
    for f in stride(from: 50.0, through: 2000.0, by: 1.0) {
        let w = 2 * cos(2 * .pi * f / sr)
        var s1 = 0.0, s2 = 0.0
        for s in v { let s0 = s + w * s1 - s2; s2 = s1; s1 = s0 }
        let p = s1 * s1 + s2 * s2 - w * s1 * s2
        if p > best.p { best = (f, p) }
    }
    return best.f
}

func longestZeroRun(_ x: ArraySlice<Int16>) -> Int {
    var best = 0, run = 0
    for v in x { run = v == 0 ? run + 1 : 0; best = max(best, run) }
    return best
}

func meanAbs(_ x: ArraySlice<Int16>) -> Int {
    x.isEmpty ? 0 : Int(x.reduce(0.0) { $0 + abs(Double($1)) } / Double(x.count))
}

func maxAbs(_ x: ArraySlice<Int16>) -> Int { x.map { abs(Int($0)) }.max() ?? 0 }

/// Runs chunks through an aligner in the given order and finalizes: the Python tests' `_drive_writer_loop`
/// (which drains the mic queue and the system queue in turns).
@discardableResult
func drive(_ dir: URL, mic: [TimedChunk], system: [TimedChunk],
           onReanchor: ((CaptureTrack, Double) -> Bool)? = nil) throws -> (mic: Wav, system: Wav, aligner: TrackAligner) {
    let aligner = try TrackAligner(mic: TrackWriter(finalURL: dir.appendingPathComponent("mic_raw.wav")),
                                   system: TrackWriter(finalURL: dir.appendingPathComponent("system.wav")),
                                   onReanchor: onReanchor)
    for i in 0..<max(mic.count, system.count) {
        if i < mic.count { try aligner.handle(mic[i], track: .mic) }
        if i < system.count { try aligner.handle(system[i], track: .system) }
    }
    try aligner.finish()
    return (try readWav(dir.appendingPathComponent("mic_raw.wav")),
            try readWav(dir.appendingPathComponent("system.wav")), aligner)
}
