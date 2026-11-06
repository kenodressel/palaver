// Where the app runs and what it starts with: options, the bundle or a checkout, the workers'
// python, the version, the legacy fallback, the temp-folder sweep, the single-instance check, the
// crash log's header, and the fallback's launcher (a fake menu bar app, no real one).
import Darwin
import Foundation
import Testing
@testable import PalaverCore

private func temp() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-env-\(getpid())-\(UUID().uuidString.prefix(8))",
                                                                            isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

private func write(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite struct AppEnvironmentTests {
    @Test func theOptionsAreTheCommandsGlobalOnesAndAnythingElseIsIgnored() {
        #expect(AppOptions.parse([]) == AppOptions())
        #expect(AppOptions.parse(["--config", "~/c.toml", "--dictionary", "/d.txt", "--no-notify"])
                == AppOptions(config: "~/c.toml", dictionary: "/d.txt", noNotify: true))
        #expect(AppOptions.parse(["-psn_0_12345", "--config=/c.toml", "-NSDocumentRevisionsDebugMode", "YES"])
                == AppOptions(config: "/c.toml"))
        #expect(AppOptions.parse(["--config"]) == AppOptions())  // no value: nothing
    }

    @Test func insideABundleTheWorkersRunItsPythonHostAndTheVersionIsItsRuntimeJson() {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.5.0", "runtime": "3.13.18-arm64-abc"}"#)
        let loc = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        #expect(loc.bundle?.path == app.path && loc.checkout == nil)
        #expect(loc.python(environment: [:]) == app.path + "/Contents/MacOS/palaver-python")
        #expect(loc.python(environment: ["PALAVER_PYTHON": "/x/python"]) == "/x/python")
        #expect(loc.version() == "0.5.0")
    }

    @Test func aDevelopmentBuildRunsTheCheckoutsVenvAndReadsItsVersion() {
        let repo = temp()
        write(repo.appendingPathComponent("palaver/__init__.py"), "\"\"\"Palaver.\"\"\"\n\n__version__ = \"0.4.9\"\n")
        let exe = repo.appendingPathComponent("native/.build/arm64-apple-macosx/release/Palaver")
        let loc = AppLocation(executable: exe)
        #expect(loc.bundle == nil && loc.checkout?.path == repo.path)
        #expect(loc.python(environment: [:]) == repo.path + "/.venv/bin/python")
        #expect(loc.version() == "0.4.9")
        #expect(loc.runtimePython(home: repo) == nil)  // no runtime to check outside a release
        let nowhere = AppLocation(executable: URL(fileURLWithPath: "/nonexistent-\(UUID())/Palaver"))
        #expect(nowhere.bundle == nil && nowhere.checkout == nil && nowhere.version() == "?")
        #expect(nowhere.python(environment: [:]) == "python3")
    }

    @Test func aReleaseChecksTheRuntimeItWasBuiltFor() throws {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["PalaverRuntimeID": "3.13.18-arm64-abc", "CFBundleShortVersionString": "0.5.0"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let loc = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        #expect(loc.runtimePython(home: root)?.path
                == root.path + "/Library/Application Support/palaver/runtime/3.13.18-arm64-abc/bin/python3")
        #expect(loc.version() == "0.5.0")  // no runtime.json: Info.plist's
    }

    @Test func theLegacyAppIsChosenByTheEnvironmentOrTheMarkerFile() {
        let support = temp()
        #expect(!LegacyApp.wanted(environment: [:], support: support))
        #expect(LegacyApp.wanted(environment: ["PALAVER_LEGACY_APP": "1"], support: support))
        #expect(!LegacyApp.wanted(environment: ["PALAVER_LEGACY_APP": "0"], support: support))
        write(support.appendingPathComponent("legacy-app"), "")
        #expect(LegacyApp.wanted(environment: [:], support: support))
        #expect(LegacyApp.argv(python: "/A/Contents/MacOS/palaver-python", cliOptions: ["--config", "/c.toml"])
                == ["/A/Contents/MacOS/palaver-python", "-m", "palaver", "--config", "/c.toml", "menubar"])
    }

    @Test func theSweepRemovesOnlyTheNotifyFilesOfGoneProcesses() throws {
        let dir = temp()
        let names = ["palaver-111.sock", "palaver-111.notifications", "palaver-111.notifications.tmp",  // gone
                     "palaver-222.sock", "palaver-222.notifications",  // alive
                     "palaver-333.sock",  // this process
                     "palaver-test-recording-ab12", "palaver-111.log", "palaver-x.sock", "other-111.sock"]
        for n in names { write(dir.appendingPathComponent(n), "") }
        let removed = TempSweep.sweep(dir, myPid: 333, alive: { $0 == 222 })
        #expect(removed == ["palaver-111.notifications", "palaver-111.notifications.tmp", "palaver-111.sock"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == names.filter { !$0.hasPrefix("palaver-111.") || $0 == "palaver-111.log" }.sorted())
    }

    @Test func anotherLiveAppInDaemonJsonIsReportedNeverThisOneOrAStoppedOne() throws {
        let dir = temp()
        let state = dir.appendingPathComponent("daemon.json")
        #expect(RunningApp.other(stateFile: state, myPid: 1, alive: { _ in true }) == nil)  // no file
        func put(_ obj: [String: Any]) throws { try JSONSerialization.data(withJSONObject: obj).write(to: state) }
        try put(["state": "idle", "pid": 4242])
        #expect(RunningApp.other(stateFile: state, myPid: 1, alive: { $0 == 4242 }) == 4242)
        #expect(RunningApp.other(stateFile: state, myPid: 1, alive: { _ in false }) == nil)  // gone or another program
        #expect(RunningApp.other(stateFile: state, myPid: 4242, alive: { _ in true }) == nil)  // this process
        try put(["state": "stopped", "pid": 4242])
        #expect(RunningApp.other(stateFile: state, myPid: 1, alive: { _ in true }) == nil)
        try put(["state": "recording", "pid": true])
        #expect(RunningApp.other(stateFile: state, myPid: 1, alive: { _ in true }) == nil)
    }

    @Test func theCrashLogsHeaderSaysWhoCrashedAsPythonsDoes() {
        let line = CrashLog.header(where: "palaver app", version: "0.5.0", pid: 77, argv: ["--no-notify"],
                                   now: Date(timeIntervalSince1970: 0))
        #expect(line.hasPrefix("=== "))
        #expect(line.hasSuffix(" palaver app pid 77 palaver 0.5.0 argv ['--no-notify']\n"))
    }
}

