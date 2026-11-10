// A meeting's audio for the page's player (api.py `_tracks`, `AudioSource`, :2093-2148; server.py `_audio`,
// :816-841): one 16-bit mono WAV, the microphone and the other side summed on the fly, so any byte range is
// answered without writing a mixed copy. A range is read in slices of AUDIO_SLICE_BYTES; every sample's bytes
// depend on that sample only, so slices stitch to the bytes Python reads in one go.
import Darwin
import Foundation
import PalaverCore
import PalaverDomain

/// The audio of `paths` as `track` ("system", or "mix": the microphone, cleaned or raw, and the system track).
public final class AudioSource {
    public static let HEADER = 44
    /// The most one answer holds unless the page asks for the last N bytes (server.py:43).
    public static let AUDIO_SLICE_BYTES = 1 << 21

    private let files: [URL]
    public let sampleRate: Int
    public let frames: Int
    /// The WAV's bytes: the header and two per frame of the longest track.
    public let size: Int

    /// `AudioSource(paths, track)`: `NotFound(track)` for a track not named or not there; a file that is no
    /// 16-bit PCM WAV throws as `sf.info` would.
    public init(paths: RecordingPaths, track: String) throws {
        files = try Self.tracks(paths, track)
        let infos = try files.map { try Wav16.info($0) }
        sampleRate = infos[0].rate
        frames = infos.map(\.frames).max()!
        size = Self.HEADER + 2 * frames
    }

    /// `_tracks`: the files a track is made of, those there.
    static func tracks(_ paths: RecordingPaths, _ track: String) throws -> [URL] {
        let named: [URL]
        if track == "system" {
            named = [paths.systemWav]
        } else if track == "mix" {
            named = [MeetingsAPI.exists(paths.micWav) ? paths.micWav : paths.micRawWav, paths.systemWav]
        } else {
            throw NotFound(track)
        }
        let found = named.filter { MeetingsAPI.exists($0) }
        if found.isEmpty { throw NotFound(track) }
        return found
    }

    /// The canonical header for `frames` of mono 16-bit at the first track's rate.
    private var header: [UInt8] {
        var h: [UInt8] = []
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { h += $0 } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { h += $0 } }
        let data = 2 * frames
        h += Array("RIFF".utf8); put32(36 + data); h += Array("WAVEfmt ".utf8)
        put32(16); put16(1); put16(1); put32(sampleRate); put32(2 * sampleRate); put16(2); put16(16)
        h += Array("data".utf8); put32(data)
        return h
    }

    /// The bytes of `range` (an empty one: none), read a slice at a time.
    public func read(range: Range<Int>) throws -> Data {
        var out = Data(capacity: range.count)
        var at = range.lowerBound
        while at < range.upperBound {
            let next = min(range.upperBound, at + Self.AUDIO_SLICE_BYTES)
            try out.append(contentsOf: slice(at, next - 1))
            at = next
        }
        return out
    }

    /// `read(start, end)`: bytes `start` ... `end` inclusive — the header's, then the mix's: int16 samples summed as
    /// int32, clipped to int16.
    private func slice(_ start: Int, _ end: Int) throws -> [UInt8] {
        var start = start
        var out: [UInt8] = []
        if start < Self.HEADER {
            out = Array(header[start..<min(end + 1, Self.HEADER)])
            start = Self.HEADER
        }
        if end < start { return out }
        let first = (start - Self.HEADER) / 2, last = (end - Self.HEADER) / 2 + 1
        var mix = [Int32](repeating: 0, count: last - first)
        for f in files {
            let chunk = try Self.firstChannel(f, start: first, frames: last - first)
            for (i, s) in chunk.enumerated() { mix[i] += Int32(s) }
        }
        var pcm = [UInt8](repeating: 0, count: 2 * mix.count)
        for (i, s) in mix.enumerated() {
            let v = UInt16(bitPattern: Int16(max(-32768, min(32767, s))))
            pcm[2 * i] = UInt8(v & 0xFF)
            pcm[2 * i + 1] = UInt8(v >> 8)
        }
        let offset = (start - Self.HEADER) % 2
        return out + pcm[offset..<offset + end - start + 1]
    }

    /// `sf.read(f, start=, stop=, dtype="int16", always_2d=True)[:, 0]`: the first channel of `frames` from `start`,
    /// fewer where the file ends. The file is looked at again (a track still recorded grows); one cut short between
    /// that look and the read reads what is left.
    static func firstChannel(_ url: URL, start: Int, frames: Int) throws -> [Int16] {
        let info = try Wav16.info(url)
        let count = max(0, min(frames, info.frames - start))
        if count == 0 { return [] }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let block = 2 * info.channels
        var raw = [UInt8](repeating: 0, count: count * block)
        var done = 0
        try raw.withUnsafeMutableBytes { buf in
            while done < buf.count {
                let n = pread(fd, buf.baseAddress! + done, buf.count - done, off_t(info.dataOffset + start * block + done))
                if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if n == 0 { break }
                done += n
            }
        }
        let whole = done / block
        return (0..<whole).map { Int16(bitPattern: UInt16(raw[$0 * block]) | UInt16(raw[$0 * block + 1]) << 8) }
    }
}

