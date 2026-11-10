import Foundation
import Testing
@testable import PalaverCore
@testable import PalaverDomain

@Suite struct StorePathsTests {
    @Test func palaverHomeMovesEverythingUnderHome() {
        let s = StorePaths.current(env: ["PALAVER_HOME": "/tmp/ph"])
        #expect(Paths.fromEnvironment(["PALAVER_HOME": "/tmp/ph"]).home.path == "/tmp/ph")
        #expect(s.configDir.path == "/tmp/ph/.config/palaver")
        #expect(s.support.path == "/tmp/ph/Library/Application Support/palaver")
        #expect(s.launchAgent.path == "/tmp/ph/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist")
        #expect(s.applications.path == "/tmp/ph/Applications")
        #expect(s.downloads.path == "/tmp/ph/Downloads")
        #expect(s.logs.path == "/tmp/ph/Library/Logs/palaver")
        #expect(s.hubCache.path == "/tmp/ph/.cache/huggingface/hub")
        #expect(s.modelsDir.path == "/tmp/ph/Library/Application Support/palaver/models")
        #expect(s.engineProvenMarker.lastPathComponent == "engine-transcribed")
        #expect(s.daemonJson.lastPathComponent == "daemon.json")
        #expect(s.preparedNotes.lastPathComponent == "prepared-notes")
    }

    /// In a test, stores in the user's real ~/.config stop the process before anything is read (TestIsolation).
    @Test func aTestNeverGetsTheRealStores() async {
        await #expect(processExitsWith: .failure) {
            let home = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
            _ = StorePaths(configDir: URL(fileURLWithPath: home + "/.config/palaver"), home: URL(fileURLWithPath: "/tmp/ph"))
        }
        await #expect(processExitsWith: .failure) { _ = StorePaths.current(env: ["XDG_CONFIG_HOME": "/tmp/xdg"]) }
    }

    @Test func xdgMovesTheStores() {
        let s = StorePaths.current(env: ["PALAVER_HOME": "/tmp/ph", "XDG_CONFIG_HOME": "/tmp/xdg"])
        #expect(s.configDir.path == "/tmp/xdg/palaver")
        #expect(s.glossary.path == "/tmp/xdg/palaver/glossary.json")
        #expect(s.voices.path == "/tmp/xdg/palaver/voices")
        #expect(s.support.path == "/tmp/ph/Library/Application Support/palaver")
        let empty = StorePaths.current(env: ["PALAVER_HOME": "/tmp/ph", "XDG_CONFIG_HOME": ""])
        #expect(empty.configDir.path == "/tmp/ph/.config/palaver")
    }

    @Test func hubCacheFollowsHFVariables() {
        let both = StorePaths.current(env: ["PALAVER_HOME": "/tmp/ph", "HF_HUB_CACHE": "/c/hub", "HF_HOME": "/c/home"])
        #expect(both.hubCache.path == "/c/hub")
        let home = StorePaths.current(env: ["PALAVER_HOME": "/tmp/ph", "HF_HOME": "/c/home"])
        #expect(home.hubCache.path == "/c/home/hub")
    }

    @Test func configReadsLanguageAndTranscriber() {
        let d = Config(toml: "")
        #expect(d.language == "auto" && d.transcriber == "parakeet" && d.claudePath == nil)
        let c = Config(toml: "[model]\nlanguage = \"de\"\ntranscriber = \"whisper\"\n[notes]\nclaude = \"/opt/claude\"\n")
        #expect(c.language == "de" && c.transcriber == "whisper" && c.claudePath == "/opt/claude")
    }

    @Test func domainResourcesFindsTheBuildBundlesKeep() {
        #expect(DomainResources.url(".keep") != nil)
        #expect(DomainResources.url("nope-missing.bin") == nil)
        #expect(DomainResources.split("zipf.bin") == ("zipf", "bin"))
    }

    @Test func resourceLookupFindsRegularNamesInFlatAndNestedBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("palaver-res-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let flat = root.appendingPathComponent("a/x_Flat.bundle/Contents/Resources", isDirectory: true)
        let nested = root.appendingPathComponent("b/x_Nested.bundle/Contents/Resources/Resources", isDirectory: true)
        for d in [flat, nested] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("1".utf8).write(to: flat.appendingPathComponent("zipf.bin"))
        try Data("2".utf8).write(to: nested.appendingPathComponent("zipf.bin"))
        try Data("3".utf8).write(to: nested.appendingPathComponent("LICENSE"))
        try Data("4".utf8).write(to: nested.appendingPathComponent(".keep"))
        let a = [root.appendingPathComponent("a")], b = [root.appendingPathComponent("b")]
        #expect(ResourceLookup.find("zipf", "bin", main: nil, searchDirs: a, bundleSuffix: "_Flat.bundle")?.lastPathComponent == "zipf.bin")
        #expect(ResourceLookup.find("zipf", "bin", main: nil, searchDirs: b, bundleSuffix: "_Nested.bundle") == nil)
        #expect(ResourceLookup.find("Resources/zipf", "bin", main: nil, searchDirs: b, bundleSuffix: "_Nested.bundle")?.path.hasSuffix("Resources/Resources/zipf.bin") == true)
        #expect(ResourceLookup.find("Resources/LICENSE", "", main: nil, searchDirs: b, bundleSuffix: "_Nested.bundle") != nil)
        #expect(ResourceLookup.find("Resources/", "keep", main: nil, searchDirs: b, bundleSuffix: "_Nested.bundle") != nil)
        #expect(ResourceLookup.find("zipf", "bin", main: nil, searchDirs: b, bundleSuffix: "_Missing.bundle") == nil)
    }
}
