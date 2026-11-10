// The audio of an exported meeting (exchange.py:402-414 `_encode_audio`, :865-926 `_write_audio`, `_decode_mixed`).
//
// Export: each track compressed, Ogg Opus at the rates Opus takes, else 16-bit FLAC, block by block.
// Import: the tracks copied out of the zip (checked against the manifest as they are), checked (readable, 8 to 48 kHz,
// one or two channels, no longer than the meeting and a minute), the free space checked, then decoded and mixed into
// the one system track the window plays, at the system track's rate (the microphone's resampled with AVAudioConverter
// at `.max` quality), 10 s at a time, written as 16-bit PCM the way libsndfile writes floats (`lrintf(x * 0x7FFF)`).
// The audio is untrusted: anything malformed is `ExchangeRejected`, never a trap.
import AVFoundation
import Foundation
import PalaverCore

public enum ExchangeAudio {
    /// `<track>.opus` at the rates Opus takes, else `<track>.flac`.
    public static let OPUS_RATES = OggOpus.OPUS_RATES

    /// `_encode_audio`: `wav` compressed into `destDir` as `<track>.opus` or `<track>.flac`; the file written.
    @discardableResult
    public static func encodeTrack(_ wav: URL, destDir: URL, track: String) throws -> URL {
        let info = try Wav16.info(wav)
        if OPUS_RATES.contains(info.rate) {
            let out = destDir.appendingPathComponent("\(track).opus")
            try OggOpus.encode(wav: wav, to: out)
            return out
        }
        let out = destDir.appendingPathComponent("\(track).flac")
        try Flac.encode(wav: wav, to: out)
        return out
    }

