// tests/test_storage.py: what the meetings and models take; a transcribed meeting's audio can go (#9). Every file is in
// a temporary folder: the meetings, the config dir, the home (Application Support/palaver/models) and the model cache.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private let berlin = TimeZone(identifier: "Europe/Berlin")!

/// A naive local time in Berlin, as Python's `datetime(2026, 11, 2, 12, 0)` is for the tests.
private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
}

private let NOW = local(2026, 11, 2, 12, 0)

/// The folders of one test: Recordings, a config dir, a home and a model cache.
private struct Place {
    let t = TempFolder("storage")
    var root: URL { t.url.appendingPathComponent("Recordings", isDirectory: true) }
    var stores: StorePaths {
        StorePaths(configDir: t.url.appendingPathComponent("config/palaver", isDirectory: true),
                   home: t.url.appendingPathComponent("home", isDirectory: true),
                   hubCache: t.url.appendingPathComponent("hub", isDirectory: true))
    }

    init() { try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { t.remove() }

    @discardableResult
    func meeting(_ name: String, transcribed: Bool = true, audio: Int = 1000) -> RecordingPaths {
        let p = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
        try! FileManager.default.createDirectory(at: p.folder, withIntermediateDirectories: true)
        for f in [p.micRawWav, p.micWav, p.systemWav] { bytes(f, audio) }
        if transcribed { try! "[]".write(to: p.transcriptJson, atomically: false, encoding: .utf8) }
        try! "{}".write(to: p.notes, atomically: false, encoding: .utf8)
        return p
    }

    func cacheDir(_ repo: String) -> URL { ModelCatalog.cacheDir(repo, stores: stores) }
}

private func bytes(_ url: URL, _ n: Int) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(count: n).write(to: url)
}

private func exists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

private func rows(_ place: Place, config: Config = Config()) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for row in Storage.models(config: config, stores: place.stores) { out[row["id"]!.stringValue!] = row }
    return out
}

private func keys(_ v: JSONValue) -> [String] {
    if case .object(let fields) = v { return fields.map(\.0) }
    return []
}

private func deletable(_ rows: [String: JSONValue]) -> [String] {
    rows.filter { $0.value["deletable"] == .bool(true) }.map(\.key).sorted()
}

