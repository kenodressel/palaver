// Where the app runs and what it starts with: options, the bundle or a checkout, the version, the programs it
// starts, the temp-folder sweep, the single-instance check and the crash log's header.
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

/// A checkout: its VERSION file and native/Package.swift.
private func checkout(_ root: URL, version: String) {
    write(root.appendingPathComponent("VERSION"), version + "\n")
    write(root.appendingPathComponent("native/Package.swift"), "// swift-tools-version: 6.0\n")
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

    @Test func aBundleHasNoPythonAtAllAndItsVersionIsItsRuntimeJson() {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.6.0rc1", "runtime": "no-python-1"}"#)
        let loc = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        #expect(loc.bundle?.path == app.path && loc.checkout == nil)
        #expect(loc.version() == "0.6.0rc1")
    }

    @Test func theHomeIsPalaverHomeElseHomeElseTheAccounts() {
        #expect(Paths.home(environment: ["PALAVER_HOME": "/tmp/p", "HOME": "/tmp/h"]).path == "/tmp/p")
        #expect(Paths.home(environment: ["PALAVER_HOME": "", "HOME": "/tmp/h"]).path == "/tmp/h")
        #expect(Paths.home(environment: [:]) == FileManager.default.homeDirectoryForCurrentUser)
        // config.toml's `~` is that home.
        let config = Config(toml: "[recording]\noutput_dir = \"~/rec\"\n", environment: ["PALAVER_HOME": "/tmp/p", "HOME": "/tmp/h"])
        #expect(config.outputDir.path == "/tmp/p/rec")
        #expect(Config(toml: "", environment: ["PALAVER_HOME": "/tmp/p"]).outputDir.path == "/tmp/p/Meetings/Recordings")
    }

    @Test func thePalaverCommandInResourcesBinIsInsideTheBundleAlsoThroughALink() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.6.0"}"#)
        let cli = app.appendingPathComponent("Contents/Resources/bin/palaver")
        write(cli, "")
        let loc = AppLocation(executable: cli)
        #expect(loc.bundle?.path == app.path && loc.checkout == nil && loc.version() == "0.6.0")
        // ~/.local/bin/palaver, as install.sh links it.
        let link = root.appendingPathComponent("local/bin/palaver")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        #expect(AppLocation(executable: link).bundle?.path == app.path)
        // Another bin folder is no bundle.
        #expect(AppLocation(executable: root.appendingPathComponent("Other/Resources/bin/palaver")).bundle == nil)
    }

    @Test func aDevelopmentBuildFindsItsCheckoutAndReadsItsVersionFile() {
        let repo = temp()
        checkout(repo, version: "0.4.9")
        let exe = repo.appendingPathComponent("native/.build/arm64-apple-macosx/release/Palaver")
        let loc = AppLocation(executable: exe)
        #expect(loc.bundle == nil && loc.checkout?.path == repo.path)
        #expect(loc.version() == "0.4.9")
        let nowhere = AppLocation(executable: URL(fileURLWithPath: "/nonexistent-\(UUID())/Palaver"))
        #expect(nowhere.bundle == nil && nowhere.checkout == nil && nowhere.version() == "?")
        // A VERSION file alone is no checkout.
        let other = temp()
        write(other.appendingPathComponent("VERSION"), "1.0\n")
        #expect(AppLocation(executable: other.appendingPathComponent("bin/Palaver")).checkout == nil)
    }

    @Test func aReleaseWithoutRuntimeJsonReadsInfoPlist() throws {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.5.0"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let loc = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        #expect(loc.version() == "0.5.0")
    }

    @Test func theSwiftProgramsAreTheBundlesTheCheckoutsBuildOrTheOverride() throws {
        let app = URL(fileURLWithPath: "/Applications/Palaver.app", isDirectory: true)
        let bundled = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        #expect(bundled.binary("palaver-worker", environment: [:], fileExists: { _ in true })
                == "/Applications/Palaver.app/Contents/MacOS/palaver-worker")
        #expect(bundled.binary("palaver-worker", environment: [:], fileExists: { _ in false }) == nil)
        #expect(bundled.binary("palaver-server", environment: ["PALAVER_SERVER_BIN": "/x/palaver-server"], fileExists: { _ in true })
                == "/x/palaver-server")
        #expect(bundled.staticDir()?.path == "/Applications/Palaver.app/Contents/Resources/web")

        let root = temp()
        checkout(root, version: "0.5.0rc4")
        let dev = AppLocation(executable: root.appendingPathComponent("native/.build/debug/Palaver"))
        let release = root.appendingPathComponent("native/.build/release/palaver-server").path
        let debug = root.appendingPathComponent("native/.build/debug/palaver-server").path
        #expect(dev.binary("palaver-server", environment: [:], fileExists: { $0 == release }) == release)
        #expect(dev.binary("palaver-server", environment: [:], fileExists: { $0 == debug }) == debug)
        #if DEBUG
        #expect(dev.binary("palaver-server", environment: [:], fileExists: { $0 == debug || $0 == release }) == debug)  // its own build
        #endif
        #expect(dev.staticDir() == root.appendingPathComponent("web", isDirectory: true))
        #expect(AppLocation(executable: URL(fileURLWithPath: "/nowhere/bin/Palaver"), fileExists: { _ in false })
                    .binary("palaver-worker", environment: [:], fileExists: { _ in true }) == nil)
    }

    @Test func everyProgramIsTheBundlesAlsoWhenMissing() {
        let app = URL(fileURLWithPath: "/Applications/Palaver.app", isDirectory: true)
        let bundled = AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver"))
        let all = AppPrograms.find(location: bundled, environment: [:], isExecutable: { _ in true })
        #expect(all.server == app.path + "/Contents/MacOS/palaver-server" && all.worker == app.path + "/Contents/MacOS/palaver-worker")
        #expect(all.lm == app.path + "/Contents/MacOS/palaver-lm" && all.said.isEmpty)
        // A program missing from the bundle is still the bundle's: its start fails and says where.
        let missing = AppPrograms.find(location: bundled, environment: [:], isExecutable: { !$0.hasSuffix("palaver-lm") })
        #expect(missing.lm == app.path + "/Contents/MacOS/palaver-lm" && missing.said == ["palaver-lm is missing (\(missing.lm))"])
    }

    @Test func inACheckoutTheProgramsAreItsBuilds() {
        let repo = temp()
        checkout(repo, version: "0.6.0")
        let dev = AppLocation(executable: repo.appendingPathComponent("native/.build/debug/Palaver"))
        let found = AppPrograms.find(location: dev, environment: [:], isExecutable: { _ in true })
        #expect(found.server.hasPrefix(repo.path + "/native/.build/") && found.server.hasSuffix("/palaver-server"))
        #expect(found.worker.hasSuffix("/palaver-worker") && found.lm.hasSuffix("/palaver-lm") && found.said.isEmpty)
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

@Suite struct BundleWatchTests {
    @Test func theReleaseVersionIsTheBundlesOnly() {
        let root = temp()
        let app = root.appendingPathComponent("Palaver.app", isDirectory: true)
        write(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "0.5.0"}"#)
        #expect(AppLocation(executable: app.appendingPathComponent("Contents/MacOS/Palaver")).releaseVersion() == "0.5.0")
        checkout(root, version: "0.4.9")
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
