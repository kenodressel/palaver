// The updater without Python (phase 4 batch 9): the manifest, the plan, downloads and staging against a local stub
// release (file://), swap.sh run in a temp home with a fake `open` and fake pids, the uninstall script, and the
// old runtime's cleanup with each of its preconditions. Hermetic: temp folders only, no network, the real app is
// never started.
import Darwin
import Foundation
import Testing
import PalaverCore
@testable import PalaverDaemon

private let zeroSha = String(repeating: "0", count: 64)

private func manifestJSON(version: String = "0.6.1", app: [String: Any]? = nil, runtime: Bool = true,
                          extra: [String: Any] = [:]) -> Data {
    var obj: [String: Any] = ["schema": 1, "version": version, "minimum_macos": "15.0", "arch": "arm64",
                              "app": app ?? ["name": "palaver-app-\(version).zip", "url": "https://example.invalid/a.zip",
                                             "size": 12, "sha256": zeroSha],
                              "models": []]
    if runtime {
        obj["runtime"] = ["id": "no-python-1", "name": "palaver-runtime-no-python-1.tar.gz",
                          "url": "https://example.invalid/r.tar.gz", "size": 300, "sha256": zeroSha]
    }
    for (k, v) in extra { obj[k] = v }
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func sha256(_ url: URL) -> String {
    let p = Foundation.Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256", url.path]
    let out = Pipe()
    p.standardOutput = out
    try! p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return String(text.prefix(64))
}

private func executable(_ url: URL, _ text: String) {
    mkdir(url.deletingLastPathComponent())
    touch(url, text)
    chmod(url.path, 0o755)
}

/// A Palaver.app that is only its runtime.json (and an executable stand-in that is never started).
private func fakeBundle(_ app: URL, version: String, runtime: String = "no-python-1") {
    mkdir(app.appendingPathComponent("Contents/Resources"))
    touch(app.appendingPathComponent("Contents/Resources/runtime.json"), #"{"version": "\#(version)", "runtime": "\#(runtime)"}"#)
    executable(app.appendingPathComponent("Contents/MacOS/Palaver"), "#!/bin/sh\nexit 0\n")
}

@Suite struct ReleaseManifestTests {
    @Test func aManifestIsReadWithOrWithoutItsRuntimeBlock() throws {
        let with = try ReleaseManifest.parse(manifestJSON())
        let without = try ReleaseManifest.parse(manifestJSON(runtime: false))
        #expect(with == without)
        #expect(with.version == "0.6.1" && with.app.size == 12 && with.minimumMacos == "15.0" && with.notes == nil)
        let noted = try ReleaseManifest.parse(manifestJSON(extra: ["notes": "Faster notes."]))
        #expect(noted.notes == "Faster notes.")
    }

    @Test func aBrokenManifestSaysWhatIsWrong() {
        func refused(_ data: Data, _ why: String) {
            do { _ = try ReleaseManifest.parse(data); Issue.record("accepted: \(why)") } catch {
                #expect("\(error)".contains(why), "\(error)")
            }
        }
        let app: [String: Any] = ["name": "a.zip", "url": "https://example.invalid/a.zip", "size": 1, "sha256": zeroSha]
        func with(_ key: String, _ value: Any) -> [String: Any] { var a = app; a[key] = value; return a }
        refused(manifestJSON(app: with("sha256", "abc")), "bad sha256")
        refused(manifestJSON(app: with("sha256", String(repeating: "A", count: 64))), "bad sha256")
        refused(manifestJSON(app: with("name", "../Palaver.app")), "bad file name")
        refused(manifestJSON(app: with("url", "http://example.invalid/a.zip")), "bad url")
        refused(manifestJSON(app: with("size", 1.5)), "bad size")
        refused(manifestJSON(app: with("size", true)), "bad size")
        refused(manifestJSON(app: with("size", -1)), "bad size")
        refused(manifestJSON(version: "latest"), "bad version")
        refused(manifestJSON(extra: ["schema": 2]), "unknown schema")
        refused(manifestJSON(extra: ["app": "x"]), "app: missing")
        refused(Data("{".utf8), "not JSON")
        refused(Data("[1]".utf8), "not a JSON object")
    }

    @Test func versionsCompareAsNumbersWithCandidatesBeforeTheirRelease() {
        #expect(ReleaseVersion.isNewer("0.6.0rc1", than: "0.5.0rc6"))
        #expect(ReleaseVersion.isNewer("0.6.0", than: "0.6.0rc2"))
        #expect(ReleaseVersion.isNewer("0.6.0rc10", than: "0.6.0rc9"))
        #expect(ReleaseVersion.isNewer("0.10.0", than: "0.9.9"))
        #expect(ReleaseVersion.isNewer("0.6.0.1", than: "0.6.0"))
        #expect(!ReleaseVersion.isNewer("0.6.0", than: "0.6"))
        #expect(!ReleaseVersion.isNewer("0.3.14", than: "0.6.0rc1"))
        #expect(ReleaseVersion.isNewer("v0.6.1", than: "0.6.0"))
        #expect(ReleaseVersion.macosOK(minimum: "15.0", macos: "26.0.1") && !ReleaseVersion.macosOK(minimum: "15.4", macos: "15.3.2"))
    }

    @Test func thePlanIsTheAppAloneAndOnlyForANewerReleaseThisMacRuns() throws {
        let m = try ReleaseManifest.parse(manifestJSON())
        #expect(try UpdatePlanner.plan(installed: "0.6.1", manifest: m, macos: "15.6") == nil)
        #expect(try UpdatePlanner.plan(installed: "0.6.2", manifest: m, macos: "15.6") == nil)
        let plan = try #require(try UpdatePlanner.plan(installed: "0.5.0rc6", manifest: m, macos: "15.6"))
        #expect(plan == UpdatePlan(version: "0.6.1", downloadBytes: 12, runtime: false, models: []))
        var newer = m
        newer.minimumMacos = "27.0"
        #expect(throws: ManifestError.self) { try UpdatePlanner.plan(installed: "0.6.0", manifest: newer, macos: "15.6") }
    }
}

/// A local release: the app zipped as `make release` zips it, the manifest over it (file://).
private struct StubRelease {
    let root = tempDir()
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var paths: Paths { Paths(home: home, configDir: home.appendingPathComponent(".config/palaver")) }
    var installed: URL { home.appendingPathComponent("Applications/Palaver.app", isDirectory: true) }
    var dist: URL { root.appendingPathComponent("dist", isDirectory: true) }
    var manifest: URL { dist.appendingPathComponent("manifest.json") }

    /// Palaver `current` installed, release `version` published (its bundle says `bundled`).
    func make(current: String = "0.6.0", version: String = "0.6.1", bundled: String? = nil, sha: String? = nil) throws {
        fakeBundle(installed, version: current)
        mkdir(paths.support)
        let build = root.appendingPathComponent("build/Palaver.app", isDirectory: true)
        fakeBundle(build, version: bundled ?? version)
        mkdir(dist)
        let zip = dist.appendingPathComponent("palaver-app-\(version).zip")
        try UpdateStaging.run("/usr/bin/ditto", ["-ck", "--keepParent", build.path, zip.path], what: "zipping")
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! Int
        try manifestJSON(version: version, app: ["name": zip.lastPathComponent, "url": zip.absoluteString, "size": size,
                                                 "sha256": sha ?? sha256(zip)]).write(to: manifest)
    }

    func backend(bundle: URL?? = nil, opener: String = "/usr/bin/false", ran: Ran = Ran()) -> SwiftUpdateBackend {
        SwiftUpdateBackend(.init(paths: paths, bundle: bundle ?? installed, downloads: ReleaseDownloads(manifestURL: manifest.absoluteString),
                                 macos: "15.6", outputDir: { home.appendingPathComponent("Meetings") }, open: opener, startTimeout: 4,
                                 runScript: { ran.scripts.append($0) }, temp: root.appendingPathComponent("tmp")))
    }

    func version(_ app: URL) -> String? { UpdateStaging.bundleVersion(app) }

    /// Runs a script as /bin/sh does after the app quit, its 0.2 s sleeps 20 times shorter.
    func run(_ script: String) throws -> Int32 {
        executable(root.appendingPathComponent("fastbin/sleep"), "#!/bin/sh\nexec /bin/sleep 0.01\n")
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script]
        p.environment = ["PATH": root.appendingPathComponent("fastbin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A fake `open` that writes started-ok as the new app does at its first tick (or nothing).
    func opener(writesStartedOk: Bool) -> String {
        let url = root.appendingPathComponent(writesStartedOk ? "bin/open-ok" : "bin/open-silent")
        let ok = UpdateSwap.sh(paths.startedOk.path)
        executable(url, writesStartedOk
            ? "#!/bin/sh\nplutil -extract version raw -o - \"$1/Contents/Resources/runtime.json\" > \(ok)\n"
            : "#!/bin/sh\nexit 0\n")
        return url.path
    }
}

final class Ran: @unchecked Sendable { var scripts: [String] = [] }

@Suite struct ReleaseDownloadsTests {
    @Test func anAssetIsDownloadedWhenItsSizeAndSha256Match() throws {
        let r = StubRelease()
        try r.make()
        let m = try ReleaseDownloads(manifestURL: r.manifest.absoluteString).fetchManifest()
        final class Seen: @unchecked Sendable { var last = 0 }
        let seen = Seen()
        let dest = r.root.appendingPathComponent("x/a.part")
        try ReleaseDownloads(manifestURL: r.manifest.absoluteString).download(m.app, to: dest) { seen.last = $0 }
        #expect(seen.last == m.app.size && exists(dest))
    }

    @Test func aDamagedDownloadIsDeletedAndRefused() throws {
        let r = StubRelease()
        try r.make(sha: String(repeating: "a", count: 64))
        let d = ReleaseDownloads(manifestURL: r.manifest.absoluteString)
        let m = try d.fetchManifest()
        let dest = r.root.appendingPathComponent("x/a.part")
        #expect(throws: DownloadError("\(m.app.name) arrived damaged (checksum mismatch); nothing was changed")) {
            try d.download(m.app, to: dest)
        }
        #expect(!exists(dest))
    }

    @Test func aDownloadLargerThanTheReleaseSaysStopsAtOnce() throws {
        let r = StubRelease()
        try r.make()
        let d = ReleaseDownloads(manifestURL: r.manifest.absoluteString)
        var asset = try d.fetchManifest().app
        asset.size = 10
        let dest = r.root.appendingPathComponent("x/a.part")
        final class Seen: @unchecked Sendable { var most = 0 }
        let seen = Seen()
        #expect(throws: DownloadError("download of \(asset.name) failed: more than the 10 bytes the release names")) {
            try d.download(asset, to: dest) { seen.most = max(seen.most, $0) }
        }
        #expect(!exists(dest) && seen.most <= 10)
    }

    @Test func onlyHttpsUnlessTheManifestItselfIsALocalFile() throws {
        let local = ReleaseAsset(name: "a.zip", url: "file:///tmp/a.zip", size: 1, sha256: zeroSha)
        let https = ReleaseDownloads(manifestURL: ReleaseManifest.latestURL)
        #expect(!https.allowed(local.url) && https.allowed(ReleaseManifest.latestURL) && !https.allowed("http://example.invalid/a"))
        #expect(throws: DownloadError("only https downloads are allowed, not file:///tmp/a.zip")) {
            try https.download(local, to: tempDir().appendingPathComponent("a"))
        }
        #expect(ReleaseDownloads(manifestURL: "file:///tmp/manifest.json").allowed(local.url))
        #expect(ReleaseDownloads.manifestURL(environment: ["PALAVER_MANIFEST_URL": "file:///m.json"]) == "file:///m.json")
        #expect(ReleaseDownloads.manifestURL(environment: [:]) == ReleaseManifest.latestURL)
    }
}

@Suite(.serialized) struct SwiftUpdateBackendTests {
    @Test func aCheckFindsTheNewerReleaseAndACheckoutHasNothingToUpdate() throws {
        let r = StubRelease()
        try r.make()
        let s = try r.backend().status()
        #expect(s.installed == UpdateInstalled(version: "0.6.0") && s.previous == nil)
        guard case .plan(let plan) = try r.backend().check() else { Issue.record("no plan"); return }
        #expect(plan.version == "0.6.1" && !plan.runtime && plan.models.isEmpty && plan.downloadBytes > 0)
        #expect(try r.backend(bundle: .some(nil)).status().installed == nil)
        #expect(try r.backend(bundle: .some(nil)).check() == .upToDate)
    }

    @Test func downloadStagesTheCheckedAppAndTheSwapInstallsItOnceItStarted() throws {
        let r = StubRelease()
        try r.make()
        touch(r.paths.permissionsMarker)
        let ran = Ran()
        let b = r.backend(opener: r.opener(writesStartedOk: true), ran: ran)
        final class Seen: @unchecked Sendable { var last = 0 }
        let seen = Seen()
        try b.download(version: "0.6.1") { seen.last = $0 }
        let staged = r.paths.support.appendingPathComponent("updates/app/Palaver.app")
        #expect(r.version(staged) == "0.6.1" && seen.last > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.paths.support.appendingPathComponent("updates").path) == ["app"])
        // The app quits first: a pid that ends a moment later.
        let app = try spawnChild(["/bin/sleep", "0.3"], env: [:])
        let script = try b.prepare(waitFor: [app.pid])
        try b.commit()
        #expect(!exists(r.paths.permissionsMarker))  // the restarted app asks for its permissions again
        try b.spawnSwap(script: script)
        #expect(ran.scripts == [script])
        #expect(try r.run(script) == 0)
        #expect(app.poll() != nil)
        #expect(r.version(r.installed) == "0.6.1")
        #expect(!exists(r.paths.support.appendingPathComponent("previous-app")) && !exists(staged))
        #expect(!exists(r.paths.support.appendingPathComponent("update.json")))
    }

    @Test func anUpdateThatDoesNotStartPutsTheVersionBeforeBackAndTheNextStartSaysSo() throws {
        let r = StubRelease()
        try r.make()
        let b = r.backend(opener: r.opener(writesStartedOk: false))
        try b.download(version: "0.6.1") { _ in }
        let script = try b.prepare(waitFor: [])
        try b.commit()
        #expect(try r.run(script) == 0)
        #expect(r.version(r.installed) == "0.6.0")
        #expect(!exists(r.paths.support.appendingPathComponent("previous-app")))
        let updates = Updates(.init(backend: r.backend(), startedOk: r.paths.startedOk))
        updates.load()
        let status = updates.status()
        #expect(status["state"]?.stringValue == "failed")
        #expect(status["error"]?.stringValue == "Palaver 0.6.1 did not start; 0.6.0 is back.")
        #expect(status["available"]?["version"]?.stringValue == "0.6.1")
    }

    @Test func aDownloadedAppOfAnotherVersionIsRefusedAndLeavesNothing() throws {
        let r = StubRelease()
        try r.make(bundled: "0.6.0")
        #expect(throws: ManifestError("the downloaded app is not Palaver 0.6.1")) { try r.backend().download(version: "0.6.1") { _ in } }
        #expect(!exists(r.paths.support.appendingPathComponent("updates")))
        #expect(throws: ManifestError("no downloaded update to install")) { try r.backend().prepare(waitFor: []) }
    }

    @Test func aReleaseThatMovedOnSinceTheCheckIsCheckedAgain() throws {
        let r = StubRelease()
        try r.make()
        #expect(throws: ManifestError("Palaver 0.6.1 came out, not 0.6.0rc9; check again")) {
            try r.backend().download(version: "0.6.0rc9") { _ in }
        }
    }

    @Test func theSwapScriptQuotesItsPathsAndKeepsItsKeys() {
        let places = UpdateSwap.Places(target: URL(fileURLWithPath: "/Users/x/Applications/Palaver.app"),
                                       staged: URL(fileURLWithPath: "/tmp/it's/Palaver.app"), support: URL(fileURLWithPath: "/s"))
        let text = UpdateSwap.script(current: "0.6.0", version: "0.6.1", places: places, pids: [7, 8])
        #expect(text.hasPrefix("#!/bin/sh\n# Palaver's update from 0.6.0 to 0.6.1.\n"))
        #expect(text.contains("staged='/tmp/it'\\''s/Palaver.app'\n"))
        #expect(text.contains("for pid in 7 8; do\n") && text.contains("while [ \"$n\" -lt 600 ]; do\n"))
        #expect(text.contains(#"pkill -TERM -f "$target/Contents/MacOS/(palaver-launcher|Palaver)\$" 2>/dev/null"#))
        #expect(text.contains(#"failed '{"state": "failed", "from_swap": true, "error": "Palaver 0.6.1 did not start; 0.6.0 is back.", "available": {"version": "0.6.1"}}'"#))
        #expect(text.hasSuffix("reopen\n"))
    }
}

