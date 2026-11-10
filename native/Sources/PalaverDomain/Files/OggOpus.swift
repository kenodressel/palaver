// Ogg Opus as Python's soundfile (libsndfile 1.2.2, ogg_opus.c) writes and reads it, on the vendored libopus and
// libogg: an exchange's audio (exchange.py `_encode_audio`, `_write_audio`).
//
// Writing: OpusHead (version 1, the WAV's rate stored as the input rate, pre-skip = the encoder's lookahead at 48 kHz,
// gain 0, mapping 0) alone on the first page; OpusTags (vendor `opus_get_version_string()`, no comments, zero-padded by
// libsndfile's `vorbiscomment_write_tags(..., -512)` rule) on its own page; then 20 ms packets of
// `OPUS_APPLICATION_AUDIO` at the default bitrate and complexity 10, a page flushed once it holds a second of audio
// (libsndfile's page latency) or 255 segments, granule positions without the pre-skip; the last packet shortened to
// the shortest frame that covers the end and the pre-skip, its page (end of stream) at pre-skip + length.
// The WAV is read in 10 s blocks: a track is never in memory whole.
//
// Reading (`Reader`): the first logical stream, decoded at the lowest Opus rate at or above the stored input rate (as
// libsndfile), its header gain applied, the pre-skip dropped and the length taken from the last page's granule
// position (found from the file's end). The file is untrusted: anything malformed throws `AudioError`, never traps.
import COgg
import COpus
import Darwin
import Foundation

/// Audio that can't be read, written or decoded; the message says what.
public struct AudioError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A decoded audio file read block by block: interleaved float samples, `channels` per frame.
public protocol AudioSource: AnyObject {
    var rate: Int { get }
    var channels: Int { get }
    /// What the file says it holds (`sf.info(...).frames`).
    var frames: Int { get }
    /// Up to `maxFrames` frames, interleaved; empty at the end.
    func read(maxFrames: Int) throws -> [Float]
    func close()
}

public enum OggOpus {
    /// `exchange._OPUS_RATES`: the rates Opus takes.
    public static let OPUS_RATES = [8000, 12000, 16000, 24000, 48000]
    /// libsndfile's `OGG_OPUS_COMMENT_PAD`.
    static let COMMENT_PAD = 512
    /// libsndfile's default page latency: a second, in 48 kHz granules.
    static let PAGE_LATENCY: Int64 = 1000 * 48
    /// `blocksize=info.samplerate * 10`.
    static let BLOCK_SECONDS = 10
    /// The longest Opus packet: 120 ms at 48 kHz.
    static let MAX_PACKET_FRAMES = 5760
    static let READ_BYTES = 1 << 16

    /// `opus_get_version_string()`: the OpusTags vendor string.
    public static var vendor: String { String(cString: opus_get_version_string()) }

    // MARK: - Writing

    /// `wav` (16-bit PCM, one or two channels, at a rate in `OPUS_RATES`) as Ogg Opus at `out`, block by block.
    public static func encode(wav: URL, to out: URL) throws {
        let info = try Wav16.info(wav)
        guard OPUS_RATES.contains(info.rate) else { throw AudioError("Opus takes no \(info.rate) Hz audio") }
        guard (1...2).contains(info.channels) else { throw AudioError("Opus is written here for 1 or 2 channels, not \(info.channels)") }
        let writer = try Writer(out, rate: info.rate, channels: info.channels)
        defer { writer.close() }
        let step = info.rate * BLOCK_SECONDS
        var at = 0
        while at < info.frames {
            let samples = try Wav16.read(wav, start: at, frames: min(step, info.frames - at))
            if samples.isEmpty { break }
            var floats = [Float](repeating: 0, count: samples.count)
            for i in 0..<samples.count { floats[i] = Float(samples[i]) / 32768 }  // sf.blocks(dtype="float32")
            try writer.write(floats)
            at += samples.count / info.channels
        }
        try writer.finish()
    }

    /// The bytes libsndfile writes as OpusHead.
    static func head(channels: Int, preskip: Int, rate: Int) -> [UInt8] {
        Array("OpusHead".utf8) + [1, UInt8(channels)] + le(UInt64(preskip), 2) + le(UInt64(rate), 4) + le(0, 2) + [0]
    }

