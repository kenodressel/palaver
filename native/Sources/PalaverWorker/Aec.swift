// Echo cancellation (palaver/aec.py): the WebRTC audio processor (libraven_aec, linked in as CRavenAEC) takes
// the system track as the far-end reference and removes it from the raw microphone, 10 ms frame by frame. The
// tracks are written on one timeline, so the stream delay hint is 0; the processor's own estimator finds the
// acoustic path. The mic goes in MIC_LEAD_MS late (its filter covers echo heard after the reference, not before)
// and the output drops that lead again, so it lines up with the raw mic.
import CRavenAEC
import Foundation
import PalaverDomain

public enum Aec {
    public static let SAMPLE_RATE = 16_000
    public static let FRAME_MS = 10
    public static let FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS / 1000  // 160
    /// Render→capture buffering delay hint: both tracks share the capture's timeline (aec.py's measurements).
    public static let STREAM_DELAY_MS = 0
    /// How late the canceller sees the mic (#25: echoes that reach the mic with or just before their reference).
    public static let MIC_LEAD_MS = 10
    static let LEAD_SAMPLES = SAMPLE_RATE * MIC_LEAD_MS / 1000
    /// `process` feeds the canceller this much at a time (10 s; the output is the same for any block size).
    static let BLOCK_SAMPLES = SAMPLE_RATE * 10

    /// `aec_process`: `out` is `micRaw` with the system track's echo removed, as long as `micRaw`. Where the system
    /// track ended first (its capture paused, #18) the rest of the mic is kept as it is; a partial last frame of
    /// the overlap is silence. `out` is written aside and renamed: `process` trusts a mic.wav that exists (#49).
    public static func process(micRaw: URL, system: URL, out: URL) throws {
        let mic = try readMono(micRaw)
        let far = try readMono(system)
        let overlap = min(mic.count, far.count)
        let stream = try AecStream()
        defer { stream.close() }
        // Fed in blocks of BLOCK_SAMPLES straight from the tracks: no copy of a whole track (a 2 h call is 115 MB
        // per track), only the output grows.
        var result: [Int16] = []
        result.reserveCapacity(mic.count)
        var start = 0
        while start < overlap {
            let end = min(start + BLOCK_SAMPLES, overlap)
            result += try stream.process(mic: mic[start..<end], system: far[start..<end])
            start = end
        }
        result += repeatElement(Int16(0), count: overlap - result.count)
        result += mic[overlap...]
        let tmp = out.deletingLastPathComponent().appendingPathComponent(out.lastPathComponent + ".tmp")
        defer { unlink(tmp.path) }
        try Wav16.write(result, rate: SAMPLE_RATE, to: tmp)
        guard rename(tmp.path, out.path) == 0 else {
            throw WorkerError("could not rename \(tmp.lastPathComponent) to \(out.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// The first channel of a 16 kHz PCM16 WAV.
    static func readMono(_ url: URL) throws -> [Int16] {
        let info = try Wav16.info(url)
        guard info.rate == SAMPLE_RATE else {
            throw WorkerError("\(url.lastPathComponent) has sample rate \(info.rate), expected \(SAMPLE_RATE)")
        }
        let samples = try Wav16.read(url)
        guard info.channels > 1 else { return samples }
        return stride(from: 0, to: samples.count, by: info.channels).map { samples[$0] }
    }
}

/// The canceller over two growing tracks on one timeline (the live worker feeds it as the recording grows):
/// `process` takes equally long blocks (any length; a partial frame is carried over) and returns the cancelled mic
/// of every whole frame so far. Blocks give the same output as one pass.
public final class AecStream {
    private var handle: OpaquePointer?
    private var micRest: [Int16]
    private var sysRest: [Int16] = []
    private var skip = Aec.LEAD_SAMPLES  // the output of the lead's silence

    public init() throws {
        guard let h = raven_aec_create(Int32(Aec.SAMPLE_RATE)) else { throw WorkerError("raven_aec_create returned NULL") }
        handle = h
        raven_aec_set_stream_delay(h, Int32(Aec.STREAM_DELAY_MS))
        micRest = [Int16](repeating: 0, count: Aec.LEAD_SAMPLES)
    }

    deinit { close() }

    /// Mic samples fed but not returned yet: the lead and a partial frame.
    public var pending: Int { micRest.count }

    public func process(mic: [Int16], system: [Int16]) throws -> [Int16] {
        try process(mic: mic[...], system: system[...])
    }

    /// `process` over parts of longer tracks, without copying them first.
    public func process(mic: ArraySlice<Int16>, system: ArraySlice<Int16>) throws -> [Int16] {
        guard mic.count == system.count else { throw WorkerError("mic and system blocks must have the same length") }
        guard let handle else { throw WorkerError("the echo canceller is closed") }
        let near = micRest + mic, far = sysRest + system
        let n = Aec.FRAME_SAMPLES
        let whole = far.count / n * n
        micRest = Array(near[whole...])
        sysRest = Array(far[whole...])
        var out = [Int16](repeating: 0, count: whole)
        try near.withUnsafeBufferPointer { nearBuf in
            try far.withUnsafeBufferPointer { farBuf in
                try out.withUnsafeMutableBufferPointer { outBuf in
                    for off in stride(from: 0, to: whole, by: n) {
                        let r = raven_aec_process_render(handle, farBuf.baseAddress! + off, Int32(n))
                        guard r == 0 else { throw WorkerError("raven_aec_process_render failed: \(r)") }
                        let c = raven_aec_process_capture(handle, nearBuf.baseAddress! + off, outBuf.baseAddress! + off, Int32(n))
                        guard c == 0 else { throw WorkerError("raven_aec_process_capture failed: \(c)") }
                    }
                }
            }
        }
        let dropped = min(skip, whole)
        skip -= dropped
        return Array(out[dropped...])
    }

    public func close() {
        if let handle { raven_aec_destroy(handle) }
        handle = nil
    }
}
