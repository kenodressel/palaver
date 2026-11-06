// What the app answers on app.sock (appctl.app_calls): argument checks and refusal texts, verbatim,
// over `AppActions`, which the daemon (later tasks) implements. Work that touches the daemon runs
// on the main thread through `MainRunner`.
import Darwin
import Foundation
import PalaverCore

/// The daemon's side of the calls. Methods marked "main" are called on the main thread.
public protocol AppActions: AnyObject {
    // main
    func answerStopQuestion(choice: String, meeting: String?) -> Bool
    func switchedOff(app: String)
    func transcribeAgain(folder: String) -> Bool
    /// state: "recording" | "idle" | …; folder: the running recording's folder path.
    func status() -> (state: String, folder: String?)
    func stopManual()
    func startManual() -> Bool
    func refresh()
    // any thread
    func watchHelper(folder: String, process: PidProcess)
    /// Throws CallRefused for what is not a helper (Python's ValueError).
    func launchHelper(kind: String, key: String, args: [String]) throws -> Int32
    func restartWeb() -> Int32?
    /// The setup assistant's test recording; throws CallRefused for Python's ValueError.
    func testRecording(action: String?, mode: [String: Any], busy: () -> Bool) throws -> Any?
}

public enum AppCalls {
    public static let switchApps = ["teams", "slack"]

    /// The calls of appctl.app_calls plus `extra` (calendar, update_check, update_install, uninstall,
    /// which later tasks provide).
    public static func make(actions: AppActions, main: MainRunner, pid: Int32 = getpid(),
                            children: @escaping @Sendable (Int32) -> [Int32] = childPids,
                            extra: [String: AppHandler] = [:]) -> [String: AppHandler] {
        @Sendable func str(_ v: Any?) -> String { v is NSNull || v == nil ? "None" : "\(v!)" }
        var calls: [String: AppHandler] = [:]
        calls["ping"] = { _ in ["pid": Int(pid)] }
        calls["answer"] = { args in
            let choice = str(args["choice"]), meeting = args["meeting"].flatMap { $0 is NSNull ? nil : str($0) }
            return try await main.run {
                let done = actions.answerStopQuestion(choice: choice, meeting: meeting)
                actions.refresh()
                return done
            }
        }
        calls["switched_off"] = { args in
            let app = args["app"] as? String
            guard let app, switchApps.contains(app) else { throw CallRefused("no record switch for \(pyRepr(args["app"]))") }
            try await main.run { actions.switchedOff(app: app); actions.refresh() }
            return nil
        }
        calls["watch"] = { args in
            guard let n = args["pid"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                throw CallRefused("0 is not a process Palaver started")
            }
            let d = n.doubleValue  // never narrowed before the range check
            guard d >= 1, d <= Double(Int32.max), d == d.rounded() else {
                throw CallRefused("\(n) is not a process Palaver started")
            }
            let target = n.int32Value
            guard descendant(target, root: pid, children: children) else {
                throw CallRefused("\(target) is not a process Palaver started")
            }
            actions.watchHelper(folder: str(args["folder"]), process: PidProcess(target))
            return nil
        }
        calls["start_helper"] = { args in
            let list = (args["args"] as? [Any] ?? []).map(str)
            return ["pid": Int(try actions.launchHelper(kind: str(args["kind"]), key: str(args["key"]), args: list))]
        }
        calls["transcribe"] = { args in
            let folder = str(args["folder"])
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
                throw CallRefused("no recording at \(folder)")
            }
            return try await main.run { let q = actions.transcribeAgain(folder: folder); actions.refresh(); return q }
        }
        calls["record"] = { args in
            let action = args["action"] as? String
            let meeting = args["meeting"] is NSNull ? nil : args["meeting"] as? String
            guard let action, action == "start" || action == "stop" else {
                throw CallRefused("no recording action \(pyRepr(args["action"]))")
            }
            let (answer, refused): ([String: Any]?, String?) = try await main.run {
                let status = actions.status()
                let folder = status.folder.map { ($0 as NSString).lastPathComponent }
                if action == "stop" {
                    if status.state != "recording" || (meeting != nil && meeting != folder) {
                        return (nil, "This recording is no longer running.")
                    }
                    actions.stopManual()
                    actions.refresh()
                    return (["stopped": folder as Any? ?? NSNull()], nil)
                }
                if status.state == "recording" { return (nil, "Palaver is recording already.") }
                if !actions.startManual() { return (nil, "The recording did not start; the log says why.") }
                actions.refresh()
                let started = actions.status().folder.map { ($0 as NSString).lastPathComponent }
                return (["meeting": started as Any? ?? NSNull()], nil)
            }
            if let refused { throw CallRefused(refused) }
            return answer
        }
        calls["test"] = { args in
            let mode = args["mode"] as? [String: Any] ?? [:]
            return try actions.testRecording(action: args["action"] as? String, mode: mode,
                                             busy: { actions.status().state == "recording" })
        }
        calls["restart_web"] = { _ in ["pid": actions.restartWeb().map { Int($0) as Any } ?? NSNull()] }
        for (name, handler) in extra { calls[name] = handler }
        return calls
    }
}

// MARK: descendant check and PidProcess (appctl.descendant, appctl.PidProcess)

/// The pids whose parent is `pid` (libproc).
@Sendable public func childPids(_ pid: Int32) -> [Int32] {
    var buffer = [Int32](repeating: 0, count: 1024)
    let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
    guard n > 0 else { return [] }
    return Array(buffer.prefix(min(Int(n), buffer.count))).filter { $0 > 0 }
}

/// Whether `pid` runs under `root` (this process): a child or a child's child. Never `root`
/// itself, launchd or the kernel.
public func descendant(_ pid: Int32, root: Int32 = getpid(),
                       children: (Int32) -> [Int32] = childPids) -> Bool {
    if pid <= 1 || pid == root { return false }
    var seen: Set<Int32> = [root], todo: [Int32] = [root]
    while let next = todo.popLast() {
        for child in children(next) {
            if child == pid { return true }
            if seen.insert(child).inserted { todo.append(child) }
        }
    }
    return false
}

/// A helper the window's server started, as the memory watchdog sees its workers: not this
/// process's child, so known by its pid.
public final class PidProcess: WorkerProcess, @unchecked Sendable {
    public let pid: Int32
    private let lock = NSLock()
    private var returncode: Int32?

    public init(_ pid: Int32) { self.pid = pid }

    /// nil while it runs, 0 once gone (also when the pid is someone else's now).
    public func poll() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if returncode == nil {
            if Darwin.kill(pid, 0) != 0 { returncode = 0 }  // ESRCH or EPERM
        }
        return returncode
    }

    private func send(_ sig: Int32) {
        guard poll() == nil else { return }
        if Darwin.kill(pid, sig) != 0 && errno == ESRCH {
            lock.lock(); returncode = 0; lock.unlock()
        }
    }

    public func terminate() { send(SIGTERM) }
    public func kill() { send(SIGKILL) }

    public func signalGroup(_ sig: Int32) {
        guard poll() == nil else { return }
        if getpgid(pid) == pid, killpg(pid, sig) == 0 { return }
        send(sig)
    }
}
