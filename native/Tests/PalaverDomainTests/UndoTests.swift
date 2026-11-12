// Undo snapshots: take, seal, restore, prune; the fingerprints; and manifests that are broken or of another shape
// (on the snapshots of an earlier release, Goldens/python-undo).
import CryptoKit
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct UndoTests {
    private static let SR = 16_000
    private static let ID = "2026-10-20T14-35-17"

    /// test_undo.py's `_recording`: a second of silence on each track, and the JSON files a processed meeting has.
    @discardableResult
    private func recording(_ root: URL, _ id: String = ID) throws -> RecordingPaths {
        let paths = RecordingPaths(root.appendingPathComponent(id, isDirectory: true))
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let tone = [Int16](repeating: 0, count: Self.SR)
        for track in [paths.micRawWav, paths.micWav, paths.systemWav] { try Wav16.write(tone, rate: Self.SR, to: track) }
        write(paths.meta, #"{"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 1}"#)
        write(paths.systemTurns, #"[{"speaker": "SPEAKER_00", "start": 0, "end": 1}]"#)
        write(paths.systemSegments, "[]")
        write(paths.micSegments, "[]")
        write(paths.transcriptJson, "[]")
        write(paths.speakers, #"{"SPEAKER_00": "Anna"}"#)
        return paths
    }

    private func write(_ url: URL, _ text: String) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    }
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func json(_ url: URL) -> JSONValue? { PythonJSON.read(url) }
    private func equal(_ v: JSONValue?, _ literal: String) -> Bool {
        guard let v, let want = try? PythonJSON.parse(Data(literal.utf8)) else { return false }
        return PythonJSON.equal(v, want)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
    private func snap(_ root: URL, _ token: String) -> URL { root.appendingPathComponent(".trash/.undo/\(token)", isDirectory: true) }
    private func manifest(_ root: URL, _ token: String) -> URL { snap(root, token).appendingPathComponent("manifest.json") }
    /// Every file below `url` (relative paths, names as stored), symlinked folders not entered.
    private func files(_ url: URL) -> [String] {
        func walk(_ dir: String, _ rel: String) -> [String] {
            ((try? Undo.listdir(dir)) ?? []).flatMap { name -> [String] in
                let path = dir + "/" + name, r = rel.isEmpty ? name : rel + "/" + name
                var l = stat()
                guard lstat(path, &l) == 0 else { return [] }
                return l.st_mode & S_IFMT == S_IFDIR ? walk(path, r) : [r]
            }
        }
        return Py.stableSorted(walk(url.path, ""), by: Py.less)
    }

    /// A file written with Darwin's `open`, its name stored as given (Foundation stores names decomposed).
    private func posixWrite(_ path: String, _ data: Data) throws {
        try Undo.makedirs(Undo.dirname(path))
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw POSIXError(.EIO) }
    }
    private func wavs(_ url: URL) -> [String] { files(url).filter { $0.hasSuffix(".wav") } }

    /// test_undo.py's `_later`: the file's mtime `seconds` later.
    private func later(_ url: URL, _ seconds: Double = 5) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let t = (attrs[.modificationDate] as! Date).addingTimeInterval(seconds)
        try FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path)
    }

    private func gone(_ body: () throws -> Void) -> Bool {
        do { try body() } catch is UndoGone { return true } catch { return false }
        return false
    }
    private func changed(_ body: () throws -> Void) -> Bool {
        do { try body() } catch is UndoChanged { return true } catch { return false }
        return false
    }

    // MARK: - test_undo.py

    @Test func test_take_and_restore_metadata_only() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        #expect(wavs(snap(temp.url, token)).isEmpty)
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        #expect(try Undo.restore(temp.url, token) == [Self.ID])
        #expect(equal(json(paths.speakers), #"{"SPEAKER_00": "Anna"}"#))
        #expect(exists(paths.systemWav))  // the audio was never copied, and is still there
        #expect(!exists(snap(temp.url, token)))
    }

    @Test func test_metadata_only_restore_moves_the_audio_instead_of_copying_it() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        try Wav16.write((0..<Self.SR).map { Int16(truncatingIfNeeded: $0) }, rate: Self.SR, to: paths.systemWav)  // bytes to recognise
        let audio = try [paths.micRawWav, paths.micWav, paths.systemWav].map { try Data(contentsOf: $0) }
        let token = try Undo.take(temp.url, "event", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        try Undo.restore(temp.url, token)
        #expect(equal(json(paths.speakers), #"{"SPEAKER_00": "Anna"}"#))
        #expect(try [paths.micRawWav, paths.micWav, paths.systemWav].map { try Data(contentsOf: $0) } == audio)
        let replaced = temp.url.appendingPathComponent(".trash/\(Self.ID).undone-\(token.prefix(8))")
        #expect(isDir(replaced) && exists(replaced.appendingPathComponent("speakers.json")))
        #expect(wavs(replaced).isEmpty)  // no second copy of the audio in the trash
    }

    @Test func test_restore_moves_back_a_trashed_meeting() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "delete", meetings: [Self.ID])
        let dst = try Cutting.trash(paths)
        try Undo.moved(temp.url, token, src: paths.folder, dst: dst)
        try Undo.restore(temp.url, token)
        #expect(isDir(paths.folder) && exists(paths.systemWav) && exists(paths.speakers))
        #expect(!exists(temp.url.appendingPathComponent(".trash/\(Self.ID)")))
    }

    @Test func test_restore_trashes_created_meetings() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        try recording(temp.url, "2026-10-20T15-00-00")
        let token = try Undo.take(temp.url, "split", meetings: [Self.ID])
        try Undo.created(temp.url, token, ["2026-10-20T15-00-00"])
        try Undo.restore(temp.url, token)
        #expect(!exists(temp.url.appendingPathComponent("2026-10-20T15-00-00")))
        #expect(isDir(temp.url.appendingPathComponent(".trash/2026-10-20T15-00-00")))
    }

    @Test func test_restore_puts_back_store_files() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let store = temp.url.appendingPathComponent("projects.json")
        write(store, #"{"a": 1}"#)
        let token = try Undo.take(temp.url, "projects", stores: [store])
        write(store, #"{"a": 2}"#)
        try Undo.restore(temp.url, token)
        #expect(text(store) == #"{"a": 1}"#)
    }

    @Test func test_restore_removes_a_store_file_that_did_not_exist() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let store = temp.url.appendingPathComponent("projects.json")
        let token = try Undo.take(temp.url, "projects", stores: [store])
        write(store, "{}")
        try Undo.restore(temp.url, token)
        #expect(!exists(store))
    }

    @Test func test_speaker_files_of_all_meetings_only() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let a = try recording(temp.url), b = try recording(temp.url, "2026-10-20T15-00-00")
        let token = try Undo.take(temp.url, "voices", speakerFilesOfAll: true)
        #expect(files(snap(temp.url, token).appendingPathComponent("meetings")).map { ($0 as NSString).lastPathComponent }
                == ["speakers.json", "speakers.json"])
        write(a.speakers, "{}")
        try FileManager.default.removeItem(at: b.speakers)
        try Undo.sealed(temp.url, token)
        try Undo.restore(temp.url, token)
        #expect(equal(json(a.speakers), #"{"SPEAKER_00": "Anna"}"#) && exists(b.speakers))
        #expect(exists(a.transcriptJson))
    }

    @Test func test_restore_unknown_token_raises_not_found() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        #expect(gone { try Undo.restore(temp.url, String(repeating: "0", count: 32)) })
        #expect(gone { try Undo.restore(temp.url, "../../x") })
    }

    @Test func test_restore_refused_when_meeting_changed_since() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, "{}")
        try later(paths.speakers)
        #expect(changed { try Undo.restore(temp.url, token) })
        #expect(text(paths.speakers) == "{}")
        #expect(exists(snap(temp.url, token)))
    }

    @Test func test_the_my_notes_lock_is_no_change_to_a_meeting() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        write(paths.folder.appendingPathComponent(".my-notes.lock"), "")
        #expect(try Undo.restore(temp.url, token) == [Self.ID])
    }

    /// Python makes the temporary file vanish while the folder is copied (a monkeypatched `copytree`); Swift never
    /// copies it at all, so it may vanish any time: before `sealed` here.
    @Test func test_a_write_in_progress_is_no_part_of_a_snapshot() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let tmp = paths.folder.appendingPathComponent(".my-notes.json.123.tmp")
        write(tmp, "[]")
        let token = try Undo.take(temp.url, "event", meetings: [Self.ID])
        #expect(!exists(snap(temp.url, token).appendingPathComponent("meetings/\(Self.ID)/.my-notes.json.123.tmp")))
        try FileManager.default.removeItem(at: tmp)  // the save finished
        try Undo.sealed(temp.url, token)
        #expect(try Undo.restore(temp.url, token) == [Self.ID])
    }

    @Test func test_restore_refused_when_meeting_changed_after_the_change() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, "{}")
        try Undo.sealed(temp.url, token)
        write(paths.notes, "{}")
        try later(paths.notes)
        #expect(changed { try Undo.restore(temp.url, token) })
    }

    @Test func test_older_undo_works_after_a_later_change_was_undone() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let first = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, first)
        let second = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Carl"}"#)
        try Undo.sealed(temp.url, second)
        try Undo.restore(temp.url, second)  // files rewritten with the same content: newer mtimes, no change
        for f in try FileManager.default.contentsOfDirectory(at: paths.folder, includingPropertiesForKeys: nil) { try later(f) }
        #expect(try Undo.restore(temp.url, first) == [Self.ID])
        #expect(equal(json(paths.speakers), #"{"SPEAKER_00": "Anna"}"#))
    }

    @Test func test_restore_refused_after_a_later_edit_of_the_same_size() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        write(paths.speakers, #"{"SPEAKER_00": "Rob"}"#)  // same size, other content, same mtime
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: paths.speakers.path)
        #expect(changed { try Undo.restore(temp.url, token) })
    }

    @Test func test_partial_snapshot_checks_only_the_speaker_files() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let other = try recording(temp.url, "2026-10-20T15-00-00")
        var token = try Undo.take(temp.url, "voices", meetings: [Self.ID], speakerFilesOfAll: true)
        try Undo.sealed(temp.url, token)
        write(other.notes, "{}")  // not a speaker file: no reason to refuse
        #expect(try Undo.restore(temp.url, token).contains("2026-10-20T15-00-00"))
        token = try Undo.take(temp.url, "voices", meetings: [Self.ID], speakerFilesOfAll: true)
        try Undo.sealed(temp.url, token)
        write(other.speakers, #"{"SPEAKER_00": "Zoe"}"#)
        #expect(changed { try Undo.restore(temp.url, token) })
    }

    @Test func test_snapshot_from_before_fingerprints_still_checks_mtimes() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        try Undo.sealed(temp.url, token)
        var data = try #require(PyDict<JSONValue>(json(manifest(temp.url, token)) ?? .null))
        var meetings = try #require(PyDict<JSONValue>(data["meetings"] ?? .null))
        meetings[Self.ID] = .object([("partial", .bool(false)), ("audio", .bool(false)), ("mtime", .double(0))])
        data["meetings"] = meetings.json
        write(manifest(temp.url, token), PythonJSON.dumps(data.json))
        #expect(changed { try Undo.restore(temp.url, token) })
    }

    @Test func test_trash_twice_does_not_nest() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent(".trash/\(Self.ID)"), withIntermediateDirectories: true)
        let target = try Cutting.trash(paths)
        #expect(target.path == temp.url.appendingPathComponent(".trash/\(Self.ID)-2").path)
        #expect(!exists(temp.url.appendingPathComponent(".trash/\(Self.ID)/\(Self.ID)")))
    }

    /// test_undo.py's `_set_time`.
    private func setTime(_ root: URL, _ token: String, _ when: Date) throws {
        var data = try #require(PyDict<JSONValue>(json(manifest(root, token)) ?? .null))
        data["time"] = .string(Py.isoNow(now: when))
        write(manifest(root, token), PythonJSON.dumps(data.json))
    }

    @Test func test_prune_keeps_newest_20_and_drops_old() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let now = Date()
        let tokens = try (0..<22).map { try Undo.take(temp.url, "n\($0)") }
        for (i, token) in tokens.enumerated() { try setTime(temp.url, token, now.addingTimeInterval(-Double(30 - i) * 60)) }
        let old = try Undo.take(temp.url, "old")
        try setTime(temp.url, old, now.addingTimeInterval(-25 * 3600))
        Undo.prune(temp.url)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: temp.url.appendingPathComponent(".trash/.undo").path))
        #expect(left.count == 20 && !left.contains(old))
        #expect(left == Set(tokens[2...]))
    }

    @Test func test_prune_leaves_a_snapshot_still_being_taken() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let fresh = temp.url.appendingPathComponent(".trash/.undo/" + String(repeating: "a", count: 32))
        try FileManager.default.createDirectory(at: fresh.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        let stale = temp.url.appendingPathComponent(".trash/.undo/" + String(repeating: "b", count: 32))
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: stale.path)
        Undo.prune(temp.url)
        #expect(exists(fresh) && !exists(stale))
    }

    @Test func test_restore_moves_replaced_files_to_the_trash() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let store = temp.url.appendingPathComponent("projects", isDirectory: true)
        write(store.appendingPathComponent("a.json"), "1")
        let token = try Undo.take(temp.url, "x", speakerFilesOfAll: true, stores: [store])
        write(paths.speakers, #"{"edited": 1}"#)
        write(store.appendingPathComponent("a.json"), "2")
        try Undo.sealed(temp.url, token)
        try Undo.restore(temp.url, token)
        let aside = temp.url.appendingPathComponent(".trash/undone-\(token.prefix(8))")
        #expect(equal(json(aside.appendingPathComponent("\(Self.ID)/speakers.json")), #"{"edited": 1}"#))
        #expect(text(aside.appendingPathComponent("stores/0/projects/a.json")) == "2")
        #expect(text(store.appendingPathComponent("a.json")) == "1")
    }

    @Test func test_restore_refused_when_a_store_changed_after_the_change() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let store = temp.url.appendingPathComponent("projects.json")
        write(store, #"{"assign": {"A": "x"}}"#)
        let token = try Undo.take(temp.url, "trash", stores: [store])
        write(store, #"{"assign": {}}"#)  // the change
        try Undo.sealed(temp.url, token)
        write(store, #"{"assign": {"B": "y"}}"#)  // an unrelated later edit
        #expect(changed { try Undo.restore(temp.url, token) })
        #expect(equal(json(store), #"{"assign": {"B": "y"}}"#))  // nothing lost
        #expect(exists(snap(temp.url, token)))
    }

    @Test func test_restore_refused_when_a_store_folder_changed_after_the_change() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let voices = temp.url.appendingPathComponent("voices", isDirectory: true)
        write(voices.appendingPathComponent("anna.json"), "1")
        let token = try Undo.take(temp.url, "merge", stores: [voices])
        write(voices.appendingPathComponent("anna.json"), "2")
        try Undo.sealed(temp.url, token)
        write(voices.appendingPathComponent("bob.json"), "3")
        #expect(changed { try Undo.restore(temp.url, token) })
    }

    @Test func test_restore_refused_when_a_made_folder_changed_after_the_change() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let token = try Undo.take(temp.url, "split", meetings: [Self.ID])
        let tail = try recording(temp.url, "2026-10-20T15-00-00")  // the change made it
        try Undo.created(temp.url, token, [tail.id])
        try Undo.sealed(temp.url, token)
        write(tail.speakers, #"{"SPEAKER_00": "Zoe"}"#)  // named afterwards
        #expect(changed { try Undo.restore(temp.url, token) })
        #expect(isDir(tail.folder))
    }

    @Test func test_a_made_folder_trashed_since_is_no_reason_to_refuse() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let token = try Undo.take(temp.url, "split", meetings: [Self.ID])
        let tail = try recording(temp.url, "2026-10-20T15-00-00")
        try Undo.created(temp.url, token, [tail.id])
        try Undo.sealed(temp.url, token)
        try Cutting.trash(tail)
        #expect(try Undo.restore(temp.url, token) == [Self.ID])
    }

    @Test func test_undoing_store_changes_in_order_still_works() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let store = temp.url.appendingPathComponent("projects.json")
        write(store, #"{"v": 1}"#)
        let first = try Undo.take(temp.url, "a", stores: [store])
        write(store, #"{"v": 2}"#)
        try Undo.sealed(temp.url, first)
        let second = try Undo.take(temp.url, "b", stores: [store])
        write(store, #"{"v": 3}"#)
        try Undo.sealed(temp.url, second)
        #expect(changed { try Undo.restore(temp.url, first) })  // out of order: the second change would be lost
        try Undo.restore(temp.url, second)
        try later(store)  // the same content written again
        try Undo.restore(temp.url, first)
        #expect(text(store) == #"{"v": 1}"#)
    }

    @Test func test_restore_refused_when_the_meeting_went_to_the_trash_since() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "event", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        try Cutting.trash(paths)
        #expect(changed { try Undo.restore(temp.url, token) })
        #expect(!exists(paths.folder))  // no audio-less second copy
        #expect(try Undo.restore(temp.url, token, check: false) == [Self.ID])  // a rollback still puts it back
    }

    @Test func test_a_meeting_the_change_itself_removed_is_put_back() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let other = try recording(temp.url, "2026-10-20T15-00-00")
        let token = try Undo.take(temp.url, "split", meetings: [Self.ID, other.id], audio: true)
        try Cutting.trash(other)  // e.g. joined into the tail
        try Undo.sealed(temp.url, token)
        #expect(try Undo.restore(temp.url, token).sorted() == [Self.ID, other.id].sorted())
        #expect(exists(other.systemWav))
    }

    @Test func test_restore_of_an_audio_snapshot_drops_the_undone_audio() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "cut", meetings: [Self.ID], audio: true)
        try Wav16.write([Int16](repeating: 0, count: Self.SR / 2), rate: Self.SR, to: paths.systemWav)  // the cut
        write(paths.transcriptJson, #"[{"cut": 1}]"#)
        try Undo.sealed(temp.url, token)
        try Undo.restore(temp.url, token)
        #expect(try Wav16.info(paths.systemWav).frames == Self.SR)
        let replaced = temp.url.appendingPathComponent(".trash/\(Self.ID).undone-\(token.prefix(8))")
        #expect(equal(json(replaced.appendingPathComponent("transcript.json")), #"[{"cut": 1}]"#))  // the undone state stays
        #expect(wavs(replaced).isEmpty)  // without its audio
    }

    // MARK: - The snapshots Python took

    private static let PLACEHOLDER = "/PALAVER-UNDO-ROOT"

    /// Goldens/python-undo/root copied into `temp` (as `temp/root`), the manifests' placeholder made `temp`.
    private func pythonRoot(_ temp: TempFolder) throws -> URL {
        let root = temp.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.copyItem(at: Goldens.url("python-undo/root"), to: root)
        let undo = root.appendingPathComponent("Meetings/.trash/.undo")
        for token in try FileManager.default.contentsOfDirectory(atPath: undo.path) {
            let m = undo.appendingPathComponent("\(token)/manifest.json")
            write(m, try #require(text(m)).replacingOccurrences(of: Self.PLACEHOLDER, with: temp.url.path))
        }
        return root
    }

    /// The files below `url` and their bytes; lock files (each side makes its own) and empty folders (git keeps none)
    /// left out.
    /// Paths compared by code points (a String key would take NFC and NFD for one).
    private func tree(_ url: URL) throws -> [ScalarKey: (String, Data)] {
        var out: [ScalarKey: (String, Data)] = [:]
        for rel in files(url) where !rel.hasSuffix(".lock") && !rel.hasSuffix(".DS_Store") {
            out[ScalarKey(rel)] = (rel, try Data(contentsOf: URL(fileURLWithPath: url.path + "/" + rel)))
        }
        return out
    }

    @Test func test_an_unreadable_manifest_is_gone() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let root = try pythonRoot(temp), out = root.appendingPathComponent("Meetings", isDirectory: true)
        let tokens = try Goldens.cases("undo_fixture", "snapshots").compactMap { $0[0].stringValue }
        let broken = [Data("{\"label\": \"rename\", \"meetings\": {".utf8), Data(), Data([0xFF, 0xFE, 0x7B, 0x7D]), Data("[]".utf8),
                      Data("null".utf8)]
        for (token, bytes) in zip(tokens, broken) {
            try bytes.write(to: manifest(out, token))
            #expect(gone { try Undo.restore(out, token) })
            #expect(gone { _ = try Undo.label(out, token) })
            #expect(gone { _ = try Undo.extra(out, token) })
            #expect(gone { try Undo.sealed(out, token) })
            #expect(exists(snap(out, token)))  // nothing was put back, nothing removed
        }
        try FileManager.default.removeItem(at: manifest(out, tokens[0]))
        #expect(gone { try Undo.restore(out, tokens[0]) })
        #expect(exists(root.appendingPathComponent("Meetings/.trash/2026-10-21T09-00-00")))  // the trashed meeting stays
    }

    @Test func aManifestOfAnotherShapeIsGone() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let shapes = [#"{"meetings": [], "stores": [], "moves": [], "created": []}"#,
                      #"{"meetings": {"2026-10-20T14-35-17": {"audio": false}}, "stores": [], "moves": [], "created": []}"#,
                      #"{"meetings": {"2026-10-20T14-35-17": {"partial": false, "audio": false}}, "stores": [], "moves": [], "created": []}"#,
                      #"{"meetings": {}, "stores": [{"path": 1, "index": 0, "existed": true, "dir": false}], "moves": [], "created": []}"#,
                      #"{"meetings": {}, "stores": [], "moves": [["a"]], "created": []}"#,
                      #"{"meetings": {}, "stores": [], "moves": [], "created": [1]}"#,
                      #"{"meetings": {}, "stores": [], "moves": [], "created": [], "created_fingerprints": null}"#,
                      #"{"meetings": {}, "stores": [], "moves": []}"#]
        for shape in shapes {
            let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
            write(manifest(temp.url, token), shape)
            #expect(gone { try Undo.restore(temp.url, token) }, "\(shape)")
            #expect(exists(temp.url.appendingPathComponent(Self.ID)))
        }
    }

    // MARK: - Swift's own: locks, derived files, odd times

    @Test func aRestoreOfSpeakerFilesWaitsForTheMeetingsLock() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "voices", speakerFilesOfAll: true)
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        let holder = try LockHolder(paths.folder.appendingPathComponent(".speakers.lock"), seconds: 1.0)
        let started = Date()
        try Undo.restore(temp.url, token)
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
        #expect(equal(json(paths.speakers), #"{"SPEAKER_00": "Anna"}"#))
    }

    @Test func aRestoreOfAMeetingWaitsForItsLock() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        write(paths.speakers, #"{"SPEAKER_00": "Bob"}"#)
        try Undo.sealed(temp.url, token)
        let holder = try LockHolder(paths.folder.appendingPathComponent(".speakers.lock"), seconds: 1.0)
        let started = Date()
        try Undo.restore(temp.url, token)
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
    }

    @Test func aRestoreOfAStoreWaitsForTheStoresLock() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let store = temp.url.appendingPathComponent("config/palaver/projects.json")
        write(store, #"{"v": 1}"#)
        let token = try Undo.take(temp.url, "project", stores: [store])
        write(store, #"{"v": 2}"#)
        try Undo.sealed(temp.url, token)
        let holder = try LockHolder(store.deletingLastPathComponent().appendingPathComponent("projects.json.lock"), seconds: 1.0)
        let started = Date()
        try Undo.restore(temp.url, token)
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
        #expect(text(store) == #"{"v": 1}"#)
    }

    @Test func aRestoreOfMyNotesImagesWaitsForTheNotesLockAndMakesNoFolderOfAGoneMeeting() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let image = paths.folder.appendingPathComponent("my-notes/img-0123456789ab.png")
        write(image, "png")
        let token = try Undo.take(temp.url, "my-notes clear", stores: [image])
        try FileManager.default.removeItem(at: image)
        try Undo.sealed(temp.url, token)
        let holder = try LockHolder(paths.folder.appendingPathComponent(".my-notes.lock"), seconds: 1.0)
        let started = Date()
        try Undo.restore(temp.url, token)
        #expect(Date().timeIntervalSince(started) >= 0.7)
        #expect(holder.wait() == 0)
        #expect(text(image) == "png")
        #expect(!exists(image.deletingLastPathComponent().appendingPathComponent("img-0123456789ab.png.lock")))  // the notes' lock, not one of its own
        // A speaker file of a meeting gone meanwhile: Python puts it back into a new folder; the lock adds nothing.
        let unknown = paths.folder.appendingPathComponent("speakers_unknown.json")
        write(unknown, "[]")
        let second = try Undo.take(temp.url, "unknown", stores: [unknown])
        try Cutting.trash(paths)
        try Undo.restore(temp.url, second, check: false)
        #expect(files(paths.folder) == ["speakers_unknown.json"])
    }

    @Test func theSpeakersLockAndDerivedFilesAreNoChangeToAMeeting() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let paths = try recording(temp.url)
        let before = try Undo.fingerprint(paths.folder, partial: false)
        for name in [".speakers.lock", ".my-notes.lock", "search-index.v2", "notes.json.tmp", "sub/.speakers.lock"] {
            write(paths.folder.appendingPathComponent(name), "x")
        }
        #expect(try Undo.fingerprint(paths.folder, partial: false) == before)
        write(paths.folder.appendingPathComponent("other.lock"), "x")  // a lock of no writer of ours is a file like any
        #expect(try Undo.fingerprint(paths.folder, partial: false) != before)
        let token = try Undo.take(temp.url, "rename", meetings: [Self.ID])
        #expect(files(snap(temp.url, token)).filter { $0.contains("speakers.lock") || $0.contains("search-index") }.isEmpty)
    }

    @Test func pruneTakesATimeWithoutAnOffsetAsUnreadable() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let naive = try Undo.take(temp.url, "naive"), fine = try Undo.take(temp.url, "fine")
        var data = try #require(PyDict<JSONValue>(json(manifest(temp.url, naive)) ?? .null))
        data["time"] = .string("2026-11-04T10:00:00")
        write(manifest(temp.url, naive), PythonJSON.dumps(data.json))
        Undo.prune(temp.url)
        #expect(exists(snap(temp.url, naive)))  // still young: maybe a take in progress
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: snap(temp.url, naive).path)
        Undo.prune(temp.url)
        #expect(!exists(snap(temp.url, naive)) && exists(snap(temp.url, fine)))
        Undo.prune(temp.url, keep: 0)
        #expect(!exists(snap(temp.url, fine)))
    }

    @Test func pruneWithAnInfiniteOrNaNMaxAgeKeepsEverythingAndDoesNotTrap() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        let a = try Undo.take(temp.url, "a"), b = try Undo.take(temp.url, "b")
        // Python's `now - when > max_age` is False for infinity and for NaN: nothing is too old.
        Undo.prune(temp.url, maxAge: .infinity)
        Undo.prune(temp.url, maxAge: .nan)
        #expect(exists(snap(temp.url, a)) && exists(snap(temp.url, b)))
        Undo.prune(temp.url, maxAge: -.infinity)  // everything is older than that
        #expect(!exists(snap(temp.url, a)) && !exists(snap(temp.url, b)))
    }

    @Test func notesExtraAndTheCreatedIdsAreKept() throws {
        let temp = TempFolder("undo"); defer { temp.remove() }
        try recording(temp.url)
        let token = try Undo.take(temp.url, "split", meetings: [Self.ID], stores: [temp.url.appendingPathComponent("a//b/./projects.json")])
        #expect(try Undo.extra(temp.url, token).isEmpty)
        try Undo.note(temp.url, token, PyDict([("folder", .string("x")), ("paragraphs", .array([]))]))
        try Undo.created(temp.url, token, ["2026-10-20T15-00-00"])
        try Undo.created(temp.url, token, ["2026-10-20T16-00-00"])
        #expect(try Undo.extra(temp.url, token).keys == ["folder", "paragraphs"])
        #expect(try Undo.createdIds(temp.url, token) == ["2026-10-20T15-00-00", "2026-10-20T16-00-00"])
        #expect(try Undo.stores(temp.url, token).map(\.path) == [temp.url.path + "/a/b/projects.json"])
        #expect(try Undo.label(temp.url, token) == "split")
        try Undo.sealed(temp.url, token)
        let keys = try #require(PyDict<JSONValue>(json(manifest(temp.url, token)) ?? .null)).keys
        #expect(keys == ["label", "time", "meetings", "stores", "moves", "created", "extra", "created_fingerprints"])
    }
}
