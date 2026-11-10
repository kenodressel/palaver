// The setup probe, its permissions, autostart and the model downloads (tests/test_onboarding.py: the downloads and the
// speech probe; tests/test_setup_api.py: the speech models that download by themselves; tests/test_doctor.py: the
// system audio permission as the probe reads it) under their names, and the probe's own tests. No test downloads a
// model from the network or starts the real engine: the engine is tests/fake_engine.py, the hub a stub on this Mac.
import Darwin
import Foundation
import Testing
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let REPO = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let FAKE_ENGINE = REPO.appendingPathComponent("tests/fake_engine.py")

/// Stores in a temporary folder (its home is the `PALAVER_HOME` the probe writes under).
private struct Place {
    let dir = tempFolder("probe")
    var stores: StorePaths {
        StorePaths(configDir: dir.appendingPathComponent("config/palaver", isDirectory: true),
                   home: dir.appendingPathComponent("home", isDirectory: true),
                   hubCache: dir.appendingPathComponent("hub", isDirectory: true))
    }

    /// Every file of the speech models, in models/fluidaudio.
    func speechFiles() throws {
        let root = SpeechCheck.models(stores)
        for rel in ModelCatalog.SPEECH_FILES {
            let file = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
    }

    /// An executable shell script in the folder.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
        chmod(file.path, 0o755)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

private func env(_ extra: [String: String] = [:]) -> [String: String] {
    ProcessInfo.processInfo.environment.merging(extra) { $1 }
}

private func engine(_ path: URL, _ stores: StorePaths, mode: String? = nil) -> EngineProcess {
    EngineProcess(path: { path }, models: SpeechCheck.models(stores), version: "test",
                  env: env(mode.map { ["FAKE_ENGINE_MODE": $0] } ?? [:]), idle: 30)
}

private func model(_ id: String) -> ModelInfo { ModelCatalog.models.first { $0.id == id }! }

private func job(_ d: SetupDownloads, _ i: Int = 0) -> JSONValue? { d.status()["models"]?.arrayValue?[i] }

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

@Suite struct ProbeTests {
    // MARK: - downloads (test_onboarding.py)

    /// `_cache`: a Hugging Face cache entry of `repo` with `files` (and a partial blob).
    @discardableResult
    private func cache(_ root: URL, _ repo: String, _ files: [(String, String)], incomplete: Bool = false) throws -> URL {
        let base = root.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("refs"), withIntermediateDirectories: true)
        let rev = String(repeating: "a", count: 40)
        try Data(rev.utf8).write(to: base.appendingPathComponent("refs/main"))
        let snap = base.appendingPathComponent("snapshots/\(rev)")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        for (i, (name, data)) in files.enumerated() {
            let blob = base.appendingPathComponent("blobs/" + String(repeating: String(i), count: 64))
            try Data(data.utf8).write(to: blob)
            try fm.createSymbolicLink(at: snap.appendingPathComponent(name), withDestinationURL: blob)
        }
        if incomplete {
            try Data("part".utf8).write(to: base.appendingPathComponent("blobs/" + String(repeating: "f", count: 64) + ".incomplete"))
        }
        return base
    }

    @Test func test_complete_needs_every_file_and_no_partial_blob() throws {
        let p = Place()
        defer { p.remove() }
        let hub = p.stores.hubCache
        #expect(!ModelCatalog.complete("org/none", stores: p.stores))
        try cache(hub, "org/ok", [("config.json", "{}"), ("model.safetensors", String(repeating: "x", count: 10))])
        #expect(ModelCatalog.complete("org/ok", stores: p.stores))
        try cache(hub, "org/partial", [("config.json", "{}")], incomplete: true)
        #expect(!ModelCatalog.complete("org/partial", stores: p.stores))
        let base = try cache(hub, "org/broken", [("config.json", "{}"), ("model.safetensors", "y")])
        for blob in try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        where (try? Data(contentsOf: blob))?.count == 1 {
            try FileManager.default.removeItem(at: blob)  // a snapshot file whose blob is gone
        }
        #expect(!ModelCatalog.complete("org/broken", stores: p.stores))
        try cache(hub, "org/noconfig", [("model.safetensors", "z")])
        #expect(!ModelCatalog.complete("org/noconfig", stores: p.stores))
    }

    @Test func test_a_failed_download_can_be_tried_again() throws {
        let tries = Box<[String]>([])
        let d = SetupDownloads(fetch: { m, _ in
            tries.update { $0.append(m.id) }
            if tries.get.count == 1 { throw SetupDownloads.DownloadFailed(description: "connection reset") }
        }, progress: { _ in 0 }, done: { _ in true })
        try d.start(["speech"])
        #expect(until { job(d)?["state"] == .string("failed") })
        #expect(job(d)?["error"] == .string("connection reset"))
        try d.start(["speech"])
        #expect(until { job(d)?["state"] == .string("done") })
        #expect(tries.get == ["speech", "speech"])
    }

    @Test func test_a_download_that_left_files_missing_is_failed() throws {
        let d = SetupDownloads(fetch: { _, _ in }, progress: { _ in 0 }, done: { _ in false })
        try d.start(["gemma"])
        #expect(until { job(d)?["state"] == .string("failed") })
        #expect(job(d)?["error"]?.stringValue?.contains("incomplete") == true)
    }

    @Test func test_download_progress_reads_the_configured_repo() {
        let seen = Box<[String]>([])
        let d = SetupDownloads(fetch: { _, _ in }, progress: { repo in seen.update { $0.append(repo) }; return 0 },
                               done: { _ in true }, repoOf: { $0.id == "gemma" ? "my/gemma" : $0.repo })
        d.setJob("gemma", state: "downloading")
        _ = d.status()
        #expect(seen.get == ["my/gemma"])
    }

    /// The updater runs in the menu bar app, the downloads in the window's server: a file with the server's pid says they
    /// run (#60).
    @Test func test_running_downloads_say_so_on_disk_for_the_updater() throws {
        let p = Place()
        defer { p.remove() }
        let marker = p.dir.appendingPathComponent("downloading")
        let release = DispatchSemaphore(value: 0)
        let d = SetupDownloads(fetch: { _, _ in _ = release.wait(timeout: .now() + 5) }, progress: { _ in 0 },
                               done: { _ in true }, marker: marker)
        #expect(!ModelCatalog.downloadsRunning(marker))
        try d.start(["speech"])
        #expect(until { FileManager.default.fileExists(atPath: marker.path) })
        #expect(try String(contentsOf: marker, encoding: .utf8) == "\(getpid())\n" && ModelCatalog.downloadsRunning(marker))
        release.signal()
        #expect(until { !FileManager.default.fileExists(atPath: marker.path) })
        try Data("999999".utf8).write(to: marker)  // a server that died while downloading
        #expect(!ModelCatalog.downloadsRunning(marker))
    }

    @Test func test_download_progress_counts_in_the_units_of_the_model_size() {
        // disk_gb is in GiB (as free disk and Settings → Storage): progress too, so a download isn't shown complete
        // before its last 7 %.
        let d = SetupDownloads(fetch: { _, _ in }, progress: { _ in 4 * 1_073_741_824 }, done: { _ in true })
        d.setJob("gemma", state: "downloading")
        #expect(job(d)?["done_gb"] == .double(4.0))
    }

    @Test func downloadsAnswerAsPythonsAndRefuseAnUnknownModel() throws {
        let d = SetupDownloads(fetch: { _, _ in }, progress: { _ in 0 }, done: { _ in true })
        #expect(PythonJSON.dumps(d.status()) == #"{"running": false, "models": []}"#)
        #expect(throws: Refused.self) { try d.start(["speech", "nope"]) }
        do { try d.start(["nope"]) } catch { #expect("\(error)" == "no model 'nope'") }
        // The one before it was queued; the thread starts with the next start.
        try d.start(["speech"])
        #expect(until { job(d)?["state"] == .string("done") })
        #expect(PythonJSON.dumps(d.status()) == #"{"running": false, "models": [{"id": "speech", "label": "Speech models", "#
                + #""disk_gb": 0.5, "state": "done", "done_gb": 0.5, "error": null}]}"#)
    }

    // MARK: - the speech models: one download, the engine's (test_onboarding.py)

    @Test func test_speech_model_offered_and_old_ones_retired() {
        let ids = ModelCatalog.models.map(\.id), retired = ModelCatalog.retired.map(\.id)
        #expect(ids.contains("speech") && !ids.contains("parakeet") && !ids.contains("pyannote"))
        #expect(retired.contains("parakeet") && retired.contains("pyannote"))
        let speech = model("speech")
        #expect(speech.label == "Speech models" && speech.diskGB == 0.5 && speech.memory == "under 1 GB while transcribing")
        #expect(speech.localFolder == "fluidaudio" && speech.probe.hasPrefix("speaker-diarization/"))
        let manual = ModelCatalog.retired.filter { ["parakeet", "pyannote"].contains($0.id) }.map(\.manual)
        #expect(manual == [true, true])  // listed in Storage, never dropped by themselves
    }

    /// The engine sends progress per model; the assistant's download state shows one combined fraction (asr 95 %, the
    /// diarizer 5 %), never going back.
    @Test func test_speech_download_runs_prepare_with_progress() throws {
        let p = Place()
        defer { p.remove() }
        let log = p.dir.appendingPathComponent("requests.jsonl")
        // The fake engine behind a tee, so the test sees the requests it got.
        let spy = try p.script("engine", "tee -a '\(log.path)' | exec '\(FAKE_ENGINE.path)' \"$@\"\n")
        let seen = Box<[Double]>([])
        let cleared = Box(0)
        let d = SetupDownloads(fetch: { m, d in
            try SetupDownloads.fetchSpeech(engine: engine(spy, p.stores, mode: "progress"), setFraction: { f in
                seen.update { $0.append(Py.round(f, 3)) }
                d.setFraction(m.id, f)
            }, finally: { cleared.update { $0 += 1 } })
        }, progress: { _ in 0 }, done: { _ in true })
        try d.start(["speech"])
        #expect(until(10) { job(d)?["state"] == .string("done") })
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { line -> [String] in
            let req = try! PythonJSON.parse(Data(line.utf8))
            return [req["cmd"]!.stringValue!] + req["models"]!.arrayValue!.map { $0.stringValue! }
        }
        #expect(calls == [["prepare", "asr"], ["prepare", "diarizer"]])
        let fractions = seen.get
        #expect(fractions == fractions.sorted() && fractions.last == 1.0 && fractions.contains(0.95))
        #expect(fractions[0] > 0 && fractions[0] < 0.95)
        #expect(job(d)?["done_gb"] == .double(0.5))
        #expect(cleared.get == 1)  // speech_here.cache_clear()
    }

    @Test func test_speech_download_shows_its_progress_while_it_runs() {
        let d = SetupDownloads(fetch: { _, _ in }, progress: { _ in 0 }, done: { _ in true })
        d.setJob("speech", state: "downloading")
        d.setFraction("speech", 0.4)
        d.setFraction("speech", 0.2)  // a late, lower number does not move it back
        #expect(job(d)?["done_gb"] == .double(0.2))  // 0.4 of 0.5 GB
    }

    @Test func test_speech_download_that_the_engine_refuses_fails_with_its_message() throws {
        let p = Place()
        defer { p.remove() }
        let d = SetupDownloads(fetch: { m, d in
            try SetupDownloads.fetchSpeech(engine: engine(FAKE_ENGINE, p.stores, mode: "error"),
                                           setFraction: { d.setFraction(m.id, $0) }, finally: {})
        }, progress: { _ in 0 }, done: { _ in true })
        try d.start(["speech"])
        #expect(until(10) { job(d)?["state"] == .string("failed") })
        #expect(job(d)?["error"] == .string("no such wav"))
    }

    @Test func test_speech_models_here_ask_the_engine_when_the_files_are_there() throws {
        let p = Place()
        defer { p.remove() }
        func check(_ engineAt: URL) -> SpeechCheck {
            SpeechCheck(stores: p.stores, enginePath: { try EnginePath.find(env: ["PALAVER_ENGINE": engineAt.path]) }, env: env())
        }
        #expect(!check(FAKE_ENGINE).here())  // no files: no engine needed
        try p.speechFiles()
        #expect(ModelCatalog.speechFilesHere(stores: p.stores))
        let none = check(p.dir.appendingPathComponent("no-engine"))  // not built: the files decide
        #expect(none.here())
        #expect(ModelCatalog.modelHere(model("speech"), repo: "fluidaudio", speechHere: none.here, stores: p.stores))
        // an engine that answers: its ModelStore has the last word (the fake's hello has no models: not ready)
        #expect(!check(FAKE_ENGINE).here())
    }

    @Test func test_speech_here_is_cached_for_a_while() throws {
        let p = Place()
        defer { p.remove() }
        try p.speechFiles()
        let hellos = Box(0), now = Box(1000.0)
        let check = SpeechCheck(stores: p.stores, enginePath: { FAKE_ENGINE }, clock: { now.get }, hello: { path in
            hellos.update { $0 += 1 }
            return try SpeechCheck.hello(engine: path, stores: p.stores, env: env())
        })
        _ = check.here()
        _ = check.here()
        #expect(hellos.get == 1)  // one engine for two asks
        now.update { $0 += 31 }
        _ = check.here()
        #expect(hellos.get == 2)
        check.clear()
        _ = check.here()
        #expect(hellos.get == 3)
    }

    @Test func test_an_engine_that_crashes_on_hello_means_not_ready() throws {
        let p = Place()
        defer { p.remove() }
        try p.speechFiles()
        let crash = env(["FAKE_ENGINE_MODE": "crash"])
        #expect(!SpeechCheck(stores: p.stores, enginePath: { try EnginePath.find(env: ["PALAVER_ENGINE": FAKE_ENGINE.path]) },
                             env: crash).here())
        let missing = p.dir.appendingPathComponent("no-engine").path  // not found: the files decide
        #expect(SpeechCheck(stores: p.stores, enginePath: { try EnginePath.find(env: ["PALAVER_ENGINE": missing]) }, env: crash).here())
    }

