// The status of a recording folder (cli._status), the worker pid files (live.py, stream.py), the
// local-only marker (llm.py) and transcription.json (transcription.py).
import Darwin
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

private func touch(_ url: URL, bytes: String = "RIFF...", mtime: Date? = nil) {
    try! bytes.write(to: url, atomically: false, encoding: .utf8)
    if let mtime { try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
}

private func part(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".part") }

@Suite struct MeetingStatusTests {
    @Test func test_status_precedence() {
        let t = TempFolder("status"); defer { t.remove() }
        let p = RecordingPaths(t.url)
        // incomplete: no wavs
        #expect(MeetingStatus.status(p) == "incomplete")
        // recorded: a V2 capture (pre-AEC mic + system) but no transcript
        touch(p.micRawWav); touch(p.systemWav)
        #expect(MeetingStatus.status(p) == "recorded")
        // processed: transcript exists
        touch(p.transcriptJson, bytes: "[]")
        #expect(MeetingStatus.status(p) == "processed")
        // synced: notion info exists (highest precedence)
        touch(p.notionInfo, bytes: "{}")
        #expect(MeetingStatus.status(p) == "synced")
    }

    @Test func test_status_synced_takes_precedence_even_if_transcript_missing() {
        let t = TempFolder("status"); defer { t.remove() }
        let p = RecordingPaths(t.url)
        touch(p.notionInfo, bytes: "{}")
        #expect(MeetingStatus.status(p) == "synced")
    }

    @Test func test_status_crashed_when_part_files_remain() {
        let t = TempFolder("status"); defer { t.remove() }
        let p = RecordingPaths(t.url)
        touch(part(p.micRawWav)); touch(part(p.systemWav))
        #expect(MeetingStatus.status(p, now: Date().addingTimeInterval(3600)).hasPrefix("crashed"))
        #expect(MeetingStatus.status(p, now: Date().addingTimeInterval(3600)) == "crashed (run `process` to recover)")
    }

    @Test func test_status_recording_while_part_files_still_grow() {
        let t = TempFolder("status"); defer { t.remove() }
        let p = RecordingPaths(t.url)
        touch(part(p.micRawWav))
        #expect(MeetingStatus.status(p) == "recording")
    }

    @Test func aGrowingPartIsRecording() {
        let t = TempFolder("status"); defer { t.remove() }
        let p = RecordingPaths(t.url)
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        touch(part(p.systemWav), mtime: written)
        touch(part(p.micRawWav), mtime: written.addingTimeInterval(-500))  // the newest of the two counts
        #expect(MeetingStatus.status(p, now: written.addingTimeInterval(59.9)) == "recording")
        #expect(MeetingStatus.status(p, now: written.addingTimeInterval(60)) == "crashed (run `process` to recover)")
        // A recording with both tracks in place is recorded, whatever parts are left.
        touch(p.micRawWav); touch(p.systemWav)
        #expect(MeetingStatus.status(p, now: written.addingTimeInterval(1)) == "recorded")
        // The processed mic.wav counts for the recorded mic as well.
        try? FileManager.default.removeItem(at: p.micRawWav)
        touch(p.micWav)
        #expect(MeetingStatus.status(p, now: written.addingTimeInterval(1)) == "recorded")
    }
}

@Suite struct WorkerPidsTests {
    private func livePid(_ t: TempFolder, _ pid: Int32) { t.write("live.pid", String(pid)) }