/// Thread-safe list of what a cleanup ran.
private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var days: [Int] = []
    func add(_ d: Int) { lock.lock(); days.append(d); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return days }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite struct StorageTests {
    @Test func test_drop_audio_keeps_the_transcript_and_says_so() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        #expect(try Storage.dropAudio(p) == 3000)
        #expect(Storage.audioFiles(p).isEmpty && exists(p.transcriptJson) && exists(p.notes))
        #expect(Storage.deleted(p)?["bytes"] == .int(3000))
        #expect(!Storage.canDrop(p))
    }

    @Test func test_an_untranscribed_meeting_keeps_its_audio() {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00", transcribed: false)
        #expect(throws: StorageError.self) { try Storage.dropAudio(p) }
        #expect(Storage.audioFiles(p).count == 3)
    }

    @Test func test_a_meeting_still_being_written_keeps_its_audio() {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        bytes(URL(fileURLWithPath: p.systemWav.path + ".part"), 1)
        #expect(!Storage.canDrop(p))
    }

    @Test func test_drop_old_audio_only_older_than_the_days() throws {
        let place = Place(); defer { place.remove() }
        let old = place.meeting("2026-10-01T10-00-00")
        let new = place.meeting("2026-10-30T10-00-00")
        let pending = place.meeting("2026-09-01T10-00-00", transcribed: false)
        let dropped = try Storage.dropOldAudio(place.root, days: 14, now: NOW, timeZone: berlin)
        #expect(dropped.meetings == 1 && dropped.bytes == 3000)
        #expect(Storage.audioFiles(old).isEmpty)
        #expect(Storage.audioFiles(new).count == 3 && Storage.audioFiles(pending).count == 3)
        let kept = try Storage.dropOldAudio(place.root, days: 0, now: NOW, timeZone: berlin)  // 0: kept
        #expect(kept.meetings == 0 && kept.bytes == 0)
    }

    @Test func test_audio_days_are_saved_and_checked() throws {
        let place = Place(); defer { place.remove() }
        #expect(Storage.audioDays(stores: place.stores) == 0)
        try Storage.setAudioDays(.int(30), stores: place.stores)
        #expect(Storage.audioDays(stores: place.stores) == 30)
        for wrong: JSONValue in [.int(5), .bool(true), .string("30"), .null] {
            #expect(throws: StorageError.self) { try Storage.setAudioDays(wrong, stores: place.stores) }
        }
        do {
            try Storage.setAudioDays(.int(5), stores: place.stores)
        } catch {
            #expect("\(error)" == "audio_days must be one of 0, 7, 14, 30, 90")
        }
    }

    @Test func test_summary_counts_meetings_audio_and_what_would_go() throws {
        let place = Place(); defer { place.remove() }
        place.meeting("2026-10-01T10-00-00")
        place.meeting("2026-10-30T10-00-00", audio: 500)
        try FileManager.default.createDirectory(at: place.root.appendingPathComponent("not-a-meeting"), withIntermediateDirectories: true)
        let s = Storage.summary(outputDir: place.root, now: NOW, timeZone: berlin, stores: place.stores)
        #expect(s["meetings"] == .int(2) && s["audio_bytes"] == .int(4500) && s["audio_meetings"] == .int(2))
        #expect(s["bytes"]!.doubleValue! > s["audio_bytes"]!.doubleValue!)
        #expect(PythonJSON.dumps(s["older"]!["14"]!) == #"{"meetings": 1, "bytes": 3000}"#)
        #expect(PythonJSON.dumps(s["older"]!["90"]!) == #"{"meetings": 0, "bytes": 0}"#)
        #expect(s["models"] == .array([]))
        #expect(PythonJSON.dumps(.array(keys(s).map { .string($0) }))
                == #"["folder", "meetings", "bytes", "audio_bytes", "audio_meetings", "audio_days", "days", "older", "models"]"#)
        #expect(PythonJSON.dumps(s["days"]!) == "[0, 7, 14, 30, 90]")
        #expect(s["folder"] == .string(place.root.path.hasSuffix("/") ? String(place.root.path.dropLast()) : place.root.path))
    }

    @Test func test_only_a_notes_model_not_in_use_can_be_deleted() throws {
        let place = Place(); defer { place.remove() }
        for (repo, size) in [(ModelCatalog.model("gemma")!.repo, 9), (ModelCatalog.model("qwen")!.repo, 17),
                             (ModelCatalog.model("parakeet")!.repo, 2)] {
            bytes(place.cacheDir(repo).appendingPathComponent("blobs/b"), size)
        }
        var found = rows(place)
        #expect(Set(found.keys) == ["gemma", "qwen", "parakeet"])
        #expect(deletable(found) == ["qwen"])  // the old ones wait for the engine's proof
        bytes(place.stores.engineProvenMarker, 1)
        found = rows(place)
        #expect(deletable(found) == ["parakeet", "qwen"])
        let qwen = place.cacheDir(ModelCatalog.model("qwen")!.repo)
        #expect(try Storage.deleteModel("qwen", stores: place.stores) == 17 && !exists(qwen))
        for id in ["gemma", "nope"] {
            #expect(throws: StorageError.self) { try Storage.deleteModel(id, stores: place.stores) }
        }
    }

    @Test func test_retired_models_listed_for_deletion() throws {
        let place = Place(); defer { place.remove() }
        let parakeet = place.cacheDir(ModelCatalog.model("parakeet")!.repo)
        bytes(parakeet.appendingPathComponent("blobs/w"), 2300)
        let copy = place.stores.modelsDir.appendingPathComponent("pyannote-community-1")
        bytes(copy.appendingPathComponent("segmentation/m.bin"), 30)
        let speech = place.stores.modelsDir.appendingPathComponent("fluidaudio/speaker-diarization")
        bytes(speech.appendingPathComponent("plda-parameters.json"), 5)
        var found = rows(place)  // the models are here, but nothing ran with them yet
        #expect(found["parakeet"]?["bytes"] == .int(2300) && found["pyannote"]?["bytes"] == .int(30)
                && found["speech"]?["bytes"] == .int(5))
        #expect(deletable(found).isEmpty)
        #expect(Storage.dropRetired(stores: place.stores) == 0 && exists(parakeet) && exists(copy))  // never by themselves
        bytes(place.stores.engineProvenMarker, 1)  // a meeting transcribed with the engine
        found = rows(place)
        #expect(deletable(found) == ["parakeet", "pyannote"])
        #expect(try Storage.deleteModel("pyannote", stores: place.stores) == 30 && !exists(copy))
        #expect(try Storage.deleteModel("parakeet", stores: place.stores) == 2300 && !exists(parakeet))
        #expect(exists(speech))
    }

    @Test func test_the_old_whisper_model_is_listed_and_kept_while_config_uses_it() throws {
        // #8: Whisper (the default transcriber until October) stayed in the Hugging Face cache unseen. Listed now;
        // deletable once the engine did a meeting's work, never while config.toml's transcriber is mlx-whisper, never by
        // itself.
        let place = Place(); defer { place.remove() }
        let whisper = place.cacheDir("mlx-community/whisper-large-v3-turbo")
        bytes(whisper.appendingPathComponent("blobs/w"), 1600)
        var found = rows(place)
        #expect(found["whisper"]?["bytes"] == .int(1600) && found["whisper"]?["deletable"] == .bool(false))
        #expect(Storage.dropRetired(stores: place.stores) == 0 && exists(whisper))
        bytes(place.stores.engineProvenMarker, 1)
        var uses = Config()
        uses.transcriber = "mlx-whisper"
        let usedRows = Storage.models(config: uses, stores: place.stores)
        #expect(usedRows.first { $0["id"] == .string("whisper") }?["deletable"] == .bool(false))
        #expect(throws: StorageError.self) { try Storage.deleteModel("whisper", config: uses, stores: place.stores) }
        found = rows(place)
        #expect(found["whisper"]?["deletable"] == .bool(true))
        #expect(try Storage.deleteModel("whisper", stores: place.stores) == 1600 && !exists(whisper))
    }

    @Test func test_cleanup_runs_once_an_hour_and_only_when_asked() {
        let place = Place(); defer { place.remove() }
        let runs = Runs()
        let clock = Runs(), days = Runs()  // the last value is the current one
        clock.add(0); days.add(0)
        let c = StorageCleanup(outputDir: place.root, days: { days.all.last! }, clock: { Double(clock.all.last!) },
                               drop: { _, d in runs.add(d) })
        c.tick()
        days.add(30)
        clock.add(10)
        c.tick()  // not an hour yet
        clock.add(3601)
        c.tick()
        c.wait()
        #expect(runs.all == [30])
    }

    @Test func aFailedCleanupIsLoggedAndTriedAgainNextHour() {
        let place = Place(); defer { place.remove() }
        struct Refused: Error, CustomStringConvertible { var description: String { "permission denied" } }
        let clock = Runs(); clock.add(0)
        let logged = Said()
        let c = StorageCleanup(outputDir: place.root, days: { 7 }, clock: { Double(clock.all.last!) },
                               drop: { _, _ in throw Refused() }, log: { logged.add($0) })
        c.tick()
        c.wait()
        clock.add(3601)
        c.tick()
        c.wait()
        #expect(logged.all == Array(repeating: "deleting the audio older than 7 days failed: permission denied", count: 2))
    }

    @Test func test_deleted_marker_survives_a_second_delete() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        _ = try Storage.dropAudio(p)
        bytes(p.micRawWav, 10)  // e.g. put back by hand
        _ = try Storage.dropAudio(p)
        let marker = try PythonJSON.parse(Data(contentsOf: p.folder.appendingPathComponent(Storage.DELETED)))
        #expect(marker["bytes"] == .int(3010))
    }

    @Test func test_a_model_no_longer_offered_goes_at_start() throws {
        let place = Place(); defer { place.remove() }
        let qwen = place.cacheDir(ModelCatalog.QWEN)
        bytes(qwen.appendingPathComponent("blobs/abc"), 100)
        try SettingsFile.update([("local_model", .string(ModelCatalog.QWEN))], stores: place.stores)  // chosen before: ignored now
        #expect(Storage.dropRetired(stores: place.stores) == 100 && !exists(qwen))
        #expect(Storage.dropRetired(stores: place.stores) == 0)
        try FileManager.default.createDirectory(at: qwen.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        var named = Config()
        named.notesLocalModel = ModelCatalog.QWEN  // config.toml still names it: kept
        #expect(Storage.dropRetired(config: named, stores: place.stores) == 0 && exists(qwen))
    }

    @Test func test_the_live_diarizers_scratch_counts_as_audio_and_is_deleted_with_it() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        let scratch = p.folder.appendingPathComponent(".live-diarize.wav")
        bytes(scratch, 500)
        #expect(Storage.audioFiles(p).contains(scratch) && Storage.audioBytes(p) == 3500)
        #expect(try Storage.dropAudio(p) == 3500)
        #expect(!exists(scratch))
    }

    @Test func test_retention_removes_the_live_diarizers_scratch() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        let scratch = p.folder.appendingPathComponent(".live-diarize.wav")
        bytes(scratch, 500)
        let dropped = try Storage.dropOldAudio(place.root, days: 7, now: NOW, timeZone: berlin)
        #expect(dropped.meetings == 1 && dropped.bytes == 3500)
        #expect(!exists(scratch))
    }

    // MARK: - Swift only: the guards around deleting

    @Test func droppingAudioRemovesALinkNeverWhatItPointsTo() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        let outside = place.t.url.appendingPathComponent("elsewhere/keep.wav")
        bytes(outside, 700)
        try FileManager.default.removeItem(at: p.micWav)
        #expect(symlink(outside.path, p.micWav.path) == 0)
        #expect(try Storage.dropAudio(p) == 2700)  // the link counts with its target's size, as Python's stat does
        #expect(!exists(p.micWav) && exists(outside))
    }

    @Test func deletingAModelNeverFollowsALinkOutOfItsFolder() throws {
        let place = Place(); defer { place.remove() }
        let outside = place.t.url.appendingPathComponent("elsewhere", isDirectory: true)
        bytes(outside.appendingPathComponent("keep.bin"), 3)
        let copy = place.stores.modelsDir.appendingPathComponent("pyannote-community-1")
        bytes(copy.appendingPathComponent("segmentation/m.bin"), 30)
        #expect(symlink(outside.path, copy.appendingPathComponent("segmentation/linked").path) == 0)
        #expect(symlink(outside.appendingPathComponent("keep.bin").path, copy.appendingPathComponent("file-link").path) == 0)
        bytes(place.stores.engineProvenMarker, 1)
        #expect(rows(place)["pyannote"]?["bytes"] == .int(33))  // a linked file counts, a linked folder isn't entered
        #expect(try Storage.deleteModel("pyannote", stores: place.stores) == 33)
        #expect(!exists(copy) && exists(outside.appendingPathComponent("keep.bin")))
    }

    @Test func aModelFolderThatIsALinkIsLeftAlone() throws {
        let place = Place(); defer { place.remove() }
        let outside = place.t.url.appendingPathComponent("elsewhere", isDirectory: true)
        bytes(outside.appendingPathComponent("segmentation/m.bin"), 30)
        try FileManager.default.createDirectory(at: place.stores.modelsDir, withIntermediateDirectories: true)
        let copy = place.stores.modelsDir.appendingPathComponent("pyannote-community-1")
        #expect(symlink(outside.path, copy.path) == 0)
        bytes(place.stores.engineProvenMarker, 1)
        #expect(rows(place)["pyannote"]?["deletable"] == .bool(true))
        #expect(try Storage.deleteModel("pyannote", stores: place.stores) == 30)  // rmtree refuses a link: nothing goes
        #expect(exists(copy) && exists(outside.appendingPathComponent("segmentation/m.bin")))
    }

    @Test func aFolderWhoseNameIsNoDateIsNeverOld() throws {
        let place = Place(); defer { place.remove() }
        let bad = place.meeting("2026-02-30T10-00-00")  // no such day: datetime.max, as strptime fails
        let late = place.meeting("2026-10-01T10-00-60")  // second 60: strptime reads it, datetime refuses it
        let old = place.meeting("2026-10-01T10-00-00-2")
        #expect(Storage.olderThan(place.root, days: 7, now: NOW, timeZone: berlin).map(\.id) == [old.id])
        #expect(Storage.canDrop(bad) && Storage.canDrop(late))
    }

    @Test func aMarkerWithBytesThatAreNoNumberIsATypeError() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-01T10-00-00")
        try #"{"at": "x", "bytes": "many"}"#.write(to: p.folder.appendingPathComponent(Storage.DELETED), atomically: false, encoding: .utf8)
        // Python's int + str: a TypeError after the audio went, and retention does not swallow it.
        #expect { try Storage.dropOldAudio(place.root, days: 7, now: NOW, timeZone: berlin) } throws: {
            ($0 as? StorageError)?.kind == .type
        }
        #expect(Storage.audioFiles(p).isEmpty)
    }
}