// The fallback's launcher, with a fake menu bar app (a shell script), as test_app_bundle.py tested
// the ObjC launcher: the command, the click socket, a forwarded signal, the exit code.
@Suite(.serialized) struct LegacyLauncherTests {
    func fakeApp(_ dir: URL, _ body: String) -> URL {
        let script = dir.appendingPathComponent("fake python")  // a path with a space
        write(script, "#!/bin/sh\n" + body)
        chmod(script.path, 0o755)
        return script
    }

    func waitFor(_ url: URL, _ seconds: Double = 10) -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let s = try? String(contentsOf: url, encoding: .utf8), s.hasSuffix("\n") { return s }
            usleep(20_000)
        }
        return nil
    }

    @Test func itStartsTheMenuBarAppWithItsOutputInTheLogAndReturnsItsExitCode() throws {
        let dir = temp()
        let marker = dir.appendingPathComponent("args.txt")
        let fake = fakeApp(dir, "echo \"$@|$PALAVER_NOTIFY|${PALAVER_LAUNCHER_FD:-none}\" > '\(marker.path)'\necho said\nexit 3\n")
        let log = dir.appendingPathComponent("logs/app.log")
        let launcher = try LegacyLauncher(argv: LegacyApp.argv(python: fake.path, cliOptions: ["--config", "/x y/c.toml"]),
                                          env: ["PALAVER_NOTIFY": "/t/palaver-1.sock"], log: log, clicks: false)
        #expect(launcher.wait() == 3)
        #expect(waitFor(marker) == "-m palaver --config /x y/c.toml menubar|/t/palaver-1.sock|none\n")
        #expect(try String(contentsOf: log, encoding: .utf8) == "said\n")
    }

    @Test func aClickReachesTheAppThroughTheFdInItsEnvironment() throws {
        let dir = temp()
        let marker = dir.appendingPathComponent("click.txt")
        // dd reads one datagram from the inherited socket.
        let fake = fakeApp(dir, "eval \"dd bs=200 count=1 <&$PALAVER_LAUNCHER_FD 2>/dev/null\" > '\(marker.path).part'\n"
                                + "printf '\\n' >> '\(marker.path).part'; mv '\(marker.path).part' '\(marker.path)'\n")
        let launcher = try LegacyLauncher(argv: [fake.path], env: [:], log: dir.appendingPathComponent("app.log"), clicks: true)
        launcher.open("2026-10-30T08-02-13")
        #expect(waitFor(marker) == "open 2026-10-30T08-02-13\n")
        #expect(launcher.wait() == 0)
    }

    @Test func aSignalToTheAppIsPassedOnAndItsExitBecomesTheApps() throws {
        let dir = temp()
        let ready = dir.appendingPathComponent("ready.txt")
        let fake = fakeApp(dir, "trap 'exit 7' USR2\necho up > '\(ready.path)'\nwhile :; do sleep 0.05; done\n")
        let launcher = try LegacyLauncher(argv: [fake.path], env: [:], log: dir.appendingPathComponent("app.log"), clicks: false)
        launcher.forwardSignals([SIGUSR2])  // the app forwards TERM, INT and HUP; USR2 keeps this test process safe
        defer { launcher.stopForwarding() }
        #expect(waitFor(ready) == "up\n")
        kill(getpid(), SIGUSR2)
        #expect(launcher.wait() == 7)
    }
}

