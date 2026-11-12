// The audio of an exported meeting (exchange.py:402-414, 865-926): the audio tests of test_exchange.py (with 2 to 4 s
// of audio, not 60: libopus is unoptimized in debug builds), Ogg Opus and FLAC against Python's soundfile both ways
// (golden `exchange_zip_audio`, and the repo's venv decoding what is written here), and malformed audio that must
// throw, never trap. Tones only; fictional people (ExchangeImportTests' meeting: Valerie exports, Timo imports).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct ExchangeAudioTests {
    typealias Import = ExchangeImportTests
    static let SR = 16_000

    static func valerie(_ r: Import.Root, audio: Int = 4) throws -> RecordingPaths {
        try Import.makeMeeting(r.t.url.appendingPathComponent("valerie"), audio: audio)
    }

    static func entries(_ zip: URL) throws -> [ZipEntry] { try ZipReader(url: zip, maxDirectoryBytes: 1 << 20).entries }

    static func entryData(_ zip: URL, _ name: String) throws -> Data {
        let reader = try ZipReader(url: zip, maxDirectoryBytes: 1 << 20)
        return try reader.data(try #require(reader.entries.first { $0.name == name }), limit: 1 << 26)
    }

    /// A tone of `hz` at `amplitude` (of full scale), faded in over a quarter second, as 16-bit samples.
    static func tone(_ rate: Int, seconds: Double, hz: Double, amplitude: Double) -> [Int16] {
        (0..<Int(Double(rate) * seconds)).map { i in
            let t = Double(i) / Double(rate)
            return Int16((32767 * amplitude * sin(2 * .pi * hz * t) * min(1, 4 * t)).rounded())
        }
    }

    /// The power of `hz` in `x` (Goertzel).
    static func power(_ x: [Float], rate: Int, hz: Double) -> Double {
        let w = 2 * Double.pi * hz / Double(rate), c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + c * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - c * s1 * s2
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<n { ab += Double(a[i]) * Double(b[i]); aa += Double(a[i]) * Double(a[i]); bb += Double(b[i]) * Double(b[i]) }
        return ab / (aa * bb).squareRoot()
    }

    static func maxDifference(_ a: [Int16], _ b: [Int16]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - test_exchange.py

    @Test func test_audio_goes_in_only_when_asked_compressed() throws {
        let r = Import.Root(); defer { r.remove() }
        let paths = try Self.valerie(r)
        #expect(!(try Self.entries(try r.export(paths, "a.zip"))).contains { $0.name.hasPrefix("audio/") })
        let out = try r.export(paths, "b.zip", audio: true)
        let audio = try Self.entries(out).filter { $0.name.hasPrefix("audio/") }
        #expect(Set(audio.map(\.name)) == ["audio/system.opus", "audio/mic.opus"])
        #expect(audio.allSatisfy { $0.method == 0 })  // stored: deflating it again gains nothing
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        let wav = try FileManager.default.attributesOfItem(atPath: paths.systemWav.path)[.size] as! Int
        #expect(size < wav)
        // The manifest lists them like any file.
        let manifest = try Import.doc(out, "manifest.json")
        let listed = try #require(manifest["files"]?["audio/system.opus"])
        let data = try Self.entryData(out, "audio/system.opus")
        #expect(listed["sha256"] == .string(sha256Hex(data)) && listed["bytes"] == .int(data.count))
    }

    @Test func test_audio_comes_in_as_one_track_the_window_plays() throws {
        let r = Import.Root(); defer { r.remove() }
        try r.importInto(r.mine, try r.export(try Self.valerie(r), "x.zip", audio: true))
        let info = try Wav16.info(r.here().systemWav)
        #expect(info.rate == Self.SR && abs(Double(info.frames) / Double(Self.SR) - 4) < 0.5 && info.channels == 1)
        #expect(!Import.exists(r.here().micWav))
    }

    @Test func test_tracks_of_different_rates_become_one_system_track() throws {
        let r = Import.Root(); defer { r.remove() }
        let paths = try Self.valerie(r)
        try Wav16.write(Self.tone(48_000, seconds: 4, hz: 440, amplitude: 0.3), rate: 48_000, to: paths.micWav)
        try r.importInto(r.mine, try r.export(paths, "x.zip", audio: true))
        let audio = try Wav16.readFloat(r.here().systemWav)
        #expect(abs(Double(audio.count) / Double(Self.SR) - 4) < 0.5 && !Import.exists(r.here().micWav))
        let head = Array(audio.prefix(Self.SR * 4))
        let others = stride(from: 100.0, to: 3000, by: 37).map { Self.power(head, rate: Self.SR, hz: $0) }.sorted()
        #expect(Self.power(head, rate: Self.SR, hz: 440) > 10 * others[others.count / 2])  // the sender's microphone is in it
    }

    @Test func test_a_microphone_alone_becomes_the_system_track() throws {
        let r = Import.Root(); defer { r.remove() }
        let paths = try Self.valerie(r)
        try FileManager.default.removeItem(at: paths.systemWav)
        try r.importInto(r.mine, try r.export(paths, "x.zip", audio: true))
        #expect(Import.exists(r.here().systemWav) && !Import.exists(r.here().micWav))
    }

    @Test func test_audio_is_not_decoded_onto_a_nearly_full_disk() throws {
        let r = Import.Root(); defer { r.remove() }
        let out = try r.export(try Self.valerie(r, audio: 2), "x.zip", audio: true)
        try r.rejected(out, "Not enough free disk space", freeBytes: { _ in Exchange.MIN_FREE_BYTES + 1000 })
    }

    @Test func test_audio_broken_after_its_header_is_rejected() throws {
        let r = Import.Root(); defer { r.remove() }
        let out = try r.export(try Self.valerie(r, audio: 2), "x.zip", audio: true)
        var opus = [UInt8](try Self.entryData(out, "audio/system.opus"))
        for i in 300..<opus.count { opus[i] = UInt8(((i - 300) * 37) % 256) }
        try r.rejected(try r.repack(out, "y.zip", change: ["audio/system.opus": Data(opus)]), "audio")
    }

    @Test func test_audio_that_is_not_audio_is_rejected() throws {
        let r = Import.Root(); defer { r.remove() }
        let out = try r.export(try Self.valerie(r, audio: 2), "x.zip", audio: true)
        try r.rejected(try r.repack(out, "y.zip", change: ["audio/system.opus": Data("not audio at all".utf8)]), "can't be read")
    }

    // MARK: - against Python

    /// The repo's venv Python (the dev tooling's, with soundfile), or nil (recorded as an issue: the test needs it).
    static func python() -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let py = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            Issue.record("no \(py.path): the Python half of the test cannot run")
            return nil
        }
        return py
    }

    /// `sf.read(file, dtype="float32")` and `sf.info` in Python: [rate, frames, channels, samples...].
    static func pythonReads(_ py: URL, _ file: URL) throws -> (rate: Int, frames: Int, samples: [Float]) {
        let script = """
        import json, sys
        import soundfile as sf
        data, rate = sf.read(sys.argv[1], dtype="float32", always_2d=True)
        info = sf.info(sys.argv[1])
        print(json.dumps([rate, info.frames, data[:, 0].tolist()]))
        """
        let p = Foundation.Process()
        p.executableURL = py
        p.arguments = ["-I", "-c", script, file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let v = try PythonJSON.parse(data)
        let samples = (v[2]?.arrayValue ?? []).map { Float($0.doubleValue ?? .nan) }
        return (v[0]?.intValue ?? 0, v[1]?.intValue ?? 0, samples)
    }

    /// The first two packets of an Ogg file (OpusHead, OpusTags), read with a page parser of its own.
    static func headers(_ url: URL) throws -> (head: [UInt8], tags: [UInt8]) {
        let d = [UInt8](try Data(contentsOf: url))
        var packets: [[UInt8]] = [], current: [UInt8] = []
        var i = 0
        while i + 27 <= d.count && packets.count < 2 {
            let n = Int(d[i + 26])
            let lacing = Array(d[(i + 27)..<(i + 27 + n)])
            var at = i + 27 + n
            for l in lacing {
                current += d[at..<(at + Int(l))]
                at += Int(l)
                if l < 255 { packets.append(current); current = [] }
            }
            i = at
        }
        return (packets[0], packets[1])
    }

    /// Python's exports with audio (golden `exchange_zip_audio`) import here as there: the system track Python's
    /// import wrote, to 2 LSB (Opus decoded by another decoder build), and the FLAC one likewise.
    @Test func test_old_exports_import() throws {
        let golden = Goldens.load("exchange_zip_audio")
        for name in ["exchange-python-audio", "exchange-python-audio-flac"] {
            let r = Import.Root(); defer { r.remove() }
            let done = try Exchange.importPackage(r.mine, Goldens.url("\(name).zip"), userName: "Valerie", stores: r.stores)
            let wav = RecordingPaths(r.mine.appendingPathComponent(done.id)).systemWav
            let info = try Wav16.info(wav)
            let python = try #require(golden["imported"]?["\(name).zip"])
            #expect(info.rate == python["rate"]?.intValue && info.frames == python["frames"]?.intValue, "\(name)")
            let theirs = try Wav16.read(Goldens.url("\(name)-system.wav")), mine = try Wav16.read(wav)
            #expect(mine.count == theirs.count && Self.maxDifference(mine, theirs) <= 2, "\(name)")
            #expect(!Import.exists(r.here(done.id).micWav))
        }
    }

    // MARK: - Ogg Opus and FLAC

    /// Every length comes back exact, at each Opus rate, in one and two channels; nothing comes back as nothing.
    @Test func opusKeepsTheLengthAtEveryRate() throws {
        let t = TempFolder("audio"); defer { t.remove() }
        for (rate, channels, frames) in [(8000, 1, 0), (8000, 1, 1), (12_000, 1, 239), (16_000, 2, 320), (24_000, 1, 24_001),
                                          (48_000, 1, 96_000 + 77)] {
            let wav = t.url.appendingPathComponent("x.wav"), opus = t.url.appendingPathComponent("x.opus")
            let samples = (0..<(frames * channels)).map { Int16(truncatingIfNeeded: ($0 * 977) % 20000 - 10000) }
            try Wav16.write(samples, rate: rate, channels: channels, to: wav)
            try OggOpus.encode(wav: wav, to: opus)
            let reader = try OggOpus.Reader(opus)
            #expect(reader.rate == rate && reader.channels == channels && reader.frames == frames, "\(rate) \(frames): \(reader.frames)")
            reader.close()
            let decoded = try OggOpus.decode(opus)
            #expect(decoded.samples.count == frames * channels, "\(rate) \(frames)")
        }
    }

    @Test func flacKeepsEverySample() throws {
        let t = TempFolder("audio"); defer { t.remove() }
        for (rate, channels) in [(44_100, 1), (11_025, 2), (32_000, 1)] {
            let samples = (0..<(rate / 2 * channels)).map { Int16(truncatingIfNeeded: ($0 * 7919) % 65536 - 32768) }
            let wav = t.url.appendingPathComponent("x.wav")
            try Wav16.write(samples, rate: rate, channels: channels, to: wav)
            let flac = try ExchangeAudio.encodeTrack(wav, destDir: t.url, track: "system")
            #expect(flac.lastPathComponent == "system.flac")
            let decoded = try Flac.decode(flac)
            #expect(decoded.rate == rate && decoded.samples == samples.map { Float($0) / 32768 }, "\(rate)")
        }
        // Too short for AudioToolbox's encoder: refused, not written empty.
        let wav = t.url.appendingPathComponent("short.wav")
        try Wav16.write([Int16](repeating: 100, count: 4000), rate: 11_025, to: wav)
        #expect(throws: AudioError.self) { try ExchangeAudio.encodeTrack(wav, destDir: t.url, track: "mic") }
    }

    /// Damaged Ogg Opus (cut short anywhere, bytes changed anywhere) and anything else throws or reads, never traps.
    @Test func damagedAudioThrowsAndNeverTraps() throws {
        let t = TempFolder("audio"); defer { t.remove() }
        let wav = t.url.appendingPathComponent("x.wav"), opus = t.url.appendingPathComponent("x.opus")
        try Wav16.write(Self.tone(8000, seconds: 1, hz: 300, amplitude: 0.5), rate: 8000, to: wav)
        try OggOpus.encode(wav: wav, to: opus)
        let good = [UInt8](try Data(contentsOf: opus))
        let file = t.url.appendingPathComponent("bad.opus")
        func attempt(_ bytes: [UInt8]) {
            try? Data(bytes).write(to: file)
            if let source = try? ExchangeAudio.open(file) {
                var total = 0
                while let block = try? source.read(maxFrames: 4000), !block.isEmpty, total < 1 << 22 { total += block.count }
                source.close()
            }
        }
        var rng = SystemRandomNumberGenerator()
        for cut in stride(from: 0, to: good.count, by: 13) { attempt(Array(good.prefix(cut))) }
        for _ in 0..<300 {
            var bytes = good
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            attempt(bytes)
        }
        for junk in [[UInt8](), Array("fLaC".utf8) + [UInt8](repeating: 0xFF, count: 200), Array("RIFF".utf8),
                     Array("OggS".utf8) + [UInt8](repeating: 0, count: 100)] {
            attempt(junk)
        }
        #expect(throws: AudioError.self) { try OggOpus.Reader(t.url.appendingPathComponent("missing.opus")) }
    }

    @Test func aResampledStreamKeepsItsLength() throws {
        let stream = try ExchangeAudio.Resampler(from: 48_000, to: 16_000)
        var total = 0
        for _ in 0..<5 { total += try stream.process([Float](repeating: 0.1, count: 19_200), last: false).count }
        total += try stream.process([], last: true).count
        #expect(abs(total - 16_000 * 2) <= 2, "\(total)")
    }
}

private extension JSONValue {
    var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }
    subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}