enum AudioRoute {
    /// A number of the Range header, capped where it is past any file (Python's ints have no end).
    private static func number(_ digits: Substring) -> Int {
        var n = 0
        for d in digits.utf8 {
            if n >= 1 << 59 { return 1 << 60 }
            n = n * 10 + Int(d - 48)
        }
        return n
    }

    /// `bytes=(\d*)-(\d*)` (ASCII digits: the header is Latin-1 to Python, which has no other) as start and end,
    /// nil each where empty; nil for a header that is not one range.
    static func parse(_ header: String) -> (Substring, Substring)? {
        let text = Py.strip(header)
        guard text.hasPrefix("bytes=") else { return nil }
        let rest = text.dropFirst(6)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let a = rest[..<dash], b = rest[rest.index(after: dash)...]
        let digit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        guard a.allSatisfy(digit), b.allSatisfy(digit) else { return nil }
        return (a, b)
    }

    /// `_audio`: 206 with the range asked for (from its start at most a slice; the first slice without a range), or
    /// 416 past the end. HEAD: the same headers, no body read.
    static func answer(_ app: ServerApp, _ request: Request, id: String) throws -> Response {
        let paths = try MeetingsAPI.meetingPaths(outputDir: app.outputDir, id: id)
        let source = try AudioSource(paths: paths, track: request.queryValue("track") ?? "mix")
        let slice = AudioSource.AUDIO_SLICE_BYTES, size = source.size
        let start: Int, end: Int
        if let (a, b) = parse(request.header("Range") ?? ""), !(a.isEmpty && b.isEmpty) {
            if a.isEmpty {  // the last N bytes
                start = max(0, size - number(b))
                end = size - 1
            } else {
                start = number(a)
                end = min(b.isEmpty ? start + slice - 1 : number(b), size - 1, start + slice - 1)
            }
        } else {
            start = 0
            end = min(size, slice) - 1
        }
        if start >= size {
            return Response(status: 416, headers: [("Content-Range", "bytes */\(size)")], body: Data())
        }
        let body = request.method == "HEAD" ? Data() : try source.read(range: start..<max(start, end + 1))
        return Response(status: 206, headers: [("Content-Type", "audio/wav"), ("Accept-Ranges", "bytes"),
                                               ("Content-Range", "bytes \(start)-\(end)/\(size)"),
                                               ("Content-Length", String(end - start + 1))], body: body)
    }
}

extension Router {
    /// The meeting's audio and its calendar event choices (server.py's GET branches).
    static func addAudioEventRoutes(_ r: Router, app: ServerApp) {
        r.get("/api/meetings/([^/]+)/events") { _, m in .json(.array(try EventsAPI.meetingEvents(app: app, id: m.group(1)!))) }
        r.get("/api/meetings/([^/]+)/audio") { request, m in try AudioRoute.answer(app, request, id: m.group(1)!) }
    }
}
