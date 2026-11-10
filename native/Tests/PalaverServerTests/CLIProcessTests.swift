// The built `palaver` command (native/.build/debug/palaver-cli) as a person or the old installer's link starts it:
// help through `~/.local/bin/palaver`, a command of earlier versions, `daemon status`, `app ping` against a fake app
// socket, and the pipeline's commands starting the bundle's palaver-worker and palaver-lm (fakes that say what they
// got) with its exit code. Temporary homes under /tmp (a socket's path holds 104 bytes): never the real home or app.
import Darwin
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

/// native/.build/debug/palaver-cli (built with the tests).
private let cliBinary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/palaver-cli").path

/// A home under /tmp with config.toml (its own recordings) and a copy of palaver-cli in a fake Palaver.app, linked
/// from `~/.local/bin/palaver` as install.sh links it.
private final class Installed {
    let dir: URL
    let home: URL
    let app: URL
    let link: URL
    let config: URL

    init() throws {
        var template = Array("/tmp/pvcliXXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        dir = URL(fileURLWithPath: String(cString: made!), isDirectory: true).resolvingSymlinksInPath()
        home = dir.appendingPathComponent("h", isDirectory: true)
        app = dir.appendingPathComponent("Palaver.app", isDirectory: true)
        link = home.appendingPathComponent(".local/bin/palaver")
        config = dir.appendingPathComponent("config.toml")
        let bin = app.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: cliBinary, toPath: bin.appendingPathComponent("palaver").path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("palaver"))
        try Data("[recording]\noutput_dir = \"\(dir.appendingPathComponent("rec").path)\"\n".utf8).write(to: config)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var support: URL { home.appendingPathComponent("Library/Application Support/palaver", isDirectory: true) }

    /// A fake program of the bundle: prints its arguments, then exits `code`.
    func fake(_ name: String, exit code: Int32) throws {
        let url = app.appendingPathComponent("Contents/MacOS/\(name)")
        try Data("#!/bin/sh\necho \"\(name)\" \"$@\"\nexit \(code)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
    }

    func run(_ args: [String], program: String? = nil) throws -> (status: Int32, out: String, err: String) {
        let env = ["PALAVER_HOME": home.path, "HOME": home.path, "XDG_CONFIG_HOME": dir.appendingPathComponent("cfg").path,
                   "PATH": "/usr/bin:/bin", "PALAVER_TEST_QUIET_MAC": "1"]
        let ran = try McpSetup.runCommand([program ?? link.path] + args, env: env, timeout: 30)
        return (ran.status, ran.out, ran.err)
    }
}

@Suite(.serialized) struct CLIProcessTests {
    @Test func helpRunsThroughTheLinkTheOldInstallersMadeAndListsTheCommands() throws {
        let p = try Installed()
        let r = try p.run(["--help"])
        #expect(r.status == 0 && r.err.isEmpty)
        for name in Usage.CLI_COMMANDS { #expect(r.out.contains("\n  \(name) "), "\(name)") }
    }

    @Test func aCommandOfEarlierVersionsSaysWhatReplacesItAndExits2() throws {
        let p = try Installed()
        let r = try p.run(["record", "--run"])
        #expect(r.status == 2 && r.out.isEmpty)
        #expect(r.err == "palaver record is gone: Palaver.app records (its menu: Start recording now; calls on their own).\n")
    }

    @Test func daemonStatusReadsTheAppsDaemonJson() throws {
        let p = try Installed()
        #expect(try p.run(["daemon", "status"]).out == "daemon has never run\n")
        try FileManager.default.createDirectory(at: p.support, withIntermediateDirectories: true)
        try Data(#"{"pid": 999999, "state": "idle", "updated": "2026-11-08T09:00:00+01:00"}"#.utf8)
            .write(to: p.support.appendingPathComponent("daemon.json"))
        let r = try p.run(["daemon", "status"])
        #expect(r.status == 0 && r.out == "daemon not running (last update 2026-11-08T09:00:00+01:00)\n")
    }

    @Test func appPingAsksTheRunningAppOnAppSock() throws {
        let p = try Installed()
        try FileManager.default.createDirectory(at: p.support, withIntermediateDirectories: true)
        let socket = p.support.appendingPathComponent("app.sock")
        let app = FakeAppSocket(socket) { name, _ in name == "ping" ? .ok(.object([("pid", .int(4242))])) : .failed("?") }
        defer { app.stop() }
        let r = try p.run(["app", "ping"])
        #expect(r.status == 0 && r.out == "Palaver answers on \(socket.path) (pid 4242).\n")
        #expect(app.calls.map(\.0) == ["ping"])
    }

    @Test func thePipelinesCommandsBecomeTheBundlesWorkerAndLanguageModelWithTheirExitCode() throws {
        let p = try Installed()
        try p.fake("palaver-worker", exit: 4)
        try p.fake("palaver-lm", exit: 75)
        let process = try p.run(["--config", p.config.path, "--no-notify", "process", "/r/f", "--no-notes"])
        #expect(process.status == 4 && process.out == "palaver-worker --config \(p.config.path) --no-notify process /r/f --no-notes\n")
        let projects = try p.run(["projects", "suggest", "--no-wait"])
        #expect(projects.status == 75 && projects.out == "palaver-lm projects --no-wait suggest\n")
        // Started from the bundle's own bin/palaver too.
        let notes = try p.run(["notes", "/r/f"], program: p.app.appendingPathComponent("Contents/Resources/bin/palaver").path)
        #expect(notes.status == 75 && notes.out == "palaver-lm notes /r/f\n")
    }

    /// `$HOME` alone (no PALAVER_HOME, no XDG_CONFIG_HOME) is the home, as for Python: its config.toml (`~` in it
    /// is that home) and its recordings, never the account's.
    @Test func homeAloneIsTheHomeOfTheConfigAndTheRecordings() throws {
        let p = try Installed()
        let env = ["HOME": p.home.path, "PATH": "/usr/bin:/bin"]
        func list() throws -> String { try McpSetup.runCommand([p.link.path, "list"], env: env, timeout: 30).out }
        #expect(try list() == "(no recordings yet)\n")
        let rec = p.home.appendingPathComponent("Meetings/Recordings/2026-10-27T16-03-07", isDirectory: true)
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        #expect(try list() == "2026-10-27T16-03-07  incomplete\n")
        let config = p.home.appendingPathComponent(".config/palaver/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[recording]\noutput_dir = \"~/elsewhere\"\n".utf8).write(to: config)
        try FileManager.default.createDirectory(at: p.home.appendingPathComponent("elsewhere/2026-11-01T09-00-00"),
                                                withIntermediateDirectories: true)
        #expect(try list() == "2026-11-01T09-00-00  incomplete\n")
    }

    @Test func doctorRunsTheChecksOfTheServersLibrary() throws {
        let p = try Installed()
        let r = try p.run(["--config", p.config.path, "doctor", "--offline"])
        #expect([0, 1].contains(r.status) && r.out.contains("macOS: 15.1") && r.out.contains("Config"))
        #expect(r.out.hasSuffix("All set.\n") || r.out.hasSuffix("problem(s) to fix.\n"))
    }
}