    /// A child that exited and was reaped: nobody has its pid now.
    private func exitedPid() -> Int32 {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// `sh -c 'read x' palaver live <folder>`: a process whose command line is `palaver live <folder>`.
    private func worker(for folder: String) -> (Foundation.Process, Pipe) {
        let p = Foundation.Process(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "read x", "palaver", "live", folder]
        p.standardInput = stdin
        try! p.run()
        return (p, stdin)
    }

    private func stop(_ p: Foundation.Process, _ stdin: Pipe) {
        p.terminate()
        p.waitUntilExit()
        try? stdin.fileHandleForWriting.close()
    }

    @Test func test_a_stale_live_pid_is_removed() {
        let t = TempFolder("pids"); defer { t.remove() }
        // A pid of an exited child: nobody has it any more.
        livePid(t, exitedPid())
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(!t.exists("live.pid"))
        // A live pid whose command line is not ` live <folder>`: ours (the test runner's), not a worker.
        livePid(t, getppid())
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(!t.exists("live.pid"))
    }

    @Test func test_a_stale_pid_file_is_no_running_worker_and_is_removed() {
        let t = TempFolder("pids"); defer { t.remove() }
        livePid(t, exitedPid())
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(!t.exists("live.pid"))
    }

    @Test func test_an_exited_child_worker_is_reaped_not_counted() {
        let t = TempFolder("pids"); defer { t.remove() }
        // posix_spawn, not Process: Foundation reaps its children itself, and a zombie is the point.
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("true"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0)
        var tries = 0
        while tries < 100 {  // exited, not waited for: a zombie, and kill(pid, 0) still succeeds
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { break }
            usleep(20_000); tries += 1
        }
        livePid(t, pid)
        #expect(kill(pid, 0) == 0)
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(!t.exists("live.pid"))
        #expect(kill(pid, 0) == -1)  // reaped by the check
    }

    @Test func test_a_pid_now_used_by_another_program_is_no_worker() {
        let t = TempFolder("pids"); defer { t.remove() }
        livePid(t, getppid())  // alive, but not `palaver live <this folder>`
        #expect(!WorkerPids.liveRunning(t.url))
    }

    @Test func test_a_live_worker_for_this_folder_is_running() {
        let t = TempFolder("pids"); defer { t.remove() }
        let (w, stdin) = worker(for: t.url.path)
        defer { stop(w, stdin) }
        livePid(t, w.processIdentifier)
        #expect(WorkerPids.liveRunning(t.url))
        #expect(t.exists("live.pid"))
    }

    @Test func test_a_worker_for_a_folder_with_a_similar_name_is_not_this_ones() {
        let t = TempFolder("pids"); defer { t.remove() }
        let mine = t.url.appendingPathComponent("2026-10-29T12-06-10")
        let other = t.url.appendingPathComponent("2026-10-29T12-06-10-2")
        try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (w, stdin) = worker(for: other.path)
        defer { stop(w, stdin) }
        try! String(w.processIdentifier).write(to: mine.appendingPathComponent("live.pid"), atomically: false, encoding: .utf8)
        #expect(!WorkerPids.liveRunning(mine))
    }

    @Test func aMissingOrBrokenPidFileIsNoWorker() {
        let t = TempFolder("pids"); defer { t.remove() }
        #expect(!WorkerPids.liveRunning(t.url))
        t.write("live.pid", "not a pid")
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(t.exists("live.pid"))  // unreadable pids are left as they are
        t.write("live.pid", " 0\n")
        #expect(!WorkerPids.liveRunning(t.url))
        #expect(!t.exists("live.pid"))
    }

    @Test func theCommandLineIsWhatPsPrints() throws {
        let t = TempFolder("pids"); defer { t.remove() }
        let (w, stdin) = worker(for: "/tmp/with space")
        defer { stop(w, stdin) }
        #expect(WorkerPids.commandLine(w.processIdentifier) == "/bin/sh -c read x palaver live /tmp/with space")
        let ps = Foundation.Process(), out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(w.processIdentifier), "-o", "command="]
        ps.standardOutput = out
        try ps.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(printed.trimmingCharacters(in: .whitespacesAndNewlines) == WorkerPids.commandLine(w.processIdentifier))
        #expect(WorkerPids.commandLine(exitedPid()) == "")
    }

    @Test func worksOnNeedsLiveAndTheSameFolder() throws {
        let t = TempFolder("pids"); defer { t.remove() }
        let link = t.url.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.url)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(WorkerPids.worksOn("/x/palaver live \(t.url.path)", t.url))
        #expect(WorkerPids.worksOn("/x/palaver live \(link.path)  ", t.url))  // symlinks resolve, the path is stripped
        #expect(WorkerPids.worksOn("python -m palaver live /a live \(t.url.path)", t.url))  // the last ` live `
        #expect(!WorkerPids.worksOn("/x/palaver live /somewhere/else", t.url))
        #expect(!WorkerPids.worksOn("/x/palaver process \(t.url.path)", t.url))
        #expect(!WorkerPids.worksOn("/x/palaver live\n", t.url))
    }

    @Test func test_worker_running() {
        let t = TempFolder("pids"); defer { t.remove() }
        // The realtime stream's pid file: any live process of ours will do.
        #expect(!WorkerPids.streamRunning(t.url))
        t.write("stream.pid", String(getpid()))
        #expect(WorkerPids.streamRunning(t.url))
        t.write("stream.pid", "not a pid")
        #expect(!WorkerPids.streamRunning(t.url))
        t.write("stream.pid", String(exitedPid()))
        #expect(!WorkerPids.streamRunning(t.url))
        #expect(t.exists("stream.pid"))  // the stream's pid file is never removed here
    }

    @Test func stopLiveSendsSigtermAndIgnoresWhatIsNotAPid() {
        let t = TempFolder("pids"); defer { t.remove() }
        WorkerPids.stopLive(t.url)  // no file: nothing happens
        t.write("live.pid", "junk")
        WorkerPids.stopLive(t.url)
        t.write("live.pid", "0")
        WorkerPids.stopLive(t.url)  // never a whole process group
        let (w, stdin) = worker(for: t.url.path)
        defer { try? stdin.fileHandleForWriting.close() }
        livePid(t, w.processIdentifier)
        WorkerPids.stopLive(t.url)
        w.waitUntilExit()
        #expect(w.terminationReason == .uncaughtSignal && w.terminationStatus == SIGTERM)
    }
}

