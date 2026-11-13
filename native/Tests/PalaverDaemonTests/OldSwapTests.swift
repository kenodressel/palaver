// The update from 0.3.14, the last Python app, to this Swift app runs 0.3.14's swap.sh: it was written
// by that release and cannot change. It waits for started-ok, and when that does not come it restores
// 0.3.14 while ending only `palaver-launcher`, so a Swift app still running would record next to the
// 0.3.14 app. These tests run that script's text (tests/fixtures/updater_0.3.14/swap.sh.txt, from git
// 8956274) against a fake new bundle whose Contents/MacOS/Palaver is a sleeping script, and check the
// Swift side's two defences: started-ok is written from the bundle's version even when Python never
// answers, and an app whose bundle was put aside quits. Hermetic: a temp folder, a fake `open`, a
// fake `sleep` on PATH that makes the script's 0.2 s waits short and a `pgrep` that looks for the started app only.
// The script's wait for started-ok starts counting once the app ticked (`ticked`): 50 short waits are 10 s on a
// Mac and half a second here, less than a busy machine may take to schedule the test's first tick.
import Darwin
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

/// Python's str.format for the template's `{name}` fields and `{{` `}}`.
func pythonFormat(_ template: String, _ values: [String: String]) -> String {
    var out = ""
    var i = template.startIndex
    while i < template.endIndex {
        let c = template[i]
        let next = template.index(after: i)
        if c == "{" || c == "}", next < template.endIndex, template[next] == c {
            out.append(c)
            i = template.index(after: next)
            continue
        }
        if c == "{", let close = template[next...].firstIndex(of: "}") {
            let name = String(template[next..<close])
            guard let value = values[name] else { fatalError("no value for {\(name)}") }
            out += value
            i = template.index(after: close)
            continue
        }
        out.append(c)
        i = next
    }
    return out
}

