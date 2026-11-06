// The live per-track level of a recording (palaver/meter.py's `level_dbfs`, `level_bar`, `LevelTracker`;
// issue #17). It reads the still-growing `.part` files directly, never through a WAV reader (whose
// header says 0 frames until the file is finalized): only bytes appended since the previous tick are
// measured, at most the last 16 000 (0.5 s), because the process tap writes nothing while no audio
// plays and the file tail would show stale audio.
import Foundation

/// RMS level of int16 little-endian PCM in dBFS; nil for empty or digital silence.
public func levelDbfs(_ pcm16: Data) -> Double? {
    let count = pcm16.count / 2
    guard count > 0 else { return nil }
    var sum = 0.0
    pcm16.withUnsafeBytes { raw in
        for i in 0..<count {
            let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
            sum += s * s
        }
    }
    let rms = (sum / Double(count)).squareRoot()
    return rms == 0 ? nil : 20 * log10(rms / 32_768)
}

/// An 8-character block bar for a dBFS level (empty below -60 dB).
public func levelBar(_ db: Double?) -> String {
    let width = 8, floorDb = -60.0
    let blocks = Array(" ▁▂▃▄▅▆▇█")
    guard let db else { return String(repeating: " ", count: width) }
    let fill = min(max((db - floorDb) / -floorDb, 0), 1) * Double(width)
    let full = Int(fill)
    var bar = String(repeating: "█", count: full)
    if full < width { bar.append(blocks[Int((fill - Double(full)) * Double(blocks.count - 1))]) }
    return bar.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// How the tracker reads a file; tests pass a fake.
public struct LevelFiles: Sendable {
    public var size: @Sendable (URL) -> Int?
    public var read: @Sendable (URL, _ offset: Int, _ count: Int) -> Data?

    public static let real = LevelFiles(
        size: { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int },
        read: { url, offset, count in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? handle.read(upToCount: count)
        })
}

/// Per-track level of the audio appended since the previous `read()`, how long each track has had no
/// audio, and how long all of them (or one) have had nothing louder than `soundDbfs`.
public final class LevelTracker: @unchecked Sendable {
    /// Louder than this is sound (speech, the call); a quiet room's noise on the mic stays below it.
    public static let soundDbfs = -45.0
    static let headerSize = 44
    static let maxTickBytes = 16_000

    public struct Reading: Equatable, Sendable {
        public let label: String
        /// nil: nothing new, or digital silence.
        public let db: Double?
        /// Seconds without audio.
        public let silentFor: Double
    }

    private let tracks: [(label: String, url: URL)]
    private let clock: () -> Double
    private let soundDbfs: Double
    private let files: LevelFiles
    private var offsets: [String: Int]
    private var lastAudio: [String: Double]
    private var lastSoundOf: [String: Double]
    private var lastSound: Double
    private var lastRead: Double
    private let lock = NSLock()

    public init(tracks: [(label: String, url: URL)], clock: @escaping () -> Double = monotonicSeconds,
                soundDbfs: Double = LevelTracker.soundDbfs, files: LevelFiles = .real) {
        self.tracks = tracks
        self.clock = clock
        self.soundDbfs = soundDbfs
        self.files = files
        let start = clock()
        offsets = Dictionary(uniqueKeysWithValues: tracks.map { ($0.label, Self.headerSize) })
        lastAudio = Dictionary(uniqueKeysWithValues: tracks.map { ($0.label, start) })
        lastSoundOf = lastAudio
        lastSound = start
        lastRead = start
    }

    public func read() -> [Reading] {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        lastRead = now
        var readings: [Reading] = []
        for (label, url) in tracks {
            let db = readNew(label, url)
            if let db {
                lastAudio[label] = now
                if db >= soundDbfs { lastSound = now; lastSoundOf[label] = now }
            }
            readings.append(Reading(label: label, db: db, silentFor: now - lastAudio[label]!))
        }
        return readings
    }

    /// Seconds, up to the last `read()`, that no track had sound (or the track `label`: "system", the
    /// others in a call).
    public func quietFor(_ label: String? = nil) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let label else { return lastRead - lastSound }
        return lastRead - (lastSoundOf[label] ?? lastSound)
    }

    private func readNew(_ label: String, _ url: URL) -> Double? {
        guard let size = files.size(url) else { return nil }
        var start = max(offsets[label]!, size - Self.maxTickBytes)
        start += (start - Self.headerSize) % 2  // stay sample-aligned
        guard size > start else { return nil }
        guard let data = files.read(url, start, size - start) else { return nil }
        offsets[label] = size
        return levelDbfs(data)
    }
}