@Suite struct UninstallTests {
    private func home() -> (Paths, URL) {
        let root = tempDir()
        let paths = Paths(home: root, configDir: root.appendingPathComponent(".config/palaver"))
        fakeBundle(root.appendingPathComponent("Applications/Palaver.app"), version: "0.6.0")
        for dir in ["runtime/rt-1/bin", "updates", "models/fluidaudio"] { mkdir(paths.support.appendingPathComponent(dir)) }
        touch(paths.support.appendingPathComponent("update.json"), "{}")
        touch(paths.support.appendingPathComponent("daemon.json"), "{}")
        mkdir(root.appendingPathComponent("Library/LaunchAgents"))
        touch(root.appendingPathComponent("Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist"))
        mkdir(root.appendingPathComponent(".local/bin"))
        try? FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".local/bin/palaver").path,
                                                    withDestinationPath: root.appendingPathComponent("Applications/Palaver.app/Contents/Resources/bin/palaver").path)
        mkdir(paths.configDir)
        mkdir(paths.logs)
        let meetings = root.appendingPathComponent("Meetings")
        for dir in ["2026-11-01T10-00-00", ".trash/2026-10-01T09-00-00", ".jobs", "My own folder"] { mkdir(meetings.appendingPathComponent(dir)) }
        touch(meetings.appendingPathComponent("notes.txt"), "mine")
        return (paths, meetings)
    }

    @Test func alwaysTheAppItsRuntimeTheLoginItemTheCommandAndAPendingUpdate() {
        let (paths, meetings) = home()
        let plan = Uninstall.plan(paths: paths, outputDir: meetings, models: false, recordings: false).map(\.lastPathComponent)
        #expect(plan == ["Palaver.app", "runtime", "com.kenodressel.meeting-transcribe.plist", "updates", "update.json", "palaver"])
        let models = Uninstall.plan(paths: paths, outputDir: meetings, models: true, recordings: false).map(\.lastPathComponent)
        #expect(models.last == "models")
    }

    @Test func aCommandLinkedElsewhereStays() throws {
        let (paths, meetings) = home()
        let link = paths.home.appendingPathComponent(".local/bin/palaver")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/opt/other/palaver")
        #expect(!Uninstall.plan(paths: paths, outputDir: meetings, models: false, recordings: false).contains(link))
    }

    @Test func withTheRecordingsOnlyWhatPalaverMadeGoes() throws {
        let (paths, meetings) = home()
        let plan = Uninstall.plan(paths: paths, outputDir: meetings, models: false, recordings: true)
        let names = plan.map(\.path)
        #expect(names.contains(paths.support.appendingPathComponent("daemon.json").path))
        #expect(!names.contains(paths.support.appendingPathComponent("models").path) && !names.contains(paths.support.path))
        #expect(names.contains(paths.configDir.path) && names.contains(paths.logs.path))
        #expect(names.contains(meetings.appendingPathComponent("2026-11-01T10-00-00").path))
        #expect(names.contains(meetings.appendingPathComponent(".trash/2026-10-01T09-00-00").path))
        #expect(names.contains(meetings.appendingPathComponent(".jobs").path))
        #expect(!names.contains(meetings.appendingPathComponent("My own folder").path) && !names.contains(meetings.appendingPathComponent("notes.txt").path))
        // The script removes them once the app quit; the user's own files stay, and so does the folder holding them.
        let ran = Ran()
        let work = tempDir()
        let script = try Uninstall.start(plan, waitFor: [999_999], work: work,
                                         thenIfEmpty: Uninstall.emptied(paths: paths, outputDir: meetings), run: { ran.scripts.append($0) })
        #expect(ran.scripts == [script.path])
        let p = try spawnChild(["/bin/sh", script.path], env: [:], newSession: false)
        p.waitUntilExit()
        #expect(plan.allSatisfy { !exists($0) })
        #expect(exists(meetings.appendingPathComponent("notes.txt")) && exists(meetings.appendingPathComponent("My own folder")))
        #expect(exists(paths.support.appendingPathComponent("models/fluidaudio")) && !exists(script))
        // A recordings folder set to the home folder: nothing is taken from there.
        #expect(!Uninstall.plan(paths: paths, outputDir: paths.home, models: false, recordings: true)
            .contains { $0.deletingLastPathComponent().path == paths.home.path && $0.lastPathComponent.hasPrefix("2026") })
        #expect(Uninstall.recordingsDir(home: paths.home, outputDir: paths.home) == nil)
        #expect(Uninstall.recordingsDir(home: paths.home, outputDir: URL(fileURLWithPath: "/")) == nil)
    }
}