    /// The bytes libsndfile writes as OpusTags: the vendor, no comments, zeros to `(size + 512 + 255) / 255 * 255 - 1`
    /// bytes more.
    static func tags(vendor: String) -> [UInt8] {
        let v = Array(vendor.utf8)
        var out = Array("OpusTags".utf8) + le(UInt64(v.count), 4) + v + le(0, 4)
        out += [UInt8](repeating: 0, count: (out.count + COMMENT_PAD + 255) / 255 * 255 - 1)
        return out
    }

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// An Ogg Opus file written front to back: `write` interleaved floats, then `finish`.
    final class Writer {
        private let fd: Int32
        private let path: String
        private var stream = ogg_stream_state()
        private let encoder: OpaquePointer
        private let rate: Int, channels: Int, factor: Int, frameLength: Int
        private let preskip: Int
        private var pending: [Float] = []  // interleaved samples not yet encoded
        private var packetNumber: Int64 = 0
        private var packetPosition: Int64 = 0  // granules (48 kHz) of the packets so far
        private var pagePosition: Int64 = 0
        private var lastSegments = 0
        private var wroteAudio = false
        private var closed = false
        private var packet = [UInt8](repeating: 0, count: 4000)

        init(_ url: URL, rate: Int, channels: Int) throws {
            self.rate = rate
            self.channels = channels
            factor = 48000 / rate
            frameLength = 20 * rate / 1000  // OGG_OPUS_ENCODE_PACKET_LEN
            var error: Int32 = 0
            guard let encoder = opus_encoder_create(Int32(rate), Int32(channels), OPUS_APPLICATION_AUDIO, &error),
                  error == OPUS_OK else { throw AudioError("the Opus encoder can't start (\(error))") }
            self.encoder = encoder
            _ = palaver_opus_encoder_set_complexity(encoder, 10)  // as libsndfile; a failure is not fatal there either
            var lookahead: Int32 = 0
            guard palaver_opus_encoder_get_lookahead(encoder, &lookahead) == OPUS_OK else {
                opus_encoder_destroy(encoder)
                throw AudioError("the Opus encoder has no lookahead")
            }
            preskip = Int(lookahead) * factor
            path = url.path
            fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
            guard fd >= 0 else {
                let e = errno
                opus_encoder_destroy(encoder)
                throw AudioError("\(url.path): \(String(cString: strerror(e)))")
            }
            ogg_stream_init(&stream, Int32(bitPattern: UInt32.random(in: 0...UInt32.max)))
            do {
                try packetIn(OggOpus.head(channels: channels, preskip: preskip, rate: rate), granule: 0, bos: true, eos: false)
                try flushAll()  // the first page holds only the header
                try packetIn(OggOpus.tags(vendor: OggOpus.vendor), granule: 0, bos: false, eos: false)
                try flushAll()
            } catch {
                close()
                throw error
            }
        }

        deinit { close() }

        func close() {
            guard !closed else { return }
            closed = true
            ogg_stream_clear(&stream)
            opus_encoder_destroy(encoder)
            Darwin.close(fd)
        }

        func write(_ samples: [Float]) throws {
            pending += samples
            let n = frameLength * channels
            var at = 0
            while pending.count - at >= n {
                let bytes = try encode(pending, from: at, frames: frameLength)
                at += n
                wroteAudio = true
                // ogg_opus_write_out: the packet's end is its granule; pages before it go out first.
                lastSegments += (bytes + 255) / 255
                packetPosition += Int64(frameLength * factor)
                while true {
                    var page = ogg_page()
                    let flush = packetPosition - pagePosition >= OggOpus.PAGE_LATENCY || lastSegments >= 255
                    let got = flush ? ogg_stream_flush_fill(&stream, &page, 255 * 255) : ogg_stream_pageout_fill(&stream, &page, 255 * 255)
                    if got == 0 { break }
                    try put(page)
                    lastSegments -= Int(page.header[26])  // ogg_page_segments
                    pagePosition = packetPosition
                }
                try packetIn(Array(packet[0..<bytes]), granule: packetPosition, bos: false, eos: false)
            }
            pending.removeFirst(at)
        }

        /// ogg_opus_flush: what is left, padded with silence, and as much more as covers the pre-skip; the last
        /// packet shortened to the shortest frame that reaches the end (2.5, 5, 10 or 20 ms), at the end's granule.
        func finish() throws {
            defer { close() }
            if wroteAudio || !pending.isEmpty {
                let left = pending.count / channels
                let last = packetPosition + Int64(factor * left) + Int64(preskip)
                while true {
                    let remaining = last - packetPosition
                    var length = frameLength
                    var isLast = false
                    if remaining <= Int64(frameLength * factor) {
                        isLast = true
                        length = [rate / 400, rate / 200, rate / 100, frameLength].first { Int64($0 * factor) >= remaining } ?? frameLength
                    }
                    if pending.count < length * channels { pending += [Float](repeating: 0, count: length * channels - pending.count) }
                    let bytes = try encode(pending, from: 0, frames: length)
                    pending.removeFirst(length * channels)
                    packetPosition += Int64(length * factor)
                    try packetIn(Array(packet[0..<bytes]), granule: isLast ? last : packetPosition, bos: false, eos: isLast)
                    while true {
                        var page = ogg_page()
                        if ogg_stream_pageout(&stream, &page) == 0 { break }
                        try put(page)
                    }
                    if isLast { break }
                }
            }
            try flushAll()
        }