@Suite struct ModelCatalogTests {
    /// A Hugging Face cache entry of `repo`: blobs, one snapshot linking to them, refs/main naming it.
    private func cached(_ place: Place, _ repo: String, files: [String: Int], commit: String = "abc123") -> URL {
        let folder = place.cacheDir(repo)
        for (name, size) in files {
            let blob = folder.appendingPathComponent("blobs/\(name.replacingOccurrences(of: "/", with: "_"))")
            bytes(blob, size)
            let link = folder.appendingPathComponent("snapshots/\(commit)/\(name)")
            try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = name.split(separator: "/").count
            let up = String(repeating: "../", count: depth + 1)
            #expect(symlink(up + "blobs/" + blob.lastPathComponent, link.path) == 0)
        }
        bytes(folder.appendingPathComponent("refs/main"), 0)
        try! commit.write(to: folder.appendingPathComponent("refs/main"), atomically: false, encoding: .utf8)
        return folder
    }

    @Test func aCompleteDownloadHasEveryBlobAndTheProbe() throws {
        let place = Place(); defer { place.remove() }
        let repo = "intfloat/multilingual-e5-small"
        let folder = cached(place, repo, files: ["config.json": 10, "onnx/model.bin": 20])
        #expect(ModelCatalog.complete(repo, stores: place.stores))
        #expect(ModelCatalog.cachedBytes(repo, stores: place.stores) == 30)
        #expect(ModelCatalog.downloadProgress(repo, stores: place.stores) == 30)
        #expect(!ModelCatalog.complete(repo, probe: "tokenizer.json", stores: place.stores))
        #expect(ModelCatalog.complete(repo, probe: "model.bin", stores: place.stores))  // the file's name, as the cache scan names it
        bytes(folder.appendingPathComponent("blobs/x.incomplete"), 1)
        #expect(!ModelCatalog.complete(repo, stores: place.stores))
    }