@Suite struct LocalOnlyTests {
    @Test func theMarkerSaysSinceWhenAndIsPythonsFormat() throws {
        let t = TempFolder("local"); defer { t.remove() }
        #expect(!LocalOnly.isLocalOnly(t.url))
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        try LocalOnly.set(t.url, on: true, now: Date(timeIntervalSince1970: 1_793_786_400), timeZone: berlin)
        #expect(LocalOnly.isLocalOnly(t.url))
        #expect(t.text("local_only.json") == #"{"since": "2026-11-04T11:00:00+01:00"}"#)  // no indent, no newline
        try LocalOnly.set(t.url, on: true)  // set again: written again
        #expect(WallTime.parse(PythonJSON.read(t.url.appendingPathComponent("local_only.json"))?["since"]?.stringValue) != nil)
        try LocalOnly.set(t.url, on: false)
        #expect(!LocalOnly.isLocalOnly(t.url))
        try LocalOnly.set(t.url, on: false)  // missing_ok
    }

    @Test func theMeetingsKeptOnThisMacAreTheFoldersWithTheMarker() throws {
        let t = TempFolder("local"); defer { t.remove() }
        #expect(LocalOnly.meetings(outputDir: t.url.appendingPathComponent("nope")) == [])
        for name in ["a", "b", "c"] { try FileManager.default.createDirectory(at: t.url.appendingPathComponent(name), withIntermediateDirectories: true) }
        try LocalOnly.set(t.url.appendingPathComponent("a"), on: true)
        try LocalOnly.set(t.url.appendingPathComponent("c"), on: true)
        t.write("local_only.json", "{}")  // a file in the output dir is no meeting
        t.write("b.txt")
        #expect(LocalOnly.meetings(outputDir: t.url) == ["a", "c"])
    }
}

@Suite struct TranscriptionMarkerTests {
    private func paths(_ t: TempFolder) -> RecordingPaths { RecordingPaths(t.url) }

    @Test func aMarkerIsReadWrittenAndKeepsTheOtherTrack() throws {
        let t = TempFolder("marker"); defer { t.remove() }
        #expect(TranscriptionMarker.read(paths(t)) == .object([]))
        try TranscriptionMarker.write(paths(t), track: "system", info: [("engine", .string("live"))])
        try TranscriptionMarker.write(paths(t), track: "mic", info: [("engine", .string("local")), ("note", .string("Straße"))])
        try TranscriptionMarker.write(paths(t), track: "system", info: [("engine", .string("cloud")), ("at", .string("x"))])
        let text = try #require(t.text("transcription.json"))
        #expect(!t.exists("transcription.json.tmp"))
        // indent=2, ensure_ascii=False, "at" last and written over, system keeps its place.
        let data = try #require(PythonJSON.read(paths(t).transcription))
        guard case .object(let tracks) = data else { Issue.record("not an object"); return }
        #expect(tracks.map { $0.0 } == ["system", "mic"])
        #expect(data["system"]?["engine"]?.stringValue == "cloud" && data["mic"]?["note"]?.stringValue == "Straße")
        #expect(text.contains("\"note\": \"Straße\"") && text.hasPrefix("{\n  \"system\": {\n    \"engine\": \"cloud\",\n    \"at\": \""))
        #expect(!text.hasSuffix("\n"))
    }

    @Test func aBrokenOrForeignFileReadsAsEmpty() {
        let t = TempFolder("marker"); defer { t.remove() }
        t.write("transcription.json", "[1, 2]")
        #expect(TranscriptionMarker.read(paths(t)) == .object([]))
        t.write("transcription.json", "{nope")
        #expect(TranscriptionMarker.read(paths(t)) == .object([]))
    }

    @Test func test_wants_cloud() throws {
        let t = TempFolder("marker"); defer { t.remove() }
        let p = paths(t)
        // Not transcribed yet.
        #expect(TranscriptionMarker.wantsCloud(p))
        t.write("system_segments.json", "[]")
        // Transcribed before any of this: left as it is.
        #expect(!TranscriptionMarker.wantsCloud(p))
        // By the live worker during the call: the service replaces it.
        try TranscriptionMarker.write(p, track: "system", info: [("engine", .string("live"))])
        #expect(TranscriptionMarker.wantsCloud(p))
        // By this Mac after the service failed.
        try TranscriptionMarker.write(p, track: "system", info: [("engine", .string("local")), ("fallback_from", .string("cloud"))])
        #expect(TranscriptionMarker.wantsCloud(p))
        // By this Mac, plainly, or by the service.
        try TranscriptionMarker.write(p, track: "system", info: [("engine", .string("local")), ("fallback_from", .null)])
        #expect(!TranscriptionMarker.wantsCloud(p))
        try TranscriptionMarker.write(p, track: "system", info: [("engine", .string("cloud"))])
        #expect(!TranscriptionMarker.wantsCloud(p))
    }
}
