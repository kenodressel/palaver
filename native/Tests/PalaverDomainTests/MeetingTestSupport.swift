// Helpers of the meeting suites: a temporary folder per test, files written the way a recording writes them.
import Foundation

/// A new empty folder under the system temp dir, removed by `remove()`.
struct TempFolder {
    let url: URL

    init(_ name: String = "meeting") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("palaver-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ text: String = "") {
        try! text.write(to: url.appendingPathComponent(name), atomically: false, encoding: .utf8)
    }

    func text(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) }
}

/// Another process (python3, as Python's `store_lock` would) holding a lock file with `flock` for `seconds`; the init
/// returns once it has it.
final class LockHolder {
    private let process = Foundation.Process()

    init(_ lock: URL, seconds: Double) throws {
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(float(sys.argv[2]))",
                             lock.path, String(seconds)]
        process.standardOutput = out
        try process.run()
        let said = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        guard said.hasPrefix("held") else { throw CocoaError(.executableLoad, userInfo: [NSDebugDescriptionErrorKey: "the lock holder said \(said)"]) }
    }

    /// Waits for it to let go; its exit status.
    @discardableResult
    func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}