    /// An audio file of an import, by what it holds (as libsndfile looks at the bytes, not the name): Ogg is read as
    /// Ogg Opus, anything else by AudioToolbox.
    public static func open(_ url: URL) throws -> AudioSource {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AudioError("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var magic = [UInt8](repeating: 0, count: 4)
        let n = magic.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 4) }
        Darwin.close(fd)
        if n == 4 && magic == Array("OggS".utf8) { return try OggOpus.Reader(url) }
        return try Flac.Reader(url)
    }

    /// `_write_audio`: the package's tracks out of its zip into `staging` (checked against the manifest as they are
    /// copied), decoded and mixed into `folder`'s system track: the sender's microphone is a remote voice here, and the
    /// user has no microphone in a meeting they were not in. `freeBytes` is `_free_bytes` (tests make the disk full).
    public static func writeSystemTrack(package: ExchangePackage, staging: URL, folder: URL,
                                        freeBytes: (URL) throws -> Int = Exchange.freeBytes) throws {
        var tracks: [(track: String, raw: URL)] = []
        if !package.audio.isEmpty {
            let zip = try ExchangeZip.open(package.url)
            let (_, entries) = try ExchangeZip.entries(zip)
            let listed = PyDict<JSONValue>(package.manifest["files"] ?? .null) ?? PyDict()
            for name in package.audio {
                guard let entry = entries[name] else { throw ExchangeRejected("The file lacks \(ExchangeZip.repr(name)).") }
                let raw = staging.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
                let sink = try FileSink(raw)
                defer { sink.close() }
                try ExchangeZip.readEntry(zip, name, entry, expected: listed[name] ?? .null, sink: { try sink.write($0) })
                let track = String(name.unicodeScalars.split(separator: "/")[1].split(separator: ".")[0])
                tracks.removeAll { $0.track == track }  // a dict's assignment: the same key once
                tracks.append((track, raw))
            }
        }
        if tracks.isEmpty { return }
        var infos: [String: (rate: Int, channels: Int, frames: Int)] = [:]
        for (track, raw) in tracks {
            let source: AudioSource
            do { source = try open(raw) } catch { throw ExchangeRejected("The \(track) audio can't be read.") }
            defer { source.close() }
            if !(8000...48000).contains(source.rate) || !(1...2).contains(source.channels)
                || Double(source.frames) / Double(source.rate) > package.duration + 60 {
                throw ExchangeRejected("The \(track) audio does not fit the meeting.")
            }
            infos[track] = (source.rate, source.channels, source.frames)
        }
        let rate = infos["system"]?.rate ?? infos["mic"]!.rate
        let frames = infos.values.map { Int(Double($0.frames * rate) / Double($0.rate)) + 1 }.max() ?? 0
        if try freeBytes(staging) - (44 + 2 * frames) < Exchange.MIN_FREE_BYTES {
            throw ExchangeRejected("Not enough free disk space for its audio: import it without, or make room first.")
        }
        let sources = ["system", "mic"].compactMap { t in tracks.first { $0.track == t }?.raw }
        try decodeMixed(sources, rate: rate, dest: RecordingPaths(folder).systemWav)
    }

    /// A file a downloaded entry is written to, front to back.
    private final class FileSink {
        let fd: Int32
        let path: String
        init(_ url: URL) throws {
            path = url.path
            fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw AudioError("\(path): \(String(cString: strerror(errno)))") }
        }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw AudioError("\(path): \(String(cString: strerror(errno)))") }
                    done += n
                }
            }
        }
        func close() { Darwin.close(fd) }
    }

    /// `_decode_mixed`: `sources` mixed into one 16-bit mono WAV at `rate`, 10 s of each at a time (each at its own
    /// rate, its channels averaged, resampled when it is not at `rate`), summed and clipped.
    static func decodeMixed(_ sources: [URL], rate: Int, dest: URL) throws {
        var files: [AudioSource] = []
        defer { for f in files { f.close() } }
        do {
            for s in sources { files.append(try open(s)) }
            let streams = try files.map { $0.rate == rate ? nil : try Resampler(from: $0.rate, to: rate) }
            let out = try Wav16.Writer(dest, rate: rate)
            defer { out.close() }
            var done = [Bool](repeating: false, count: files.count)
            while !done.allSatisfy({ $0 }) {
                var parts: [[Float]] = []
                for (i, f) in files.enumerated() where !done[i] {
                    let raw = try f.read(maxFrames: f.rate * OggOpus.BLOCK_SECONDS)
                    var block = mean(raw, channels: f.channels)
                    done[i] = block.isEmpty
                    if let stream = streams[i] { block = try stream.process(block, last: done[i]) }
                    parts.append(block)
                }
                let n = parts.map(\.count).max() ?? 0
                if n == 0 { continue }
                var mix = [Float](repeating: 0, count: n)
                for part in parts { for j in 0..<part.count { mix[j] += part[j] } }
                var pcm = [Int16](repeating: 0, count: n)
                for j in 0..<n { pcm[j] = pcm16(min(max(mix[j], -1), 1)) }
                try out.append(pcm)
            }
            try out.finish()
        } catch let error as AudioError {
            throw ExchangeRejected("The audio can't be decoded (\(error.description)).")
        } catch let error as WavError {
            throw ExchangeRejected("The audio can't be decoded (\(error.description)).")
        }
    }

    /// `.mean(axis=1)` of a float32 block: each frame's channels summed in order, divided by their number.
    static func mean(_ samples: [Float], channels: Int) -> [Float] {
        if channels == 1 { return samples }
        let frames = samples.count / channels
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i * channels + c] }
            out[i] = sum / Float(channels)
        }
        return out
    }

    /// libsndfile's float to 16-bit PCM: `lrintf(x * 0x7FFF)` (in float, ties to even).
    static func pcm16(_ x: Float) -> Int16 { Int16((x * Float(0x7FFF)).rounded(.toNearestOrEven)) }

    /// A mono float stream resampled block by block (`soxr.ResampleStream` in Python): AVAudioConverter at `.max`
    /// quality, fed each block as it comes, flushed on the last.
    public final class Resampler {
        private let converter: AVAudioConverter
        private let input: AVAudioFormat, output: AVAudioFormat
        private let ratio: Double
        private var ended = false

        public init(from: Int, to: Int) throws {
            guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(from), channels: 1, interleaved: false),
                  let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(to), channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: input, to: output) else {
                throw AudioError("no resampler from \(from) Hz to \(to) Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.input = input
            self.output = output
            self.converter = converter
            ratio = Double(to) / Double(from)
        }

        public func process(_ block: [Float], last: Bool) throws -> [Float] {
            guard !ended else { return [] }
            var given = block.isEmpty
            var buffer: AVAudioPCMBuffer?
            if !block.isEmpty {
                guard let b = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(block.count)) else {
                    throw AudioError("no buffer for the resampler")
                }
                b.frameLength = AVAudioFrameCount(block.count)
                block.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: block.count) }
                buffer = b
            }
            var out: [Float] = []
            while true {
                let capacity = AVAudioFrameCount(Double(block.count) * ratio) + 4096
                guard let o = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw AudioError("no buffer for the resampler") }
                var error: NSError?
                let status = converter.convert(to: o, error: &error) { _, state in
                    if !given, let buffer {
                        given = true
                        state.pointee = .haveData
                        return buffer
                    }
                    state.pointee = last ? .endOfStream : .noDataNow
                    return nil
                }
                if status == .error { throw AudioError("the resampler failed (\(error?.localizedDescription ?? "?"))") }
                if o.frameLength > 0 {
                    out += UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength))
                }
                if status == .endOfStream { ended = true; break }
                if status == .inputRanDry || (status == .haveData && o.frameLength == 0) { break }
            }
            return out
        }
    }
}