@Suite(.serialized) struct RuntimeCleanupTests {
    /// A 0.6 bundle after an update from 0.5: the old runtime, the placeholder, `.previous` and a stale unpacking.
    private struct Fixture {
        let root = tempDir()
        var support: URL { root.appendingPathComponent("Library/Application Support/palaver", isDirectory: true) }
        var bundle: URL { root.appendingPathComponent("Applications/Palaver.app", isDirectory: true) }
        var runtime: URL { support.appendingPathComponent("runtime", isDirectory: true) }
        var claude: URL { root.appendingPathComponent(".claude.json") }

        init() {
            fakeBundle(bundle, version: "0.6.0")
            for id in ["3.13.18-arm64-155fa76f8b4e", "no-python-1"] {
                executable(runtime.appendingPathComponent("\(id)/bin/python3"), String(repeating: "x", count: 1000))
            }
            mkdir(runtime.appendingPathComponent("3.13.18-arm64-155fa76f8b4e/lib/python3.13/site-packages"))
            touch(runtime.appendingPathComponent("3.13.18-arm64-155fa76f8b4e/lib/python3.13/site-packages/x.py"), "pass\n")
            touch(runtime.appendingPathComponent(".previous"), "3.13.18-arm64-155fa76f8b4e\n")
            mkdir(runtime.appendingPathComponent(".no-python-2.abc123"))
            touch(support.appendingPathComponent("started-ok"), "0.6.0")
            touch(claude, #"{"mcpServers": {"palaver": {"command": "\#(bundle.path)/Contents/Resources/bin/palaver", "args": ["mcp"]}}}"#)
        }

        func facts(users: [Int32] = [], env: [String: String] = [:], bundle: URL?? = nil, version: String? = "0.6.0") -> RuntimeCleanup.Facts {
            RuntimeCleanup.Facts(bundle: bundle ?? self.bundle, bundleVersion: version, support: support, environment: env,
                                 claudeConfigs: [claude, root.appendingPathComponent("no-desktop.json")], users: { _ in users })
        }
    }

