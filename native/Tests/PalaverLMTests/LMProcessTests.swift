// palaver-lm the program (this package's debug build, beside the tests) with the Claude Code CLI as its model: the CLI
// ends when palaver-lm's process group is killed (the window's Cancel, the daemon's killpg) and when palaver-lm alone
// gets SIGTERM; a CLI that quits without reading a long prompt is a reported failure, not death by SIGPIPE.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain
@testable import PalaverLM
import Testing

/// palaver-lm, built with the tests (swift build --build-tests).
let LM_BINARY = builtProgram("palaver-lm")

/// A program built with this test bundle: next to it in the products folder of whichever build ran the tests
/// (native/.build/test/debug for `make test`, native/.build/debug for `swift test`).
func builtProgram(_ name: String) -> String {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let file = info.dli_fname else { return name }
    var url = URL(fileURLWithPath: String(cString: file))  // <products>/<Bundle>.xctest/Contents/MacOS/<Bundle>
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(name).path
}

@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: LM_BINARY))) struct LMProcessTests {
    /// A home whose notes run on the Claude Code CLI `script`; palaver-lm started on its meeting in a session of its own.
    func start(_ home: Home, _ paths: RecordingPaths, script: String, output: URL) throws -> PalaverCore.Process {
        home.config.claudePath = script
        try home.settings.choose("notes", .string("claude-cli"))
        let config = home.dir.appendingPathComponent("config.toml")
        try "[notes]\nclaude = \"\(script)\"\n".write(to: config, atomically: true, encoding: .utf8)
        let fd = open(output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        defer { close(fd) }
        let env = ["XDG_CONFIG_HOME": home.stores.configDir.deletingLastPathComponent().path,
                   "PALAVER_HOME": home.stores.home.path, "PATH": "/usr/bin:/bin",
                   "PALAVER_TEST_KEYSTORE": home.dir.appendingPathComponent("keychain.json").path]
        return try spawnChild([LM_BINARY, "--config", config.path, "--no-notify", "notes", paths.folder.path], env: env,
                              output: fd, newSession: true)
    }

    func gone(_ pid: pid_t, within seconds: Double = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(50_000)
        }
        return false
    }

    @Test(arguments: ["group", "alone"]) func theCLIEndsWithPalaverLM(_ how: String) throws {
        let home = Home()
        let paths = home.meeting()
        let seen = home.dir.appendingPathComponent("seen")
        let script = home.dir.appendingPathComponent("claude")
        try "#!/bin/sh\ncat > /dev/null\necho $$ > \(seen.path)\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let lm = try start(home, paths, script: script.path, output: home.dir.appendingPathComponent("lm.log"))
        defer { lm.signalGroup(SIGKILL) }
        let deadline = Date().addingTimeInterval(20)
        var claude: pid_t?
        while claude == nil && Date() < deadline {
            claude = (try? String(contentsOf: seen, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            usleep(50_000)
        }
        let pid = try #require(claude, "the fake claude never started: \((try? String(contentsOf: home.dir.appendingPathComponent("lm.log"), encoding: .utf8)) ?? "")")
        #expect(getpgid(pid) == lm.pid)  // in palaver-lm's group
        if how == "group" { killpg(lm.pid, SIGTERM) } else { kill(lm.pid, SIGTERM) }
        #expect(lm.waitUntilExit(timeout: 10) != nil)
        #expect(gone(pid))
    }

    @Test func aCLIThatQuitsWithoutReadingALongPromptIsAFailureItReports() throws {
        let home = Home()
        let long = (0..<1500).map { utterance($0 % 2 == 0 ? "Timo Strauß" : "SPEAKER_01", Double($0 * 5),
                                              "Wir sprechen über das Angebot für Contoso und den Preis für Northwind.") }
        let paths = home.meeting(MEETING, long)
        let script = home.dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 'Please run /login' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let log = home.dir.appendingPathComponent("lm.log")
        let lm = try start(home, paths, script: script.path, output: log)
        let code = lm.waitUntilExit(timeout: 30)
        let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(code == 1, "\(said)")
        #expect(lm.terminationSignal == nil)
        #expect(said.contains("before it read the prompt: Please run /login"))
        #expect(home.events(paths).last?["event"] == .string("notes_failed"))
    }
}
