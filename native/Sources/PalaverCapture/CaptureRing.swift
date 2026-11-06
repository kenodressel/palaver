// The hand-over from the capture callbacks to the writer thread (capture_recorder.py's two
// `queue.Queue`s), made safe for Core Audio's realtime IO thread.
import Darwin
import Foundation
import Synchronization

/// A byte ring of captured buffers: raw bytes in their stream format, stamped
/// with the host time (ns) of their first frame. Producers are the capture
/// callbacks; the one consumer is the recorder's writer thread, which decodes,
/// resamples and writes.
///
/// Realtime behaviour of `push` (what the IO proc and the capture delegates
/// call): no allocation, no Objective-C, no I/O. It takes an `os_unfair_lock`
/// (Swift's `Mutex`; it donates priority to the owner), copies a 40-byte
/// header and the payload with `memcpy` into storage allocated once in
/// `init`, and returns. The consumer holds the lock only for its own copy out.
/// A full ring drops the buffer and counts it (the PTS gap is zero-padded
/// later, so the timeline stays right); the writer thread logs the count.
///
/// More than one producer is allowed (a late ScreenCaptureKit start may
/// overlap a new one for a moment); there is exactly one consumer.
public final class CaptureRing: @unchecked Sendable {
    /// 8 MiB: about 43 s of the tap's 48 kHz mono float32, 21 s of a 48 kHz
    /// stereo float32 microphone, 5 s of 96 kHz 4-channel float32. The writer
    /// drains every 20 ms.
    public static let defaultCapacity = 8 << 20

    struct Header {
        var payload: UInt32
        var formatID: UInt32
        var formatFlags: UInt32
        var channels: UInt32
        var bits: UInt32
        var reserved: UInt32 = 0
        var pts: Int64
        var sampleRate: Double
    }

    static let headerSize = MemoryLayout<Header>.size

    public let capacity: Int
    private let storage: UnsafeMutableRawPointer
    private struct Cursor {
        var head = 0  // where the oldest record starts
        var used = 0
    }
    private let cursor = Mutex(Cursor())
    private let droppedCount = Atomic<Int>(0)

    public init(capacity: Int = CaptureRing.defaultCapacity) {
        precondition(capacity > CaptureRing.headerSize)
        self.capacity = capacity
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    /// Copies one buffer in (realtime-safe, see above). False when it was dropped: empty, or no room.
    @discardableResult
    public func push(pts: Int64, format: PCMFormat, bytes: UnsafeRawBufferPointer) -> Bool {
        let need = Self.headerSize + bytes.count
        guard bytes.count > 0, bytes.count <= Int(UInt32.max), need <= capacity else {
            if bytes.count > 0 { droppedCount.add(1, ordering: .relaxed) }
            return false
        }
        var header = Header(payload: UInt32(bytes.count), formatID: format.formatID,
                            formatFlags: format.formatFlags, channels: UInt32(clamping: format.channels),
                            bits: UInt32(clamping: format.bitsPerChannel), pts: pts, sampleRate: format.sampleRate)
        let stored = cursor.withLock { c -> Bool in
            guard capacity - c.used >= need else { return false }
            let tail = (c.head + c.used) % capacity
            withUnsafeBytes(of: &header) { copyIn($0, at: tail) }
            copyIn(bytes, at: (tail + Self.headerSize) % capacity)
            c.used += need
            return true
        }
        if !stored { droppedCount.add(1, ordering: .relaxed) }
        return stored
    }

    /// The oldest buffer, its bytes copied into `buffer` (resized to fit; the
    /// writer thread reuses it). Consumer only.
    public func pop(into buffer: inout [UInt8]) -> (pts: Int64, format: PCMFormat)? {
        var header = Header(payload: 0, formatID: 0, formatFlags: 0, channels: 0, bits: 0, pts: 0, sampleRate: 0)
        let found = cursor.withLock { c -> Bool in
            guard c.used >= Self.headerSize else { return false }
            withUnsafeMutableBytes(of: &header) { copyOut($0, from: c.head) }
            return true
        }
        guard found else { return nil }
        let count = Int(header.payload)
        // Sized outside the lock: only this consumer moves `head`, so the record stays put.
        if buffer.count != count { buffer = [UInt8](repeating: 0, count: count) }
        cursor.withLock { c in
            buffer.withUnsafeMutableBytes { copyOut($0, from: (c.head + Self.headerSize) % capacity) }
            let size = Self.headerSize + count
            c.head = (c.head + size) % capacity
            c.used -= size
        }
        let format = PCMFormat(sampleRate: header.sampleRate, formatID: header.formatID,
                               formatFlags: header.formatFlags, channels: Int(header.channels),
                               bitsPerChannel: Int(header.bits))
        return (header.pts, format)
    }

    /// Buffers dropped since the last call (a full ring).
    public func takeDropped() -> Int { droppedCount.exchange(0, ordering: .relaxed) }

    public var isEmpty: Bool { cursor.withLock { $0.used == 0 } }

    private func copyIn(_ src: UnsafeRawBufferPointer, at position: Int) {
        guard let base = src.baseAddress, src.count > 0 else { return }
        let first = min(src.count, capacity - position)
        (storage + position).copyMemory(from: base, byteCount: first)
        if first < src.count { storage.copyMemory(from: base + first, byteCount: src.count - first) }
    }

    private func copyOut(_ dst: UnsafeMutableRawBufferPointer, from position: Int) {
        guard let base = dst.baseAddress, dst.count > 0 else { return }
        let first = min(dst.count, capacity - position)
        base.copyMemory(from: storage + position, byteCount: first)
        if first < dst.count { (base + first).copyMemory(from: storage, byteCount: dst.count - first) }
    }
}

/// Seconds on a monotonic clock (Python's `time.monotonic`).
public func monotonicSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// `threading.Event` for the pollers: `wait` returns true once `set`.
final class StopEvent: @unchecked Sendable {
    private let condition = NSCondition()
    private var flag = false

    var isSet: Bool { condition.withLock { flag } }

    func set() { condition.withLock { flag = true; condition.broadcast() } }

    func clear() { condition.withLock { flag = false } }

    /// Waits up to `seconds`; true when set (now or during the wait).
    func wait(_ seconds: Double) -> Bool {
        condition.withLock {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !flag { if !condition.wait(until: deadline) { break } }
            return flag
        }
    }
}

/// A background thread that calls `tick` every `interval` until stopped (the route watchers).
final class Poller: @unchecked Sendable {
    private let stop = StopEvent()
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(name: String, interval: Double, tick: @escaping () -> Void) {
        let stop = self.stop, done = self.done
        let thread = Thread {
            while !stop.wait(interval) { tick() }
            done.signal()
        }
        thread.name = name
        self.thread = thread
        thread.start()
    }

    /// Stops it and waits up to 5 s for the current tick (not when called from the poller itself).
    func cancel() {
        stop.set()
        guard let thread else { return }
        self.thread = nil
        if thread != Thread.current { _ = done.wait(timeout: .now() + 5) }
    }
}