    @Test func aMissingOrEmptyBlobOrAStrayRefIsNotComplete() throws {
        let place = Place(); defer { place.remove() }
        let repo = "intfloat/multilingual-e5-small"
        let folder = cached(place, repo, files: ["config.json": 10, "model.bin": 0])
        #expect(!ModelCatalog.complete(repo, stores: place.stores))  // an empty file
        let other = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
        let g = cached(place, other, files: ["config.json": 10, "model.safetensors": 5])
        #expect(ModelCatalog.complete(other, stores: place.stores))
        try FileManager.default.removeItem(at: g.appendingPathComponent("blobs/model.safetensors"))
        #expect(!ModelCatalog.complete(other, stores: place.stores))  // a link whose blob is gone
        _ = folder
        let third = "mlx-community/parakeet-tdt-0.6b-v3"
        let t = cached(place, third, files: ["config.json": 10])
        try "def456".write(to: t.appendingPathComponent("refs/pr"), atomically: false, encoding: .utf8)
        #expect(!ModelCatalog.complete(third, stores: place.stores))  // a ref to a commit that isn't here
        let fourth = "mlx-community/whisper-large-v3"
        let f = cached(place, fourth, files: ["config.json": 10])
        #expect(ModelCatalog.complete(fourth, stores: place.stores))
        #expect(symlink(f.appendingPathComponent("gone").path, f.appendingPathComponent("snapshots/old").path) == 0)
        #expect(!ModelCatalog.complete(fourth, stores: place.stores))  // the scan dates an empty revision by its stat: it raises
        #expect(!ModelCatalog.complete("nobody/nothing", stores: place.stores))
        #expect(ModelCatalog.cachedBytes("nobody/nothing", stores: place.stores) == 0)
    }