    @Test func anEngineThatDiesSaysSoWithItsLastWords() throws {
        let p = Place()
        defer { p.remove() }
        let e = engine(FAKE_ENGINE, p.stores, mode: "crash")
        #expect { try e.call("hello") } throws: { error in
            "\(error)".hasPrefix("the speech engine died (exit 3):") && "\(error)".contains("fake engine: out of memory")
        }
        e.close()
        let ok = engine(FAKE_ENGINE, p.stores)
        defer { ok.close() }
        let hello = try ok.call("hello")
        #expect(hello["cmd"] == .string("hello"))
        #expect(hello["args"] == .strings(["--models", SpeechCheck.models(p.stores).path, "--version", "test"]))
        let missing = EngineProcess(path: { try EnginePath.find(env: [:], location: AppLocation(executable: p.dir.appendingPathComponent("x"))) },
                                    models: SpeechCheck.models(p.stores), version: "test", env: env())
        #expect { try missing.call("hello") } throws: { "\($0)" == "the speech engine is missing: run `make engine`" }
    }

    @Test func theEngineIsBesideTheServerInARelease() throws {
        let p = Place()
        defer { p.remove() }
        let macos = p.dir.appendingPathComponent("Palaver.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let release = AppLocation(executable: macos.appendingPathComponent("palaver-server"))
        #expect { try EnginePath.find(env: [:], location: release) } throws: { "\($0)" == "the speech engine is missing: reinstall Palaver" }
        try Data().write(to: macos.appendingPathComponent("palaver-engine"))
        #expect(try EnginePath.find(env: [:], location: release).path == macos.appendingPathComponent("palaver-engine").path)
        #expect(try EnginePath.find(env: ["PALAVER_ENGINE": "/x/engine"], location: release).path == "/x/engine")
    }

    // MARK: - the other models: from Hugging Face in this process

    /// A long helper's stderr (a 6 h download's progress) is kept as its last lines only.
    @Test func aHelpersStderrIsKeptAsItsTail() throws {
        let p = Place()
        defer { p.remove() }
        let chatty = try p.script("python-chatty", """
            i=0; while [ $i -lt 4000 ]; do echo "progress line $i of a long download" >&2; i=$((i+1)); done
            echo 'OSError: no space left' >&2
            exit 1

            """)
        let done = try HelperChild.run([chatty.path], env: env(), input: Data(), timeout: 30)
        let text = String(decoding: done.stderr, as: UTF8.self)
        #expect(done.code == 1 && done.stderr.count <= HelperChild.STDERR_TAIL)
        #expect(text.hasPrefix("progress line ") && text.hasSuffix("OSError: no space left\n"))  // whole lines
    }

    /// Downloads as the page starts them, with the real fetch against a stub hub: the cache's bytes are the progress,
    /// the model is done when the cache has it, and the search index then finds e5's folder.
    private func hubDownloads(_ p: Place, _ hub: TinyHub, token: String? = nil) -> SetupDownloads {
        let stores = p.stores
        let downloader = HubDownloader(cache: HFCache(stores: stores), endpoint: URL(string: hub.url)!, sleep: { _ in })
        return SetupDownloads(fetch: { m, _ in
            try SetupDownloads.fetchFromHub(repo: ModelCatalog.repoFor(m), hub: downloader, token: { token })
        }, progress: { ModelCatalog.downloadProgress($0, stores: stores) },
        done: { m in ModelCatalog.modelHere(m, repo: ModelCatalog.repoFor(m), speechHere: { false }, stores: stores) },
        marker: stores.downloadingModels)
    }

    private func settled(_ d: SetupDownloads) -> JSONValue {
        let deadline = Date().addingTimeInterval(20)
        while d.status()["running"] == .bool(true) && Date() < deadline { usleep(20_000) }
        return d.status()
    }

    @Test func otherModelsComeFromTheHubIntoTheHuggingFaceCache() throws {
        let p = Place()
        defer { p.remove() }
        let hub = try TinyHub(repo: E5Encoder.model, revision: E5Encoder.revision,
                              files: ["config.json": "{}", "sentencepiece.bpe.model": "pieces", "model.safetensors": "weights",
                                      "README.md": "not wanted"])
        defer { hub.stop() }
        let d = hubDownloads(p, hub, token: "hf_StubToken12345")
        try d.start(["e5"])
        let row = try #require(settled(d)["models"]?.arrayValue?.first)
        #expect(row["state"] == .string("done") && row["error"] == .null && row["done_gb"] == .double(0.47))
        #expect(E5Encoder.modelFolder(stores: p.stores) != nil)  // where the index looks
        #expect(!hub.paths.contains { $0.contains("README") })
        #expect(hub.authorizations == ["Bearer hf_StubToken12345"])
        #expect(!FileManager.default.fileExists(atPath: p.stores.downloadingModels.path))  // the marker is gone
    }

    @Test func aFailedHubDownloadIsOneLineOnThePage() throws {
        let p = Place()
        defer { p.remove() }
        let hub = try TinyHub(repo: "someone/else", revision: "main", files: [:])  // Gemma is not on this hub
        defer { hub.stop() }
        let d = hubDownloads(p, hub, token: "hf_StubToken12345")
        try d.start(["gemma"])
        let row = try #require(settled(d)["models"]?.arrayValue?.first)
        #expect(row["state"] == .string("failed"))
        #expect(row["error"] == .string("Hugging Face has no \(ModelCatalog.GEMMA) at revision de9e18386805 (HTTP 404)"))
        #expect(hub.paths == ["/api/models/\(ModelCatalog.GEMMA)/revision/de9e183868050b34bf6b4272518500ffcebf15b3"])
    }

    // MARK: - the speech models download by themselves (test_setup_api.py)

    @Test func test_missing_speech_models_download_by_themselves() {
        // Every meeting waits for them and there is nothing to choose: a tester who never found the download in Settings
        // must not be left with untranscribed calls.
        let probe = FakeProbe()
        #expect(probe.fetchMissingSpeech())
        #expect(until { probe.fetched.contains("speech") })
    }

    @Test func test_speech_models_already_here_are_not_fetched_again() {
        let probe = FakeProbe(downloaded: ["speech"])
        #expect(!probe.fetchMissingSpeech())
        #expect(probe.fetched.isEmpty)
    }

    @Test func test_a_mac_without_apple_silicon_downloads_nothing() {
        let probe = FakeProbe(hardware: Hardware(chip: "Intel Core i7", memoryGB: 16, freeDiskGB: 200))
        #expect(!probe.fetchMissingSpeech())
        #expect(probe.fetched.isEmpty)
    }

    @Test func test_the_installed_apps_server_fetches_them_at_start_a_checkouts_never() throws {
        let probe = FakeProbe()
        let s = try TestServer(probe: probe)
        defer { s.stop() }
        ServeMain.fetchSpeech(s.app, installed: false)
        ServeMain.fetchSpeech(s.app)  // this test runs from a checkout
        #expect(probe.fetched.isEmpty && probe.downloads.status()["models"] == .array([]))
        ServeMain.fetchSpeech(s.app, installed: true)
        #expect(until { probe.fetched.contains("speech") })
    }

    // MARK: - the system audio permission (test_doctor.py, as the probe words it)

    private func session(_ folder: URL, _ source: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((#"{"event": "record_start", "system_source": "\#(source)"}"# + "\n").utf8)
            .write(to: folder.appendingPathComponent("session.log"))
    }

    private func write(_ text: String, _ file: URL) throws { try Data(text.utf8).write(to: file) }

    @Test func test_system_audio_permission_from_last_recording() throws {
        let p = Place()
        defer { p.remove() }
        let rec = p.dir.appendingPathComponent("2026-10-20T14-35-17")
        try session(rec, "process-tap")
        #expect(SetupPermissions.systemAudio(outputDir: p.dir)["state"] == .string("granted"))
        try session(rec, "scstream")
        let fallback = SetupPermissions.systemAudio(outputDir: p.dir)
        #expect(fallback["state"] == .string("fallback") && fallback["fix"]?.stringValue?.contains("System Audio") == true)
        let none = SetupPermissions.systemAudio(outputDir: p.dir.appendingPathComponent("empty"))
        #expect(PythonJSON.dumps(none, ensureAscii: false)
                == #"{"state": "unverified", "detail": "not verified yet", "fix": "checked on the first recording"}"#)
    }

    /// The check says which meeting, as a person reads it (setup assistant and CLI).
    @Test func test_system_audio_names_the_meeting_not_its_folder() throws {
        let p = Place()
        defer { p.remove() }
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        func detail() -> String? { SetupPermissions.systemAudio(outputDir: p.dir, timeZone: berlin)["detail"]?.stringValue }
        let rec = p.dir.appendingPathComponent("2026-10-29T16-07-55")
        try session(rec, "process-tap")
        #expect(detail() == "Process Tap worked in the meeting on 29\u{a0}Oct, 16:07")
        try write(#"{"title": "Budget review"}"#, rec.appendingPathComponent("notes.json"))
        #expect(detail() == "Process Tap worked in “Budget review” on 29\u{a0}Oct, 16:07")
        try write(#"{"title": "Weekly sync", "start": "x", "end": "y"}"#, rec.appendingPathComponent("calendar.json"))
        #expect(detail() == "Process Tap worked in “Weekly sync” on 29\u{a0}Oct, 16:07")
        try write(#"{"title": "Budget with Valerie"}"#, rec.appendingPathComponent("title.json"))  // renamed by the user
        #expect(detail() == "Process Tap worked in “Budget with Valerie” on 29\u{a0}Oct, 16:07")
        try FileManager.default.removeItem(at: rec.appendingPathComponent("title.json"))
        try session(rec, "scstream")
        #expect(detail() == "works with a fallback (fell back to ScreenCaptureKit in “Weekly sync” on 29\u{a0}Oct, 16:07)")
        // The start the Meetings window shows (meta.json), which can be earlier than the folder's name.
        try write(#"{"start_time": "2026-10-29T16:06:25+01:00"}"#, rec.appendingPathComponent("meta.json"))
        #expect(detail()?.hasSuffix("on 29\u{a0}Oct, 16:06)") == true)
    }

    @Test func theLatestRecordingWithASessionLogDecides() throws {
        let p = Place()
        defer { p.remove() }
        try session(p.dir.appendingPathComponent("2026-10-20T14-35-17"), "process-tap")
        try session(p.dir.appendingPathComponent("2026-10-21T09-00-00"), "scstream")
        try FileManager.default.createDirectory(at: p.dir.appendingPathComponent("2026-10-22T09-00-00"), withIntermediateDirectories: true)
        try session(p.dir.appendingPathComponent("notes"), "process-tap")  // no recording folder
        #expect(SetupPermissions.systemAudio(outputDir: p.dir)["state"] == .string("fallback"))
        try write("{cut short\n[1]\n" + #"{"event": "record_start", "system_source": ""}"# + "\n",
                  p.dir.appendingPathComponent("2026-10-21T09-00-00/session.log"))
        #expect(SetupPermissions.systemAudio(outputDir: p.dir)["state"] == .string("granted"))  // the one before decides
    }

    // MARK: - the other permissions

    @Test func microphoneAndNotificationsAreReadNeverAsked() throws {
        let p = Place()
        defer { p.remove() }
        func state(_ v: JSONValue) -> String? { v["state"]?.stringValue }
        #expect(state(SetupPermissions.microphone(status: 0)) == "not_asked")
        #expect(state(SetupPermissions.microphone(status: 3)) == "granted")
        #expect(state(SetupPermissions.microphone(status: 2)) == "denied" && state(SetupPermissions.microphone(status: 1)) == "denied")
        #expect(PythonJSON.dumps(SetupPermissions.microphone(status: nil)) == #"{"state": "unknown", "detail": "could not check"}"#)
        let file = p.dir.appendingPathComponent("notify-state")
        #expect(state(SetupPermissions.notifications(statePath: nil)) == "unknown")
        for (written, want) in [("allowed\n", "granted"), ("denied", "denied"), ("not_asked", "not_asked"), ("maybe", "unknown")] {
            try write(written, file)
            #expect(state(SetupPermissions.notifications(statePath: file.path)) == want)
        }
    }

    // MARK: - the Mac

    private func macProbe(_ p: Place, recording: RecordingRemote? = nil, config: Config = Config(),
                          calendar: CalendarProvider? = nil) -> MacProbe {
        MacProbe(stores: p.stores, outputDir: p.dir.appendingPathComponent("Meetings"), config: config,
                 recording: recording, calendar: calendar,
                 notifyState: nil, env: ["PATH": p.dir.appendingPathComponent("bin").path],
                 enginePath: { p.dir.appendingPathComponent("no-engine") })
    }

    @Test func theMacProbeReadsThisMac() throws {
        let p = Place()
        defer { p.remove() }
        let probe = macProbe(p)
        try FileManager.default.createDirectory(at: p.stores.home, withIntermediateDirectories: true)  // its free space
        let hw = probe.hardware()
        #expect(!hw.chip.isEmpty && hw.chip != "unknown")
        #expect(hw.memoryGB > 0 && hw.memoryGB == hw.memoryGB.rounded())
        #expect(hw.freeDiskGB > 0)
        #expect(Array(probe.permissions().keys) == ["microphone", "calendar", "system_audio", "notifications"])
        #expect(probe.permissions()["system_audio"]?["state"] == .string("unverified"))
        #expect(probe.downloaded().isEmpty && !probe.speechHere())
        try p.speechFiles()
        probe.speech.clear()
        #expect(probe.downloaded() == ["speech"] && probe.speechHere())  // no engine: the files decide
        #expect(!probe.fullName().contains(","))
        #expect(try probe.calendarEvents(Date(), Date().addingTimeInterval(3600)).isEmpty)  // the calendar is off
    }

    @Test func appsInEitherApplicationsFolderCount() throws {
        let p = Place()
        defer { p.remove() }
        let probe = macProbe(p)
        probe.desktopApp = p.dir.appendingPathComponent("Claude.app")
        let before = probe.installed()
        try FileManager.default.createDirectory(at: p.stores.applications.appendingPathComponent("Slack.app"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: probe.desktopApp, withIntermediateDirectories: true)
        let after = probe.installed()
        #expect(after.slack && after.claudeDesktop)
        #expect(after.teams == before.teams)  // /Applications as this Mac has it
        #expect(probe.appDirs.map(\.path) == ["/Applications", p.stores.applications.path])
    }

    @Test func claudeCodeIsFoundWhereItIsInstalled() throws {
        let p = Place()
        defer { p.remove() }
        let home = p.stores.home
        let bin = p.dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("claude"))  // not executable: not it
        let system = MacProbe.findClaude(configured: nil, env: ["PATH": bin.path], home: home)  // this Mac's, if any
        #expect(system == nil || ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains(system!))
        let local = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try p.script("home/.local/bin/claude", "exit 0\n")
        #expect(MacProbe.findClaude(configured: nil, env: ["PATH": bin.path], home: home) == local.path)
        let onPath = try p.script("bin/claude", "exit 0\n")
        #expect(MacProbe.findClaude(configured: nil, env: ["PATH": bin.path], home: home) == onPath.path)
        #expect(MacProbe.findClaude(configured: onPath.path, env: [:], home: home) == onPath.path)
        #expect(MacProbe.findClaude(configured: p.dir.appendingPathComponent("nope").path, env: ["PATH": bin.path], home: home) == nil)
    }

    @Test func theCalendarPermissionIsTheApps() throws {
        let p = Place()
        defer { p.remove() }
        let sock = shortFolder()
        defer { try? FileManager.default.removeItem(at: sock) }
        let app = FakeAppSocket(sock.appendingPathComponent("app.sock")) { name, _ in
            name == "calendar" ? .ok(.object([("state", .string("granted")), ("detail", .string("connected (read only)"))]))
                : .failed("no")
        }
        let remote = Remote(statePath: sock.appendingPathComponent("daemon.json"), socketPath: app.path,
                            localCalendar: { .object([("state", .string("unknown"))]) })
        #expect(macProbe(p, recording: remote).permissions()["calendar"]?["state"] == .string("granted"))
        app.stop()
        #expect(macProbe(p, recording: remote).permissions()["calendar"]?["state"] == .string("unknown"))  // the app is gone
    }

    @Test func autostartWritesUnderPalaverHome() throws {
        let p = Place()
        defer { p.remove() }
        let probe = macProbe(p)
        #expect(!probe.autostart())
        try probe.setAutostart(true)
        let agent = p.stores.home.appendingPathComponent("Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist")
        #expect(probe.autostart() && FileManager.default.fileExists(atPath: agent.path))
        let app = p.stores.home.appendingPathComponent("Applications/Palaver.app").path
        // plistlib.dumps's bytes, as app_bundle.launch_agent_plist writes them.
        let want = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n"
            + "\t<string>com.kenodressel.meeting-transcribe</string>\n\t<key>ProgramArguments</key>\n\t<array>\n"
            + "\t\t<string>/usr/bin/open</string>\n\t\t<string>-g</string>\n\t\t<string>-a</string>\n"
            + "\t\t<string>\(app)</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n</dict>\n</plist>\n"
        #expect(try String(contentsOf: agent, encoding: .utf8) == want)
        #expect(String(decoding: Autostart.plist(app: "/tmp/h & <x>/Palaver.app"), as: UTF8.self)
            .contains("<string>/tmp/h &amp; &lt;x&gt;/Palaver.app</string>"))
        try probe.setAutostart(false)
        #expect(!probe.autostart() && !FileManager.default.fileExists(atPath: agent.path))
        try probe.setAutostart(false)  // off twice is no error
    }

    // MARK: - the end-to-end tests' Mac

    @Test func theTestProbeReadsItsFileAtEveryLook() throws {
        let p = Place()
        defer { p.remove() }
        let file = p.dir.appendingPathComponent("probe.json")
        let probe = TestProbe(file: file, stores: p.stores)
        #expect(probe.hardware() == Hardware(chip: "Apple M4 Pro", memoryGB: 48, freeDiskGB: 120))
        #expect(probe.installed() == Installed(teams: true, slack: false, claudeCode: true))
        #expect(probe.fullName() == "Timo Strauss" && probe.downloaded().isEmpty)
        #expect(probe.permissions()["calendar"]?["state"] == .string("not_asked"))
        try write("""
            {"hardware": {"chip": "Apple M2", "memory_gb": 16, "free_disk_gb": 30.5},
             "installed": {"slack": true},
             "permissions": {"microphone": {"state": "denied", "detail": "not allowed"}},
             "downloaded": ["speech"],
             "events": [{"title": "Northwind weekly", "start": "2026-11-09T10:00:00+01:00", "end": "2026-11-09T10:30:00+01:00"}],
             "full_name": "Valerie"}
            """, file)
        #expect(probe.hardware() == Hardware(chip: "Apple M2", memoryGB: 16, freeDiskGB: 30.5))
        #expect(probe.installed() == Installed(slack: true))
        #expect(Array(probe.permissions().keys) == ["microphone"] && probe.fullName() == "Valerie")
        #expect(probe.downloaded() == ["speech"] && probe.speechHere())
        let day = Py.fromIso("2026-11-09T00:00:00+01:00")!
        #expect(try probe.calendarEvents(day, day.addingTimeInterval(86400)).map(\.title) == ["Northwind weekly"])
        #expect(try probe.calendarEvents(day.addingTimeInterval(86400), day.addingTimeInterval(2 * 86400)).isEmpty)
        try probe.setAutostart(true)
        #expect(probe.autostart() && FileManager.default.fileExists(atPath: p.stores.launchAgent.path))
    }

    @Test func theTestProbeHoldsDownloadsUntilItsHoldFileGoes() throws {
        let p = Place()
        defer { p.remove() }
        let file = p.dir.appendingPathComponent("probe.json")
        try write(#"{"hold_downloads": true, "fail_once": ["gemma"]}"#, file)
        let probe = TestProbe(file: file, stores: p.stores)
        try write("", probe.holdFile)
        try probe.downloads.start(["speech"])
        usleep(200_000)
        #expect(job(probe.downloads)?["state"] == .string("downloading") && probe.downloaded().isEmpty)
        #expect(ModelCatalog.downloadsRunning(p.stores.downloadingModels))
        try FileManager.default.removeItem(at: probe.holdFile)
        #expect(until { job(probe.downloads)?["state"] == .string("done") })
        #expect(probe.downloaded() == ["speech"])
        #expect(until { !FileManager.default.fileExists(atPath: p.stores.downloadingModels.path) })
        try probe.downloads.start(["gemma"])
        #expect(until { job(probe.downloads, 1)?["state"] == .string("failed") })
        #expect(job(probe.downloads, 1)?["error"] == .string("connection reset"))
        try probe.downloads.start(["gemma"])
        #expect(until { job(probe.downloads, 1)?["state"] == .string("done") })
        #expect(probe.downloaded() == ["speech", "gemma"])
    }

    @Test func theTestProbeRecordsEveryDownloadTried() throws {
        let p = Place()
        defer { p.remove() }
        let file = p.dir.appendingPathComponent("probe.json")
        try write(#"{"fail_once": ["gemma"]}"#, file)
        let probe = TestProbe(file: file, stores: p.stores)
        #expect(!FileManager.default.fileExists(atPath: probe.fetchedFile.path))
        try probe.downloads.start(["gemma"])
        #expect(until { job(probe.downloads)?["state"] == .string("failed") })
        try probe.downloads.start(["gemma"])
        #expect(until { job(probe.downloads)?["state"] == .string("done") })
        #expect(try String(contentsOf: probe.fetchedFile, encoding: .utf8) == "gemma\ngemma\n")  // the failed try too
    }
}