    final class Lines: @unchecked Sendable { var all: [String] = [] }

    @Test func theRuntimeGoesWhenNothingNeedsItAndItIsLoggedOnceWithTheBytes() {
        let f = Fixture()
        let lines = Lines()
        let freed = RuntimeCleanup.run(f.facts(), log: { lines.all.append($0) })
        #expect(freed == 2032)  // two python3 of 1000 bytes, x.py, .previous
        #expect(!exists(f.runtime) && exists(f.support.appendingPathComponent("started-ok")) && exists(f.bundle))
        #expect(lines.all == ["deleted the old Python runtime: 0.0 MB free again"])
        #expect(RuntimeCleanup.run(f.facts(), log: { lines.all.append($0) }) == nil && lines.all.count == 1)  // gone: nothing more said
    }

    @Test func eachPreconditionKeepsIt() {
        func kept(_ f: Fixture, _ facts: RuntimeCleanup.Facts, _ why: String) {
            let lines = Lines()
            #expect(RuntimeCleanup.run(facts, log: { lines.all.append($0) }) == nil, "\(why)")
            #expect(exists(f.runtime.appendingPathComponent("no-python-1/bin/python3")), "\(why)")
            #expect(lines.all.count == 1 && lines.all[0].contains(why), "\(lines.all)")
        }
        var f = Fixture()
        kept(f, f.facts(bundle: .some(nil)), "not a release bundle")
        kept(f, f.facts(version: nil), "not a release bundle")
        executable(f.bundle.appendingPathComponent("Contents/MacOS/palaver-python"), "#!/bin/sh\n")
        kept(f, f.facts(), "still runs Python")
        f = Fixture()
        mkdir(f.bundle.appendingPathComponent("Contents/Resources/python/palaver"))
        kept(f, f.facts(), "still runs Python")
        f = Fixture()
        touch(f.support.appendingPathComponent("started-ok"), "0.5.0rc6")
        kept(f, f.facts(), "has not started all the way")
        try? FileManager.default.removeItem(at: f.support.appendingPathComponent("started-ok"))
        kept(f, f.facts(), "has not started all the way")
        // started-ok written after swap.sh's window: the swap is putting the old app back, which needs the runtime.
        f = Fixture()
        mkdir(f.support.appendingPathComponent("previous-app/Palaver.app/Contents/Resources/python"))
        kept(f, f.facts(), "previous-app is still there")
        f = Fixture()
        touch(f.support.appendingPathComponent("update.json"),
              #"{"state": "failed", "from_swap": true, "error": "Palaver 0.6.0 did not start; 0.5.0rc6 is back.", "available": {"version": "0.6.0"}}"#)
        kept(f, f.facts(), "swap failed")
        f = Fixture()
        touch(f.claude, #"{"mcpServers": {"palaver": {"command": "\#(f.runtime.path.replacingOccurrences(of: "/", with: "\\/"))\/3.13.18\/bin\/python3"}}}"#)
        kept(f, f.facts(), ".claude.json still starts Palaver's Python")
        f = Fixture()
        kept(f, f.facts(users: [4242]), "a process uses it (pid 4242)")
    }

    @Test func aBundledPythonInAClaudeConfigDoesNotKeepIt() {
        // Another app's, or Palaver.app's own bin/python: in 0.6 a shim starting bin/palaver mcp, no runtime needed.
        for command in ["/Applications/Other.app/Contents/Resources/bin/python", "/Applications/Palaver.app/Contents/Resources/bin/python"] {
            let f = Fixture()
            touch(f.claude, #"{"mcpServers": {"other": {"command": "\#(command)", "args": ["-m", "palaver", "mcp"]}}}"#)
            touch(f.support.appendingPathComponent("update.json"), #"{"state": "up_to_date", "current": "0.6.0"}"#)
            #expect(RuntimeCleanup.run(f.facts(), log: { _ in }) != nil && !exists(f.runtime), "\(command)")
        }
    }

    @Test func aSymlinkIsRemovedAsALinkAndNeverFollowedOut() throws {
        let f = Fixture()
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        mkdir(outside)
        touch(outside.appendingPathComponent("keep.txt"), "mine")
        try FileManager.default.createSymbolicLink(atPath: f.runtime.appendingPathComponent("no-python-1/lib").path,
                                                   withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: f.runtime.appendingPathComponent("file-link").path,
                                                   withDestinationPath: outside.appendingPathComponent("keep.txt").path)
        #expect(RuntimeCleanup.run(f.facts(), log: { _ in }) != nil)
        #expect(!exists(f.runtime) && exists(outside.appendingPathComponent("keep.txt")))
    }

    @Test func aRuntimeFolderThatIsALinkElsewhereIsRefused() throws {
        let f = Fixture()
        let elsewhere = f.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: f.runtime, to: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: f.runtime.path, withDestinationPath: elsewhere.path)
        let lines = Lines()
        #expect(RuntimeCleanup.run(f.facts(), log: { lines.all.append($0) }) == nil)
        #expect(exists(elsewhere.appendingPathComponent("no-python-1/bin/python3")) && lines.all.first?.contains("not a folder") == true)
    }

    @Test func aProcessRunningFromTheRuntimeIsFound() throws {
        let f = Fixture()
        let program = f.runtime.appendingPathComponent("no-python-1/bin/python3")
        try FileManager.default.removeItem(at: program)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: program.path)
        let p = try spawnChild([program.path, "30"], env: [:], newSession: false)
        defer { p.kill(); p.waitUntilExit() }
        var found: [Int32] = []
        for _ in 0..<50 where !found.contains(p.pid) {
            found = RuntimeCleanup.processesUsing(f.runtime)
            usleep(20_000)
        }
        #expect(found.contains(p.pid))
        #expect(RuntimeCleanup.processesUsing(Fixture().runtime).isEmpty)
    }

    @Test func housekeepingWaitsForStartedOkThenDeletes() {
        let f = Fixture()
        try? FileManager.default.removeItem(at: f.support.appendingPathComponent("started-ok"))
        final class Sleeps: @unchecked Sendable { var n = 0 }
        let sleeps = Sleeps()
        let started = f.support.appendingPathComponent("started-ok")
        let (_, work) = Housekeeping.removingOldRuntime(f.facts(), wait: 10, sleep: { _ in
            sleeps.n += 1
            if sleeps.n == 3 { touch(started, "0.6.0") }  // the first tick wrote it
        }, log: { _ in })
        try? work()
        #expect(sleeps.n == 3 && !exists(f.runtime))
        let g = Fixture()
        try? FileManager.default.removeItem(at: g.support.appendingPathComponent("started-ok"))
        let (_, never) = Housekeeping.removingOldRuntime(g.facts(), wait: 3, sleep: { _ in }, log: { _ in })
        try? never()
        #expect(exists(g.runtime))  // the next start tries again
        // started-ok is there, the swap still has to delete previous-app: it waits for that too.
        let h = Fixture()
        let previous = h.support.appendingPathComponent("previous-app")
        mkdir(previous)
        let waits = Sleeps()
        let (_, swapEnds) = Housekeeping.removingOldRuntime(h.facts(), wait: 10, sleep: { _ in
            waits.n += 1
            if waits.n == 2 { try? FileManager.default.removeItem(at: previous) }
        }, log: { _ in })
        try? swapEnds()
        #expect(waits.n == 2 && !exists(h.runtime))
    }
}