        private func encode(_ samples: [Float], from: Int, frames: Int) throws -> Int {
            let n = samples.withUnsafeBufferPointer { buf in
                packet.withUnsafeMutableBufferPointer { out in
                    opus_encode_float(encoder, buf.baseAddress! + from, Int32(frames), out.baseAddress!, Int32(out.count))
                }
            }
            guard n > 0 else { throw AudioError("Opus could not encode (\(n))") }
            return Int(n)
        }

        private func packetIn(_ bytes: [UInt8], granule: Int64, bos: Bool, eos: Bool) throws {
            var bytes = bytes
            let r = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
                var p = ogg_packet(packet: buf.baseAddress, bytes: buf.count, b_o_s: bos ? 1 : 0, e_o_s: eos ? 1 : 0,
                                   granulepos: granule, packetno: packetNumber)
                return ogg_stream_packetin(&stream, &p)
            }
            guard r == 0 else { throw AudioError("Ogg could not take a packet") }
            packetNumber += 1
        }

        private func flushAll() throws {
            while true {
                var page = ogg_page()
                if ogg_stream_flush(&stream, &page) == 0 { return }
                try put(page)
            }
        }

        private func put(_ page: ogg_page) throws {
            try put(page.header, page.header_len)
            try put(page.body, page.body_len)
        }