@Suite struct BundleWatchTests {
    @Test func theReleaseVersionIsTheBundlesOnly() {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.5.0"}"#)
        #expect(AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver")).releaseVersion() == "0.5.0")
        write(root.appendingPathComponent("palaver/__init__.py"), "__version__ = \"0.4.9\"\n")
        #expect(AppLocation(executable: root.appendingPathComponent("native/.build/release/Palaver")).releaseVersion() == nil)
        let bare = root.appendingPathComponent("Bare.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: bare.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(AppLocation(executable: bare.appendingPathComponent("Contents/MacOS/Palaver")).releaseVersion() == nil)
    }

    @Test func aBundleMovedAsideOrReplacedIsSeen() throws {
        let root = temp()
        let fm = FileManager.default
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.5.0"}"#)
        let watch = try #require(BundleWatch(bundle: app))
        #expect(!watch.replaced())
        try fm.moveItem(at: app, to: root.appendingPathComponent("failed.app"))
        #expect(watch.replaced())  // gone
        let old = root.appendingPathComponent("previous/Palaver.app", isDirectory: true)
        write(old.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.3.14"}"#)
        try fm.moveItem(at: old, to: app)
        #expect(watch.replaced())  // another app at the same path
        #expect(BundleWatch(bundle: nil) == nil)
        #expect(BundleWatch(bundle: root.appendingPathComponent("Nowhere.app")) == nil)
    }
}

@Suite struct InstanceLockTests {
    @Test func aSecondAppIsRefusedWhileTheFirstHoldsTheLock() throws {
        let file = temp().appendingPathComponent("app.lock")
        let first = try #require(InstanceLock(file))
        #expect(InstanceLock(file) == nil)  // flock is per open file: a second open in this process is refused too
        // Another process trying it: refused as well.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        probe.arguments = ["-e", #"use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or exit 2; exit(flock(F, LOCK_EX | LOCK_NB) ? 0 : 1)"#,
                           file.path]
        try probe.run()
        probe.waitUntilExit()
        #expect(probe.terminationStatus == 1)  // held
        first.release()
        let again = InstanceLock(file)
        #expect(again != nil)  // released (also at exit: the kernel drops it with the descriptor)
        again?.release()
    }
}