    /// Setup's "downloaded" is palaver-lm's: a language model needs the weights it loads (`weightsHere`), so a download
    /// stopped between two files (no partial blob left) is not called downloaded (final review M1).
    @Test func aLanguageModelIsCompleteOnlyWithTheWeightsItLoads() throws {
        let place = Place(); defer { place.remove() }
        let gemma = ModelCatalog.GEMMA
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors", "v": "optiq_vision.safetensors"}}"#
        let g = cached(place, gemma, files: ["config.json": 10, "model.safetensors.index.json": 1, "model-00001-of-00002.safetensors": 5])
        try index.write(to: g.appendingPathComponent("blobs/model.safetensors.index.json"), atomically: false, encoding: .utf8)
        #expect(!ModelCatalog.complete(gemma, stores: place.stores))  // the second shard is missing, nothing .incomplete
        _ = cached(place, gemma, files: ["model-00002-of-00002.safetensors": 5])
        #expect(ModelCatalog.complete(gemma, stores: place.stores))  // the vision sidecar is never downloaded: not needed
        let snap = g.appendingPathComponent("snapshots/abc123").path
        #expect(ModelCatalog.weightsHere(snap))
        // Not a language model: the cache's rule alone (e5 has no model*.safetensors at the top here).
        let e5 = "intfloat/multilingual-e5-small"
        _ = cached(place, e5, files: ["config.json": 10, "onnx/model.bin": 20])
        #expect(ModelCatalog.complete(e5, stores: place.stores))
        #expect(ModelCatalog.isLanguageModel(gemma) && ModelCatalog.isLanguageModel(ModelCatalog.QWEN) && !ModelCatalog.isLanguageModel(e5))
    }

