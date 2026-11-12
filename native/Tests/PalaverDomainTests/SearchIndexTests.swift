// Search by meaning (semantic.py): tests/test_semantic.py's tests by name (an index per meeting, built in the
// background, and a searcher that loads its model on demand and lets it go when idle), plus numpy's numbers to the bit
// (goldens section `search_index`: float16 rounding, `np.save` bytes, files numpy writes, `matrix @ vector`, argsort,
// the floor), a write cut off before its `.sig`, a live recording, and broken `.npy` files that throw, never trap.
import Darwin
import Foundation
import PalaverCore
@testable import PalaverDomain
import Testing

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Stands in for multilingual-e5-small (test_semantic.py's FakeEncoder): one dimension per concept, the rest hashed,
/// so texts about the same thing point the same way. `before` runs ahead of `passages` (a test's hook).
private final class FakeEncoder: MeaningEncoder {
    /// Words of one meaning share a dimension: "pricing" finds "Kosten".
    static let concepts = [["pricing", "price", "kosten", "angebot", "cost", "offer"], ["test", "testphase", "pilot"]]
    let dimension = 64
    let before: (([String]) throws -> Void)?

    init(_ loads: Box<Int>? = nil, before: (([String]) throws -> Void)? = nil) {
        loads?.value += 1
        self.before = before
    }

    private func vec(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        var word = ""
        for u in Py.casefold(text).unicodeScalars + [" "] {
            if Py.isWordScalar(u) { word.unicodeScalars.append(u); continue }
            if let hit = Self.concepts.firstIndex(where: { $0.contains { Py.same($0, word) } }), !word.isEmpty { v[hit] += 3 }
            word = ""
        }
        v[2 + text.unicodeScalars.count % 60] += 0.1  // something, so nothing is all zeros
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    func query(_ text: String) throws -> [Float] { vec(text) }

    func passages(_ texts: [String]) throws -> [[Float]] {
        try before?(texts)
        return texts.map(vec)
    }
}

@Suite struct SearchIndexTests {
    static let MEETING = "2026-10-27T16-03-07"

    /// test_webapp.py's `_meeting` (its transcript and notes; no audio) plus test_semantic.py's two lines about the
    /// price.
    private func meeting(_ root: URL, _ name: String = MEETING) throws -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let lines = [
            Utterance(speaker: "Timo", start: 0, end: 1, text: "Hi Valerie, äh, welcome."),
            Utterance(speaker: "SPEAKER_00", start: 1, end: 12, text: "Welcome to the hiring debrief."),
            Utterance(speaker: "SPEAKER_01", start: 13, end: 15, text: "Thanks Valerie, the salary band is fine."),
            Utterance(speaker: "SPEAKER_00", start: 16, end: 19, text: "Die Kosten für das Angebot sind noch zu hoch für den Kunden."),
            Utterance(speaker: "SPEAKER_00", start: 19, end: 20, text: "Das müssen wir mit dem Einkauf klären, bevor wir zusagen."),
        ]
        try PythonJSON.write(.array(lines.map(\.json)), to: paths.transcriptJson, indent: nil, ensureAscii: true)
        try PythonJSON.write(.object([
            ("title", .string("Hiring debrief")), ("summary", .string("SPEAKER_00 ran the debrief.")), ("sections", .array([])),
            ("next_steps", .array([.object([("owner", .string("SPEAKER_01")), ("task", .string("Send the offer"))])])),
            ("decisions", .strings(["Make an offer"])),
        ]), to: paths.notes, indent: 2, ensureAscii: false)
        return paths
    }

    private func mtime(_ url: URL) -> Int {
        var st = stat()
        _ = stat(url.path, &st)
        return Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
    }

    private func setMtime(_ url: URL, _ ns: Int) {
        let t = timespec(tv_sec: ns / 1_000_000_000, tv_nsec: ns % 1_000_000_000)
        #expect(utimensat(AT_FDCWD, url.path, [t, t], 0) == 0)
    }

    private func names(_ list: [RecordingPaths]) -> [String] { list.map { $0.folder.lastPathComponent } }

    private func index(_ root: URL, _ factory: @escaping () -> MeaningEncoder? = { FakeEncoder() }) throws -> Int {
        try SearchIndex.indexStale(outputDir: root, encoder: factory)
    }

    private func searcher(_ factory: @escaping Searcher.Factory = { FakeEncoder() }, idle: Double = SearchIndex.IDLE_SECONDS,
                          clock: @escaping () -> Double = { 0 }, timer: Searcher.Timer? = nil, root: URL) -> Searcher {
        Searcher(outputDir: root, encoderFactory: factory, idleSeconds: idle, clock: clock, timer: timer)
    }

    // MARK: - test_semantic.py

    @Test func test_a_meeting_is_cut_into_notes_pieces_and_runs_of_one_speaker() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let chunks = try SearchIndex.chunks(try meeting(t.url))
        #expect(Array(chunks.prefix(3)).map { $0["kind"]?.stringValue } == ["summary", "decision", "step"])
        #expect(chunks.contains { PythonJSON.dumps($0) == #"{"kind": "step", "text": "Send the offer", "owner": "SPEAKER_01"}"# })
        let lines = chunks.filter { $0["kind"]?.stringValue == "line" }  // the short lines say too little
        #expect(lines.map { PythonJSON.dumps($0, ensureAscii: false) } == [
            #"{"kind": "line", "speaker": "SPEAKER_00", "start": 16.0, "text": "Die Kosten für das Angebot sind noch zu hoch für den Kunden. Das müssen wir mit dem Einkauf klären, bevor wir zusagen."}"#,
        ])
    }

    @Test func test_long_runs_are_split() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var words: [String] = []
        for j in 0..<30 { words.append("w\(letters[j % 26])\(letters[j / 26])") }
        let text = words.joined(separator: " ") + "."
        let lines: [Utterance] = (0..<10).map { (i: Int) -> Utterance in
            Utterance(speaker: "Timo", start: Double(i), end: Double(i) + 1, text: text)
        }
        try PythonJSON.write(.array(lines.map { $0.json }), to: paths.transcriptJson, indent: nil, ensureAscii: true)
        let runs = try SearchIndex.chunks(paths).filter { $0["kind"]?.stringValue == "line" }
        // two lines of 30 words, never over CHUNK_WORDS
        #expect(runs.map { $0["start"]?.doubleValue } == [0.0, 2.0, 4.0, 6.0, 8.0])
    }

    @Test func test_an_index_is_written_once_and_again_when_the_meeting_changes() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
        #expect(try index(t.url) == 1)
        #expect(SearchIndex.stale(outputDir: t.url) == [])
        #expect(try index(t.url) == 0)
        let meta = try #require(PythonJSON.read(paths.folder.appendingPathComponent(SearchIndex.INDEX_JSON)))
        #expect(meta["model"]?.stringValue == SearchIndex.model && meta["chunks"]?.arrayValue?.count == 4)
        let npy = try Data(contentsOf: paths.folder.appendingPathComponent(SearchIndex.INDEX_NPY))
        #expect(String(decoding: npy[10..<26], as: UTF8.self) == "{'descr': '<f2',")
        #expect(try Npy.read(npy).rows == 4)
        setMtime(paths.notes, mtime(paths.notes) + 1_000_000_000)  // new notes
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
    }

    @Test func test_meetings_still_recorded_or_processed_are_not_indexed() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let folder = t.url.appendingPathComponent("2026-10-28T09-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meta.json"))
        #expect(SearchIndex.stale(outputDir: t.url) == [])
    }

    @Test func test_indexing_stops_when_asked_between_meetings() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        _ = try meeting(t.url)
        let made = Box(0)
        #expect(try SearchIndex.indexStale(outputDir: t.url, encoder: { FakeEncoder(made) }, shouldStop: { true }) == 0)
        #expect(made.value == 0)  // nothing to do: no model loaded
    }

    @Test func test_the_searcher_finds_by_meaning_and_lets_the_model_go() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let clock = Box(0.0), loads = Box(0)
        let s = searcher({ FakeEncoder(loads) }, idle: 60, clock: { clock.value }, root: t.url)
        let found = try s.search("pricing", in: [paths])
        let hits = try #require(found[Self.MEETING])
        #expect(Set(hits.compactMap { $0["kind"]?.stringValue }) == ["decision", "step", "line"])  // "offer" and "Angebot" too
        let line = try #require(hits.first { $0["kind"]?.stringValue == "line" })
        #expect(line["start"]?.doubleValue == 16.0 && (line["score"]?.doubleValue ?? 0) > SearchIndex.SMALL_SCORE)
        #expect(try s.search("pricing", in: [paths], kinds: ["summary"]).isEmpty)
        #expect(try s.search("pilot", in: [paths]).isEmpty)  // nothing about a test phase
        #expect(loads.value == 1)
        clock.value = 59
        s.release()
        #expect(s.loaded)
        clock.value = 120
        s.release()
        #expect(!s.loaded)
        _ = try s.search("pricing", in: [paths])
        #expect(loads.value == 2)
    }

    /// A timer may run its release at once (Task 44): the searcher never holds its lock while it starts one.
    @Test func aTimerThatRunsAtOnceDoesNotDeadlock() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let clock = Box(0.0), delays = Box<[Double]>([])
        let s = searcher(idle: 60, clock: { clock.value }, timer: { delay, run in
            delays.value.append(delay)
            if delays.value.count == 1 { run() }
        }, root: t.url)
        #expect(!(try s.search("pricing", in: [paths])).isEmpty)
        #expect(delays.value == [60, 60] && s.loaded)  // the release ran at once and looks again a minute later
        clock.value = 61
        s.release()
        #expect(!s.loaded)
    }

    @Test func test_the_searcher_keeps_to_one_speaker() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let s = searcher(root: t.url)
        #expect(try s.search("pricing", in: [paths], kinds: ["line"]) { _, label in label == "SPEAKER_01" }.isEmpty)
        #expect(try !s.search("pricing", in: [paths], kinds: ["line"]) { _, label in label == "SPEAKER_00" }.isEmpty)
        // the output dir's meetings when none are named
        #expect(try s.search("pricing").keys == [Self.MEETING])
    }

    /// Year 3000 does not fit an Int's nanoseconds (APFS clamps it to Int.max; other file systems may not, see
    /// FileTimesTests); Python's int has no limit. No trap, and the meeting is indexed again for it.
    private func farFuture(_ url: URL) {
        let t = timespec(tv_sec: 32_503_680_000, tv_nsec: 5)
        #expect(utimensat(AT_FDCWD, url.path, [t, t], 0) == 0)
    }

    @Test func test_a_file_time_beyond_int_nanoseconds_makes_the_meeting_stale_without_trapping() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        #expect(try index(t.url) == 1)
        farFuture(paths.notes)
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
        #expect(try index(t.url) == 1)
        #expect(SearchIndex.stale(outputDir: t.url).isEmpty)  // APFS stores Int.max, which fits
    }

    @Test func test_an_index_signature_with_a_time_beyond_int_nanoseconds_is_still_used_by_the_searcher() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        farFuture(paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG))
        let s = searcher(root: t.url)
        #expect(try s.search("pricing", in: [paths])[Self.MEETING]?.isEmpty == false)
        #expect(try s.search("pricing", in: [paths])[Self.MEETING]?.isEmpty == false)
    }

    @Test func test_a_stale_index_is_not_used() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        setMtime(paths.transcriptJson, mtime(paths.transcriptJson) + 1_000_000_000)
        #expect(try searcher(root: t.url).search("pricing", in: [paths]).isEmpty)
    }

    @Test func test_without_the_model_nothing_is_loaded() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        #expect(!SearchIndex.ready(outputDir: t.url, modelFolder: { nil }))
        let s = searcher({ nil }, root: t.url)
        #expect(try s.search("pricing", in: [paths]).isEmpty)
        #expect(!s.loaded && s.cachedIndexes == 0)
    }

    /// The domain half (`ready`); `api.search_meaning`'s is the server's (Task 44).
    @Test func test_search_by_meaning_can_be_switched_off() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config/palaver", isDirectory: true),
                                home: t.url.appendingPathComponent("home", isDirectory: true))
        try FileManager.default.createDirectory(at: stores.configDir, withIntermediateDirectories: true)
        let root = t.url.appendingPathComponent("Meetings", isDirectory: true)
        _ = try meeting(root)
        _ = try index(root)
        #expect(SearchIndex.ready(outputDir: root, stores: stores, modelFolder: { t.url }))
        try SettingsFile.update([("search_meaning", .bool(false))], stores: stores)
        #expect(!SearchIndex.enabled(stores: stores))
        #expect(!SearchIndex.ready(outputDir: root, stores: stores, modelFolder: { t.url }))
    }

    @Test func test_a_hit_has_to_stand_out_from_the_rest() {
        // multilingual-e5 scores a short German word ~0.80 against most pieces: over many pieces, a hit needs MARGIN
        // above their median.
        #expect(abs(SearchIndex.floor([Float](repeating: 0.80, count: 200)) - (0.80 + SearchIndex.MARGIN)) < 1e-6)
        #expect(SearchIndex.floor([Float](repeating: 0.70, count: 200)) == SearchIndex.MIN_SCORE)  // never below it
        #expect(SearchIndex.floor([Float](repeating: 0.85, count: 10)) == SearchIndex.SMALL_SCORE)  // too few to judge
    }

    @Test func test_the_model_goes_five_minutes_after_the_last_search() throws {
        // The release timer is armed at the first search and again while the model was used since: the model and the
        // indexes go IDLE after the last.
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let clock = Box(0.0)
        let timers = Box<[(Double, () -> Void)]>([])
        let s = searcher(idle: 300, clock: { clock.value }, timer: { delay, run in timers.value.append((clock.value + delay, run)) },
                         root: t.url)
        func fire() {
            let (at, run) = timers.value.removeFirst()
            clock.value = at
            run()
        }
        _ = try s.search("pricing", in: [paths])
        clock.value = 200
        _ = try s.search("pricing", in: [paths])  // used again: no second timer
        #expect(timers.value.count == 1)
        fire()  // 300 s after the first search, 100 after the last: kept, armed again
        #expect(s.loaded && timers.value.count == 1 && timers.value[0].0 >= 500)
        fire()
        #expect(!s.loaded && timers.value.isEmpty && s.cachedIndexes == 0)
        _ = try s.search("pricing", in: [paths])
        #expect(s.loaded && timers.value.count == 1)  // armed again for the next round
    }

    @Test func test_deleted_notes_and_removed_speakers_make_the_index_stale() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        try FileManager.default.removeItem(at: paths.notes)
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
        _ = try index(t.url)
        #expect(SearchIndex.stale(outputDir: t.url) == [])
        try Data(#"["SPEAKER_00"]"#.utf8).write(to: paths.speakersIgnored)  // a speaker removed as noise
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
    }

    @Test func test_an_index_of_a_meeting_that_changed_while_it_was_built_is_not_current() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        let changing = { () -> MeaningEncoder? in
            FakeEncoder(before: { _ in  // a line edited meanwhile
                setMtime(paths.transcriptJson, mtime(paths.transcriptJson) + 1_000_000_000)
            })
        }
        #expect(try index(t.url, changing) == 1)
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])  // built again next time
    }

    @Test func test_one_bad_meeting_does_not_stop_the_rest() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try meeting(t.url, "2026-10-20T09-00-00")
        try Data(#"{"summary": 1}"#.utf8).write(to: paths.notes)  // a summary that is no text
        #expect(try index(t.url) == 1)  // the other one
        #expect(SearchIndex.stale(outputDir: t.url) == [])  // the bad one waits for its files to change
        let later = mtime(paths.notes) + 1_000_000_000
        try Data(#"{"summary": "Fixed."}"#.utf8).write(to: paths.notes)
        setMtime(paths.notes, later)
        #expect(SearchIndex.stale(outputDir: t.url) == [paths])
    }

    // MARK: - Beyond test_semantic.py

    @Test func aMeetingBeingRecordedLiveIsNeverIndexed() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        let p = Foundation.Process(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "read x", "palaver", "live", paths.folder.path]  // `palaver live <folder>`
        p.standardInput = stdin
        try p.run()
        defer { p.terminate(); p.waitUntilExit(); try? stdin.fileHandleForWriting.close() }
        try Data(String(p.processIdentifier).utf8).write(to: paths.folder.appendingPathComponent("live.pid"))
        #expect(SearchIndex.stale(outputDir: t.url) == [])
        #expect(try index(t.url) == 0)
    }

    @Test func anIndexCutOffBeforeItsSigIsNotCurrent() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let sig = try Data(contentsOf: paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG))
        setMtime(paths.notes, mtime(paths.notes) + 1_000_000_000)
        // The pieces can't be written (a folder where their temp file goes): the vectors are, the .sig is not.
        try FileManager.default.createDirectory(at: paths.folder.appendingPathComponent(SearchIndex.INDEX_JSON + ".tmp"),
                                                withIntermediateDirectories: false)
        #expect(try index(t.url) == 0)
        #expect(!SearchIndex.isCurrent(paths))
        #expect(try Data(contentsOf: paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG)) == sig)
        let mark = try #require(PythonJSON.read(paths.folder.appendingPathComponent(SearchIndex.INDEX_FAILED)))
        #expect(PythonJSON.dumps(mark) == PythonJSON.dumps(.object([("sources", SearchIndex.signature(paths))])))
        #expect(try searcher(root: t.url).search("pricing", in: [paths]).isEmpty)
        // Once it can be written, it is: the mark goes.
        try FileManager.default.removeItem(at: paths.folder.appendingPathComponent(SearchIndex.INDEX_JSON + ".tmp"))
        setMtime(paths.notes, mtime(paths.notes) + 1_000_000_000)
        #expect(try index(t.url) == 1)
        #expect(SearchIndex.isCurrent(paths) && !t.exists("\(Self.MEETING)/\(SearchIndex.INDEX_FAILED)"))
    }

    @Test func brokenNpyFilesThrowNeverTrap() throws {
        let good = Npy.float16(rows: 2, columns: 3, [Float](repeating: 0.5, count: 6))
        #expect(try Npy.read(Data(good)).values == [Float](repeating: 0.5, count: 6))
        func header(_ dict: String) -> [UInt8] {
            let text = Array((dict + "\n").utf8)
            return Npy.magic + [1, 0, UInt8(text.count & 0xff), UInt8(text.count >> 8)] + text
        }
        let broken: [[UInt8]] = [
            [], Array(good.prefix(9)), Array("NUMPY not".utf8), Npy.magic + [9, 0, 0, 0],
            Npy.magic + [1, 0, 0xff, 0xff] + Array(good.dropFirst(10)),  // header past the end
            Array(good.dropLast(1)),  // data shorter than the shape
            header("{'descr': '<f2', 'fortran_order': False, 'shape': (6,), }"),  // no matrix
            header("{'descr': '<i4', 'fortran_order': False, 'shape': (1, 1), }") + [0, 0, 0, 0],
            header("{'descr': '<f2', 'fortran_order': False, 'shape': (9223372036854775807, 9223372036854775807), }"),
            header("{'descr': '<f2', 'fortran_order': False, 'shape': (-1, 2), }"),
            header("{'descr': '<f2', 'fortran_order': Maybe, 'shape': (1, 1), }") + [0, 0],
            header("{'descr': '<f2', 'shape': (1, 1), }") + [0, 0],
            header("{'descr: '<f2', 'fortran_order': False, 'shape': (1, 1), }") + [0, 0],
        ]
        for bytes in broken {
            #expect(throws: SearchIndexError.self) { try Npy.read(Data(bytes)) }
        }
        // A file numpy wrote with more data than its shape: the rest is not read.
        #expect(try Npy.read(Data(good + [1, 2])).values.count == 6)
    }

    @Test func aBrokenIndexIsNoIndex() throws {
        let t = TempFolder("semantic"); defer { t.remove() }
        let paths = try meeting(t.url)
        _ = try index(t.url)
        let npy = paths.folder.appendingPathComponent(SearchIndex.INDEX_NPY)
        let sig = paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG)
        func bump() { setMtime(sig, mtime(sig) + 1_000_000_000) }  // read again
        try Data(Npy.float16(rows: 3, columns: 64, [Float](repeating: 0.1, count: 192))).write(to: npy)  // a piece short
        bump()
        #expect(try searcher(root: t.url).search("pricing", in: [paths]).isEmpty)
        try Data("garbage".utf8).write(to: npy)
        bump()
        #expect(try searcher(root: t.url).search("pricing", in: [paths]).isEmpty)
        // Vectors of another width: numpy's matmul error, from the search.
        try Data(Npy.float16(rows: 4, columns: 8, [Float](repeating: 0.1, count: 32))).write(to: npy)
        bump()
        #expect(throws: SearchIndexError.self) { try searcher(root: t.url).search("pricing", in: [paths]) }
    }

    // MARK: - numpy's numbers (goldens `search_index`)

    private static func floats(_ v: JSONValue?) -> [Float] {
        (v?.arrayValue ?? []).map { if case .int(let b) = $0 { return Float(bitPattern: UInt32(b)) } else { return .nan } }
    }

    private static func bits(_ xs: [Float]) -> [Int] { xs.map { Int($0.bitPattern) } }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    @Test func npyFilesNumpyWritesAreRead() throws {
        for c in try Goldens.cases("search_index", "npy_read") {
            let m = try Npy.read(hexData(c[0].stringValue ?? ""))
            #expect([m.rows, m.columns] == c[1].arrayValue?.compactMap { if case .int(let n) = $0 { return n } else { return nil } })
            #expect(Self.bits(m.values) == Self.bits(Self.floats(c[2])))
        }
    }

}
