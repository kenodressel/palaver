// `palaver-worker run` (the pipeline, the notes helper, the upload to Notion against a stub) and `index` (search by
// meaning; the e5 model downloaded first, from a stub hub here). Python (the notes) is a shell script that writes down
// how it was called.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

/// Each call's arguments as a line in `$CALLS`; `notes` exits `$NOTES_EXIT`.
private let PYTHON = """
#!/bin/sh
echo "$*" >> "$CALLS"
case " $* " in
  *" notes "*) exit "${NOTES_EXIT:-0}" ;;
esac
exit 0
"""

private func fakePython(_ t: Temp, _ extra: [String: String] = [:]) -> (HelperProgram, () -> [String]) {
    t.write("python", PYTHON)
    chmod(t.file("python").path, 0o755)
    var env = testEnv(t)
    env["CALLS"] = t.file("calls.log").path
    for (k, v) in extra { env[k] = v }
    let calls = { ((try? String(contentsOf: t.file("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    return (HelperProgram(program: t.file("python").path, options: ["--config", "/c/config.toml", "--no-notify"], env: env), calls)
}

/// One dimension per word class: enough for an index to be written.
private final class TinyEncoder: MeaningEncoder {
    let dimension = 4
    func query(_ text: String) throws -> [Float] { [1, 0, 0, 0] }
    func passages(_ texts: [String]) throws -> [[Float]] { texts.map { [Float($0.count % 3), 1, 0, 0.5] } }
}

/// A processed meeting `name` in `root` with enough words to index.
private func processed(_ root: URL, _ name: String) throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    let lines: [JSONValue] = [
        Utterance(speaker: "Timo", start: 0, end: 5, text: "Wir sprechen heute über die Kosten des Pilotprojekts bei Northwind.").json,
        Utterance(speaker: "Valerie", start: 5, end: 10, text: "Das Angebot von Contoso kommt bis Freitag, dann entscheiden wir gemeinsam.").json,
    ]
    try PythonJSON.write(.array(lines), to: paths.transcriptJson, indent: 2, ensureAscii: true)
    try PythonJSON.write(.object([("start_time", .string("2026-10-20T14:35:17+02:00")), ("duration_seconds", .double(10))]),
                         to: paths.meta, indent: nil, ensureAscii: true)
    return paths
}

private final class Said: @unchecked Sendable { var lines: [String] = [] }

@Suite(.serialized) struct RunIndexTests {
    @Test func runCallsNotesThenUploads() async throws {
        let t = Temp(); defer { t.remove() }
        var h = Harness(t)
        h.config.notesEnabled = true
        h.config.notionParentPageId = "parent-1"
        let paths = try h.meeting(mic: track(2, loud: [(0, 1)]), system: track(2, loud: []), seconds: 2)
        let (python, calls) = fakePython(t, ["NOTES_EXIT": "1"])
        let services = Services()
        services.on("POST https://api.notion.com/v1/pages", (200, #"{"id": "p1", "url": "https://www.notion.so/p1"}"#))
        var setup = h.setup(fake(#"{"transcribe": {"mic.wav": [{"start": 0.0, "end": 1.0, "text": "Hallo.", "speaker": null, "words": []}]}}"#))
        setup.helper = python
        setup.lm = python.program  // palaver-lm: the same script
        setup.cloud = CloudServices(keys: FileKeyStore(t.file("keychain.json")), http: services.client, configToml: t.file("config.toml"),
                                    env: ["NOTION_TOKEN": "secret_notion_x"])
        // A failed notes run is logged; the upload goes on.
        #expect(try await Run.run(paths.folder, setup) == 0)
        #expect(calls() == ["--config /c/config.toml --no-notify notes \(paths.folder.path)"])
        #expect(services.requests.count == 1 && PythonJSON.read(paths.notionInfo)?["page_url"] == .string("https://www.notion.so/p1"))
        #expect(!h.said.contains("Notes are up to date"))
        #expect(ProcessState.read(paths) == nil)
        // Notes switched off: straight to the upload. No token anywhere: it fails and says so.
        h.config.notesEnabled = false
        setup.config = h.config
        setup.cloud.env = [:]
        await #expect(throws: NotionError.self) { try await Run.run(paths.folder, setup) }
        #expect(calls().count == 1 && services.requests.count == 1)
    }

    @Test func runStopsWhenProcessFails() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let bare = RecordingPaths(h.config.outputDir.appendingPathComponent("2026-10-21T09-00-00", isDirectory: true))
        try FileManager.default.createDirectory(at: bare.folder, withIntermediateDirectories: true)
        let (python, calls) = fakePython(t)
        var setup = h.setup(fake("{}"))
        setup.helper = python
        #expect(try await Run.run(bare.folder, setup) == 2)  // no meta.json, no audio to rebuild it from
        #expect(calls().isEmpty)
        #expect(ProcessState.read(bare)?["reason"] == .string("error"))
    }

    @Test func indexDownloadsTheModelFirst() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        _ = try processed(h.config.outputDir, "2026-10-20T14-35-17")
        let e5 = t.file("e5")
        let downloads = Said()
        let download = {
            downloads.lines.append("e5")
            try FileManager.default.createDirectory(at: e5, withIntermediateDirectories: true)
        }
        var madeFrom: [URL] = []
        let said = Said()
        let rc = await Index.run(outputDir: h.config.outputDir, stores: h.stores, download: download,
                                 modelFolder: { FileManager.default.fileExists(atPath: e5.path) ? e5 : nil },
                                 encoder: { madeFrom.append($0); return TinyEncoder() }, shouldStop: { false },
                                 say: { said.lines.append($0) })
        #expect(rc == 0)
        #expect(downloads.lines == ["e5"])
        #expect(madeFrom.map(\.path) == [e5.path])
        #expect(said.lines == ["Indexed 1 meeting for search by meaning."])
        // Downloaded now: the next run downloads nothing.
        _ = try processed(h.config.outputDir, "2026-10-21T10-00-00")
        #expect(await Index.run(outputDir: h.config.outputDir, stores: h.stores, download: download,
                                modelFolder: { FileManager.default.fileExists(atPath: e5.path) ? e5 : nil },
                                encoder: { _ in TinyEncoder() }, shouldStop: { false }, say: { _ in }) == 0)
        #expect(downloads.lines.count == 1)
    }

    @Test func indexFailsWhenTheModelCannotBeDownloaded() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let paths = try processed(h.config.outputDir, "2026-10-20T14-35-17")
        let downloads = Said()
        let download = {
            downloads.lines.append("e5")
            throw HubError("could not reach huggingface.co: The Internet connection appears to be offline.")
        }
        var made = 0
        let rc = await Index.run(outputDir: h.config.outputDir, stores: h.stores, download: download, modelFolder: { nil },
                                 encoder: { _ in made += 1; return TinyEncoder() }, shouldStop: { false }, say: { _ in })
        #expect(rc == 1)
        #expect(downloads.lines == ["e5"] && made == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.folder.appendingPathComponent(SearchIndex.INDEX_SIG).path))
        // Nothing to index: no model, no download.
        try FileManager.default.removeItem(at: paths.folder)
        #expect(await Index.run(outputDir: h.config.outputDir, stores: h.stores, download: download, modelFolder: { nil },
                                encoder: { _ in TinyEncoder() }, shouldStop: { false }, say: { _ in }) == 0)
        #expect(downloads.lines.count == 1)
    }

    @Test func theIndexWorkerDownloadsE5FromTheHubItself() async throws {
        // `index` with the model missing: the pinned revision's three files from the hub HF_ENDPOINT names (a stub
        // here) into the Hugging Face cache, where the encoder's folder is then found.
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let hub = try TinyHub(repo: E5Encoder.model, revision: E5Encoder.revision,
                              files: ["config.json": "{}", "sentencepiece.bpe.model": "pieces", "model.safetensors": "weights",
                                      "onnx/model.onnx": "not wanted"])
        defer { hub.stop() }
        let cache = HFCache(root: t.file("hub"))
        try Index.downloadE5(hub: HubDownloader(cache: cache, endpoint: URL(string: hub.url)!, sleep: { _ in })) { "hf_StubToken12345" }
        let stores = StorePaths(configDir: h.stores.configDir, home: h.stores.home, hubCache: cache.root)
        let folder = try #require(E5Encoder.modelFolder(stores: stores))
        #expect(folder.path == cache.snapshotDir(repo: E5Encoder.model, revision: E5Encoder.revision).path)
        #expect(try String(contentsOf: folder.appendingPathComponent("sentencepiece.bpe.model"), encoding: .utf8) == "pieces")
        #expect(!hub.paths.contains { $0.contains("onnx") })
        #expect(hub.authorizations == ["Bearer hf_StubToken12345"])
    }

    @Test func indexWritesEveryStaleMeeting() async throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let a = try processed(h.config.outputDir, "2026-10-20T14-35-17")
        let b = try processed(h.config.outputDir, "2026-10-21T10-00-00")
        let said = Said()
        func index(only: [URL]? = nil, stop: @escaping () -> Bool = { false }) async -> Int32 {
            await Index.run(outputDir: h.config.outputDir, only: only, stores: h.stores, download: {}, modelFolder: { t.url },
                            encoder: { _ in TinyEncoder() }, shouldStop: stop, say: { said.lines.append($0) })
        }
        // Paused (a recording started): nothing indexed.
        #expect(await index(stop: { true }) == 0)
        #expect(said.lines.last == "Indexed 0 meetings for search by meaning.")
        #expect(await index() == 0)
        #expect(said.lines.last == "Indexed 2 meetings for search by meaning.")
        for p in [a, b] {
            #expect(SearchIndex.isCurrent(p))
            #expect(FileManager.default.fileExists(atPath: p.folder.appendingPathComponent(SearchIndex.INDEX_NPY).path))
        }
        #expect(await index() == 0)
        #expect(said.lines.last == "Indexed 0 meetings for search by meaning.")  // all current
        // Named folders: a meeting a live worker still records is left out.
        let live = try processed(h.config.outputDir, "2026-10-22T11-00-00")
        let worker = Foundation.Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/sh")
        worker.arguments = ["-c", "sleep 30", "live", live.folder.path]
        try worker.run()
        defer { worker.terminate(); worker.waitUntilExit() }
        try Data("\(worker.processIdentifier)".utf8).write(to: live.folder.appendingPathComponent("live.pid"))
        #expect(WorkerPids.liveRunning(live.folder))
        #expect(await index(only: [live.folder]) == 0)
        #expect(said.lines.last == "Indexed 0 meetings for search by meaning.")
        #expect(!SearchIndex.isCurrent(live))
    }

    @Test func indexPausesWhileTheAppRecordsOrMemoryIsShort() throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        var free = 8.0
        let stop = Index.shouldStop(stores: h.stores, freeGB: { free })
        #expect(!stop())
        try FileManager.default.createDirectory(at: h.stores.daemonJson.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PythonJSON.write(.object([("state", .string("idle")), ("transcribing", .bool(false))]), to: h.stores.daemonJson,
                             indent: nil, ensureAscii: true)
        #expect(!stop())
        try PythonJSON.write(.object([("state", .string("recording"))]), to: h.stores.daemonJson, indent: nil, ensureAscii: true)
        #expect(stop())
        try PythonJSON.write(.object([("state", .string("idle")), ("transcribing", .bool(true))]), to: h.stores.daemonJson,
                             indent: nil, ensureAscii: true)
        #expect(stop())
        try PythonJSON.write(.object([("state", .string("idle"))]), to: h.stores.daemonJson, indent: nil, ensureAscii: true)
        free = 0.5
        #expect(stop())
    }

    @Test func test_index_builds_the_search_index_of_stale_meetings() async throws {
        // The command: nothing stale here (no model needed), then search by meaning switched off in Settings.
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        t.write("config.toml", "[user]\nname = \"Timo\"\n[recording]\noutput_dir = \"\(h.config.outputDir.path)\"\n")
        var env = testEnv(t)
        env["PALAVER_TEST_E5_FOLDER"] = t.file("no-model").path
        let (python, calls) = fakePython(t)
        let head = ["--config", t.file("config.toml").path, "--no-notify"]
        #expect(await WorkerMain.run(head + ["index"], env: env.merging(python.env) { a, _ in a }) == 0)
        try FileManager.default.createDirectory(at: h.stores.configDir, withIntermediateDirectories: true)
        try PythonJSON.write(.object([("search_meaning", .bool(false))]), to: h.stores.settings, indent: 2, ensureAscii: true)
        _ = try processed(h.config.outputDir, "2026-10-20T14-35-17")
        #expect(await WorkerMain.run(head + ["index"], env: env.merging(python.env) { a, _ in a }) == 0)
        #expect(calls().isEmpty)  // switched off: not even the download
    }
}