        private func put(_ p: UnsafeMutablePointer<UInt8>?, _ count: Int) throws {
            guard let p, count > 0 else { return }
            var done = 0
            while done < count {
                let n = Darwin.write(fd, p + done, count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AudioError("\(path): \(String(cString: strerror(errno)))") }
                done += n
            }
        }
    }

    // MARK: - Reading

    /// All of `url` decoded: its rate (OpusHead's input rate, as libsndfile decodes it) and its samples, interleaved.
    public static func decode(_ url: URL) throws -> (rate: Int, samples: [Float]) {
        let reader = try Reader(url)
        defer { reader.close() }
        var out: [Float] = []
        while true {
            let block = try reader.read(maxFrames: reader.rate * BLOCK_SECONDS)
            if block.isEmpty { break }
            out += block
        }
        return (reader.rate, out)
    }

    /// The decode rate for a stored input rate: the lowest Opus rate at or above it (libsndfile's
    /// `ogg_opus_setup_decoder`).
    static func decodeRate(_ input: Int) -> Int {
        input > 24000 ? 48000 : input > 16000 ? 24000 : input > 12000 ? 16000 : input > 8000 ? 12000 : 8000
    }

    /// An Ogg Opus file read page by page.
    public final class Reader: AudioSource {
        public private(set) var rate = 0
        public private(set) var channels = 0
        public private(set) var frames = 0
        private let fd: Int32
        private let path: String
        private var sync = ogg_sync_state()
        private var stream = ogg_stream_state()
        private var decoder: OpaquePointer?
        private var factor = 1
        private var eof = false
        private var closed = false
        private var queued: [[UInt8]] = []  // packets of the first audio page, read while opening
        private var skip = 0  // frames still to drop (the pre-skip)
        private var given = 0  // frames handed out
        private var decoded: [Float] = []
        private var decodedAt = 0
        private var out: [Float] = []

        public init(_ url: URL) throws {
            path = url.path
            fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw AudioError("\(url.path): \(String(cString: strerror(errno)))") }
            ogg_sync_init(&sync)
            var headers: [[UInt8]] = []
            var serial: Int32?
            var streamReady = false
            var opened = false
            defer { if !opened { closed = true; Self.release(fd, &sync, &stream, streamReady, nil) } }  // deinit then does nothing

            // The first stream's two headers.
            var page = ogg_page()
            while headers.count < 2 {
                guard try Self.nextPage(fd, &sync, &page, &eof) else { throw AudioError("not an Ogg Opus file: no Opus headers") }
                if serial == nil {
                    guard ogg_page_bos(&page) != 0 else { continue }
                    serial = ogg_page_serialno(&page)
                    guard ogg_stream_init(&stream, serial!) == 0 else { throw AudioError("Ogg could not start a stream") }
                    streamReady = true
                }
                guard ogg_page_serialno(&page) == serial else { continue }
                guard ogg_stream_pagein(&stream, &page) == 0 else { throw AudioError("a damaged Ogg page") }
                var packet = ogg_packet()
                while headers.count < 2 {
                    let r = ogg_stream_packetout(&stream, &packet)
                    if r == 0 { break }
                    guard r > 0 else { throw AudioError("an Ogg header is missing") }
                    headers.append(Self.bytes(packet))
                }
            }
            let head = headers[0]
            // opus_read_header_packet: 19 bytes for mapping 0, version 0 or 1, at most 2 channels.
            guard head.count >= 19, head.count <= 276, Array(head[0..<8]) == Array("OpusHead".utf8) else {
                throw AudioError("not an Ogg Opus file: no OpusHead")
            }
            guard head[8] >> 4 == 0 else { throw AudioError("OpusHead version \(head[8]) is not read here") }
            let channelCount = Int(head[9])
            let preskip = Int(head[10]) | Int(head[11]) << 8
            let input = Int(head[12]) | Int(head[13]) << 8 | Int(head[14]) << 16 | Int(head[15]) << 24
            let gain = Int16(bitPattern: UInt16(head[16]) | UInt16(head[17]) << 8)
            guard head[18] == 0, head.count == 19, (1...2).contains(channelCount) else {
                throw AudioError("an Opus channel mapping that is not read here (\(head[18]), \(channelCount) channels)")
            }
            guard headers[1].count >= 8, Array(headers[1][0..<8]) == Array("OpusTags".utf8) else {
                throw AudioError("not an Ogg Opus file: no OpusTags")
            }
            channels = channelCount
            rate = OggOpus.decodeRate(input)
            factor = 48000 / rate
            skip = preskip / factor

            // Where the audio starts: the first audio page's granule less the packets it ends.
            var start: Int64 = 0
            var foundAudio = false
            while !foundAudio, try Self.nextPage(fd, &sync, &page, &eof) {
                guard ogg_page_serialno(&page) == serial else { continue }
                guard ogg_stream_pagein(&stream, &page) == 0 else { throw AudioError("a damaged Ogg page") }
                var packet = ogg_packet()
                while true {
                    let r = ogg_stream_packetout(&stream, &packet)
                    if r == 0 { break }
                    if r < 0 { continue }  // a hole: the next packet
                    queued.append(Self.bytes(packet))
                }
                let granule = ogg_page_granulepos(&page)
                if granule >= 0 && !queued.isEmpty {
                    var samples: Int64 = 0
                    for q in queued where !q.isEmpty {
                        let n = q.withUnsafeBufferPointer { opus_packet_get_nb_samples($0.baseAddress!, Int32($0.count), 48000) }
                        guard n > 0 else { throw AudioError("a damaged Opus packet") }
                        samples += Int64(n)
                    }
                    // A first page that also ends the stream may end before its packets do: it starts at 0.
                    start = ogg_page_eos(&page) != 0 ? 0 : granule - samples
                    foundAudio = true
                }
            }
            if foundAudio {
                let end = try Self.lastGranule(fd, serial: serial!)
                let (span, over) = end.subtractingReportingOverflow(start &+ Int64(preskip))
                guard !over, span >= 0, span / Int64(factor) <= Int64(Int32.max) * 64 else {
                    throw AudioError("the Ogg Opus file's length is damaged")
                }
                frames = Int(span / Int64(factor))
            } else {
                frames = 0
            }
            var error: Int32 = 0
            guard let decoder = opus_decoder_create(Int32(rate), Int32(channels), &error), error == OPUS_OK else {
                throw AudioError("the Opus decoder can't start (\(error))")
            }
            _ = palaver_opus_decoder_set_gain(decoder, Int32(gain))
            self.decoder = decoder
            opened = true
        }

        deinit { close() }

        public func close() {
            guard !closed else { return }
            closed = true
            Self.release(fd, &sync, &stream, true, decoder)
        }

        private static func release(_ fd: Int32, _ sync: inout ogg_sync_state, _ stream: inout ogg_stream_state,
                                    _ streamReady: Bool, _ decoder: OpaquePointer?) {
            if streamReady { ogg_stream_clear(&stream) }
            ogg_sync_clear(&sync)
            if let decoder { opus_decoder_destroy(decoder) }
            Darwin.close(fd)
        }

        public func read(maxFrames: Int) throws -> [Float] {
            guard !closed else { throw AudioError("\(path): read after close") }
            out.removeAll(keepingCapacity: true)
            let want = min(maxFrames, frames - given)
            while out.count < want * channels {
                if decodedAt < decoded.count {
                    let n = min(decoded.count - decodedAt, want * channels - out.count)
                    out += decoded[decodedAt..<(decodedAt + n)]
                    decodedAt += n
                    continue
                }
                guard let packet = try nextPacket() else { break }
                try decode(packet)
            }
            given += out.count / channels
            return out
        }

        private func decode(_ packet: [UInt8]) throws {
            guard !packet.isEmpty, let decoder else { return }
            var buffer = [Float](repeating: 0, count: OggOpus.MAX_PACKET_FRAMES * channels)
            let n = packet.withUnsafeBufferPointer { p in
                buffer.withUnsafeMutableBufferPointer { b in
                    opus_decode_float(decoder, p.baseAddress!, Int32(p.count), b.baseAddress!, Int32(OggOpus.MAX_PACKET_FRAMES), 0)
                }
            }
            guard n >= 0 else { throw AudioError("a damaged Opus packet (\(String(cString: opus_strerror(n))))") }
            let dropped = min(skip, Int(n))
            skip -= dropped
            decoded = Array(buffer[(dropped * channels)..<(Int(n) * channels)])
            decodedAt = 0
        }

        private func nextPacket() throws -> [UInt8]? {
            if !queued.isEmpty { return queued.removeFirst() }
            var packet = ogg_packet()
            var page = ogg_page()
            while true {
                let r = ogg_stream_packetout(&stream, &packet)
                if r > 0 { return Self.bytes(packet) }
                if r < 0 { continue }  // a hole: decoding goes on, as libsndfile's
                guard try Self.nextPage(fd, &sync, &page, &eof) else { return nil }
                _ = ogg_stream_pagein(&stream, &page)  // another stream's page is refused: skipped
            }
        }

        static func bytes(_ p: ogg_packet) -> [UInt8] {
            guard let base = p.packet, p.bytes > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: p.bytes))
        }

        /// The next whole page (CRC checked by libogg), reading on as needed; false at the file's end.
        static func nextPage(_ fd: Int32, _ sync: inout ogg_sync_state, _ page: inout ogg_page, _ eof: inout Bool) throws -> Bool {
            while true {
                let r = ogg_sync_pageout(&sync, &page)
                if r > 0 { return true }
                if r < 0 { continue }  // bytes skipped to the next page
                if eof { return false }
                guard let buffer = ogg_sync_buffer(&sync, OggOpus.READ_BYTES) else { throw AudioError("out of memory") }
                var n: Int
                repeat { n = Darwin.read(fd, buffer, OggOpus.READ_BYTES) } while n < 0 && errno == EINTR
                guard n >= 0 else { throw AudioError(String(cString: strerror(errno))) }
                if n == 0 { eof = true }
                ogg_sync_wrote(&sync, n)
            }
        }

        /// The granule position of the stream's last page with one, read from the file's end (more of it while none
        /// is found).
        static func lastGranule(_ fd: Int32, serial: Int32) throws -> Int64 {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw AudioError(String(cString: strerror(errno))) }
            let size = Int64(st.st_size)
            var window: Int64 = 1 << 16
            while true {
                let from = max(0, size - window)
                var sync = ogg_sync_state()
                ogg_sync_init(&sync)
                defer { ogg_sync_clear(&sync) }
                var at = from
                var found: Int64?
                var page = ogg_page()
                while at < size {
                    let count = Int(min(Int64(OggOpus.READ_BYTES), size - at))
                    guard let buffer = ogg_sync_buffer(&sync, count) else { throw AudioError("out of memory") }
                    var n: Int
                    repeat { n = pread(fd, buffer, count, off_t(at)) } while n < 0 && errno == EINTR
                    guard n > 0 else { break }
                    ogg_sync_wrote(&sync, n)
                    at += Int64(n)
                    while true {
                        let r = ogg_sync_pageout(&sync, &page)
                        if r == 0 { break }
                        if r < 0 { continue }
                        if ogg_page_serialno(&page) == serial && ogg_page_granulepos(&page) >= 0 {
                            found = ogg_page_granulepos(&page)
                        }
                    }
                }
                if let found { return found }
                guard from > 0 else { throw AudioError("the Ogg Opus file has no end") }
                window *= 4
            }
        }
    }
}