    @Test(arguments: [("model.safetensors", true), ("model-00001-of-00004.safetensors", true), ("modelx.safetensors", true),
                      ("optiq_vision.safetensors", false), ("model.bin", false), ("weights.safetensors", false),
                      ("model.safetensors.index.json", false), ("Model.safetensors", false)])
    func whichFilesAreWeights(_ name: String, _ weights: Bool) {
        #expect(ModelCatalog.isWeights(name) == weights)
    }

    @Test func aRepoWhoseNameHasADoubleDashIsNeverComplete() throws {
        let place = Place(); defer { place.remove() }
        let repo = "someone/model--v2"  // the cache scan reads its folder back as someone/model/v2
        _ = cached(place, repo, files: ["config.json": 10])
        #expect(!ModelCatalog.complete(repo, stores: place.stores))
    }

    @Test func theSpeechModelsAreHereWhenEveryFileIs() throws {
        let place = Place(); defer { place.remove() }
        #expect(!ModelCatalog.speechFilesHere(stores: place.stores))
        let root = place.stores.modelsDir.appendingPathComponent(ModelCatalog.SPEECH_FOLDER)
        for f in ModelCatalog.SPEECH_FILES.dropLast() { bytes(root.appendingPathComponent(f), 1) }
        #expect(!ModelCatalog.speechFilesHere(stores: place.stores))
        bytes(root.appendingPathComponent(ModelCatalog.SPEECH_FILES.last!), 1)
        #expect(ModelCatalog.speechFilesHere(stores: place.stores))
        let speech = ModelCatalog.model("speech")!
        #expect(ModelCatalog.modelHere(speech, repo: ModelCatalog.repoFor(speech), speechHere: { false }, stores: place.stores) == false)
        #expect(ModelCatalog.modelHere(speech, repo: ModelCatalog.repoFor(speech), speechHere: { true }, stores: place.stores))
        let e5 = ModelCatalog.model("e5")!
        #expect(!ModelCatalog.modelHere(e5, repo: e5.repo, speechHere: { true }, stores: place.stores))
    }

    @Test func downloadsRunWhileTheMarkersPidLives() throws {
        let place = Place(); defer { place.remove() }
        let marker = place.stores.downloadingModels
        #expect(!ModelCatalog.downloadsRunning(marker))
        bytes(marker, 0)
        try " \(getpid())\n".write(to: marker, atomically: false, encoding: .utf8)
        #expect(ModelCatalog.downloadsRunning(marker))
        try "not a pid".write(to: marker, atomically: false, encoding: .utf8)
        #expect(!ModelCatalog.downloadsRunning(marker))
    }
}