private func sh(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func executable(_ url: URL, _ text: String) {
    mkdir(url.deletingLastPathComponent())
    touch(url, text)
    chmod(url.path, 0o755)
}

private func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// The folders and scripts of one swap from 0.3.14 to 0.5.0.
private struct OldSwap {
    let root = tempDir()
    var target: URL { root.appendingPathComponent("Applications/Palaver.app", isDirectory: true) }
    var staged: URL { root.appendingPathComponent("updates/staged/Palaver.app", isDirectory: true) }
    var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    var ok: URL { support.appendingPathComponent("started-ok") }
    var status: URL { support.appendingPathComponent("update.json") }
    var appPid: URL { root.appendingPathComponent("app.pid") }
    /// Written after the app's first tick; the fake `sleep` waits for it.
    var ticked: URL { root.appendingPathComponent("ticked") }

    static let template: String = {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // native/Tests/PalaverDaemonTests
            .appendingPathComponent("../../../tests/fixtures/updater_0.3.14/swap.sh.txt").standardizedFileURL
        return (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
    }()

    /// The two apps, the fakes and swap.sh as 0.3.14's Installer.apply rendered it.
    func make() throws -> URL {
        // 0.3.14: the ObjC launcher as the executable (never started here).
        touch(mkdirThen(target.appendingPathComponent("Contents/Resources/runtime.json")), #"{"version": "0.3.14", "runtime": "rt-1"}"#)
        executable(target.appendingPathComponent("Contents/MacOS/palaver-launcher"), "#!/bin/sh\nexit 0\n")
        // 0.5.0: the Swift app, here a script that runs until it is ended.
        touch(mkdirThen(staged.appendingPathComponent("Contents/Resources/runtime.json")), #"{"version": "0.5.0", "runtime": "rt-1"}"#)
        executable(staged.appendingPathComponent("Contents/MacOS/Palaver"),
                   "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do /bin/sleep 0.05; done\n")
        mkdir(support)
        // `open`: starts the bundle's Contents/MacOS/Palaver when it has one (0.3.14's has not).
        let opener = root.appendingPathComponent("bin/open-app")
        executable(opener, """
            #!/bin/sh
            echo "$1" >> \(sh(root.appendingPathComponent("opened").path))
            if [ -x "$1/Contents/MacOS/Palaver" ]; then
              "$1/Contents/MacOS/Palaver" </dev/null >/dev/null 2>&1 &
              echo $! > \(sh(appPid.path))
            fi

            """)
        // The script's `sleep 0.2` (looked up on PATH), 20 times shorter, from the app's first tick on.
        executable(root.appendingPathComponent("fastbin/sleep"),
                   "#!/bin/sh\nwhile [ ! -e \(sh(ticked.path)) ]; do /bin/sleep 0.01; done\nexec /bin/sleep 0.01\n")
        // Its `pgrep -f "$target/Contents/MacOS/"`: the app `open` started, while it runs. The real one reads every
        // process of the Mac, 150 times in the wait for a new app that never started: 10 to 20 s on a busy Mac.
        executable(root.appendingPathComponent("fastbin/pgrep"),
                   "#!/bin/sh\npid=$(cat \(sh(appPid.path)) 2>/dev/null) && kill -0 \"$pid\" 2>/dev/null\n")
        func failure(_ error: String) -> String {
            #"{"state": "failed", "from_swap": true, "error": "\#(error)", "available": {"version": "0.5.0"}}"#
        }
        #expect(!Self.template.isEmpty, "tests/fixtures/updater_0.3.14/swap.sh.txt")
        let script = pythonFormat(Self.template, [
            "current": "0.3.14", "version": "0.5.0", "version_sh": sh("0.5.0"),
            "pids": "999999",  // the 0.3.14 app, gone already
            "target": sh(target.path), "staged": sh(staged.path),
            "keep": sh(support.appendingPathComponent("previous-app").path), "ok": sh(ok.path), "status": sh(status.path),
            "open": opener.path, "start_ticks": "50",
            "not_replaced": failure("Palaver 0.5.0 could not replace the app; 0.3.14 stays."),
            "did_not_start": failure("Palaver 0.5.0 did not start; 0.3.14 is back."),
        ])
        let url = root.appendingPathComponent("swap.sh")
        touch(url, script)
        return url
    }

    func mkdirThen(_ url: URL) -> URL { mkdir(url.deletingLastPathComponent()); return url }

    func run(_ script: URL) throws -> Foundation.Process {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.environment = ["PATH": root.appendingPathComponent("fastbin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// The pid of the started Swift app, once `open` started it.
    func waitForApp(timeout: Double = 10) -> Int32? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let text = try? String(contentsOf: appPid, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(5_000)
        }
        return nil
    }

    func version(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/runtime.json")) else { return nil }
        return JSONValue.parse(data)?["version"]?.stringValue
    }
}

/// A backend for which `palaver app update status` never answers.
private final class SilentBackend: UpdateBackend, @unchecked Sendable {
    func status() throws -> (installed: UpdateInstalled?, previous: JSONValue?) { throw Boom(description: "no answer") }
    func check() throws -> UpdateCheck { .upToDate }
    func download(version: String, progress: @escaping @Sendable (Int) -> Void) throws {}
    func prepare(waitFor: [Int32]) throws -> String { "" }
    func commit() throws {}
    func spawnSwap(script: String) throws {}
    func uninstallStart(models: Bool, recordings: Bool, waitFor: [Int32]) throws -> [String] { [] }
}

@Suite(.serialized) struct OldSwapTests {
    @Test func theSwiftAppKeepsItselfWhenPythonNeverAnswers() throws {
        let swap = OldSwap()
        let script = try swap.make()
        let process = try swap.run(script)
        let pid = try #require(swap.waitForApp())
        defer { kill(pid, SIGTERM) }
        // The app as main.swift builds its updater: started-ok from the bundle, Python silent.
        let location = AppLocation(executable: swap.target.appendingPathComponent("Contents/MacOS/Palaver"))
        let updates = Updates(.init(backend: SilentBackend(), startedOk: swap.ok, bundleVersion: location.releaseVersion()))
        Thread.detachNewThread { updates.load() }
        let ticker = AppTicker(.init(daemonTick: {}, started: { updates.started() }, startedDone: { updates.startedDone },
                                     refresh: {}, calendarRetry: {}, housekeeping: {}, updates: { false }, quit: {}))
        ticker.tick()  // the first tick
        touch(swap.ticked)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(swap.version(swap.target) == "0.5.0")  // the new app stays
        #expect(!exists(swap.support.appendingPathComponent("previous-app")) && !exists(swap.status))
        #expect(isRunning(pid))
    }

    @Test func anAppWhoseBundleWasPutBackQuitsInsteadOfRecordingNextToTheOldOne() throws {
        let swap = OldSwap()
        let script = try swap.make()
        let process = try swap.run(script)
        let pid = try #require(swap.waitForApp())
        defer { kill(pid, SIGTERM) }
        // This app never writes started-ok (it hangs before its first tick, say): 0.3.14's script restores
        // 0.3.14 and ends only palaver-launcher. The tick's bundle check must end this app.
        let watch = try #require(BundleWatch(bundle: swap.target))
        final class Quit: @unchecked Sendable { var at: Date?; var wasAlive = false }
        let quit = Quit()
        let ticker = AppTicker(.init(daemonTick: {}, started: {}, startedDone: { true }, refresh: {}, calendarRetry: {},
                                     housekeeping: {}, updates: { false },
                                     quit: { quit.at = Date(); quit.wasAlive = isRunning(pid); kill(pid, SIGTERM) },
                                     bundleReplaced: { watch.replaced() }))
        // Until the script ends: its waits are 200 starts of `sleep` (50 for started-ok, 150 for the app to go), a few
        // seconds on a Mac, far longer when every core is busy.
        let end = Date().addingTimeInterval(180)
        while process.isRunning && Date() < end {
            ticker.tick()
            touch(swap.ticked)
            usleep(20_000)
        }
        #expect(!process.isRunning)
        ticker.tick()
        #expect(quit.at != nil && quit.wasAlive)  // 0.3.14's pkill left it running: the watch ended it
        #expect(swap.version(swap.target) == "0.3.14")
        let status = try String(contentsOf: swap.status, encoding: .utf8)
        #expect(status.contains("did not start"))
        usleep(200_000)
        #expect(!isRunning(pid))
    }
}
