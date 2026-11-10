import Foundation
import Testing
@testable import PalaverCore
@testable import PalaverDomain

@Suite struct StoreLockTests {
    private func temp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func test_a_second_process_waits_for_the_lock() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("glossary.json")
        let held = try LockHolder(URL(fileURLWithPath: target.path + ".lock"), seconds: 0.5)
        let start = Date()
        try StoreLock.with(target) {}
        #expect(Date().timeIntervalSince(start) >= 0.4)
        #expect(held.wait() == 0)
    }

    @Test func test_reentrant_in_one_thread() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("projects.json")
        var depth = 0
        try StoreLock.with(target) { try StoreLock.with(target) { depth = 2 } }
        #expect(depth == 2)
        // released afterwards: another thread can take it
        let done = DispatchSemaphore(value: 0)
        Thread { try? StoreLock.with(target) {}; done.signal() }.start()
        #expect(done.wait(timeout: .now() + 5) == .success)
    }

    @Test func test_voices_lock_is_beside_the_folder() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let voices = dir.appendingPathComponent("voices", isDirectory: true)
        try StoreLock.with(voices) {}
        let lock = dir.appendingPathComponent("voices.lock")
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(!FileManager.default.fileExists(atPath: voices.path))
        var st = stat()
        #expect(stat(lock.path, &st) == 0)
        #expect(Int(st.st_mode) & 0o777 == 0o644)  // umask 022
    }

    @Test func test_an_unopenable_lock_throws_and_the_body_never_runs() {
        var ran = false
        #expect(throws: POSIXError.self) { try StoreLock.with(URL(fileURLWithPath: "/dev/null/x/store.json")) { ran = true } }
        #expect(!ran)
    }

    @Test func test_meeting_lock_is_hidden() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try StoreLock.meeting(RecordingPaths(dir)) {}
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".speakers.lock").path))
    }

    /// `/var/…` → `/private/var/…` (the folder under the symlinked /var, spelled through the link's target).
    private func privateSpelling(_ u: URL) -> URL {
        u.path.hasPrefix("/private/") ? u : URL(fileURLWithPath: "/private" + u.path)
    }

    private func plainSpelling(_ u: URL) -> URL {
        u.path.hasPrefix("/private/") ? URL(fileURLWithPath: String(u.path.dropFirst("/private".count))) : u
    }

    @Test func theSameLockUnderTwoSpellingsIsOneLock() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(dir.path.hasPrefix("/var/") || dir.path.hasPrefix("/private/var/"))
        // Each spelling first, in a folder that is there and in one the first lock makes: the key must not
        // depend on the spelling or on whether the folder exists yet.
        for (i, privateFirst) in [false, true, false, true].enumerated() {
            let folder = i < 2 ? dir : dir.appendingPathComponent("new\(i)", isDirectory: true)
            let spellings = [plainSpelling(folder), privateSpelling(folder)]
            let (first, second) = privateFirst ? (spellings[1], spellings[0]) : (spellings[0], spellings[1])
            var depth = 0
            try StoreLock.with(first.appendingPathComponent("projects.json")) {
                try StoreLock.with(second.appendingPathComponent("projects.json")) { depth = 2 }
            }
            #expect(depth == 2)
            try StoreLock.meeting(RecordingPaths(first.appendingPathComponent("m\(i)", isDirectory: true))) {
                try StoreLock.meeting(RecordingPaths(second.appendingPathComponent("m\(i)", isDirectory: true))) { depth = 3 }
            }
            #expect(depth == 3)
        }
    }
}
