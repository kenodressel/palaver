import Foundation

/// Asks the Python side: `<python> -m palaver [--config ...] app query <what...> --json`, stdout parsed as
/// one JSON object. Until the Python parts are ported (phase 2, Tasks 8 and following). `python` is
/// the bundle's host (`palaver-python`), wired in Task 14.
public func pythonQuery(_ what: [String], python: String, extraArgs: [String] = [],
                        env: [String: String] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            do {
                cont.resume(returning: try pythonQueryBlocking(what, python: python, extraArgs: extraArgs, env: env, timeout: timeout))
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// The same, blocking the calling thread (never the main one): for callers on their own queue.
public func pythonQueryBlocking(_ what: [String], python: String, extraArgs: [String] = [],
                                env: [String: String] = [:], timeout: TimeInterval = 60) throws -> [String: Any] {
    let p = Foundation.Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = ["-m", "palaver"] + extraArgs + ["app", "query"] + what + ["--json"]
    var merged = ProcessInfo.processInfo.environment
    for (k, v) in env { merged[k] = v }
    p.environment = merged
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch {
        throw WorkerError(description: "cannot start \(python): \(error.localizedDescription)")
    }
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { p.terminate() }
    timer.resume()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw WorkerError(description: "palaver app query \(what.first ?? ""): no JSON answer (exit \(p.terminationStatus))")
    }
    if let err = obj["error"] as? String {
        throw WorkerError(description: "palaver app query \(what.first ?? ""): \(err)")
    }
    return obj
}
