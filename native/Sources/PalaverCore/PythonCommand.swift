import Foundation

/// Runs `<python> -m palaver [extraArgs] <args...>` and reads its stdout as JSON lines (the commands of
/// palaver/app_update.py: `app update check --json`, `calendar attach`, ...). Every object but the last is
/// progress (`onObject`, e.g. {"progress": bytes}); the last is the answer. An answer {"error": text}, no
/// answer at all or a timeout throws a WorkerError. The child's stderr goes to `log` line by line (a
/// crash's traceback), else it is dropped. Blocks the calling thread (never the main one).
@discardableResult
public func pythonCommandBlocking(_ args: [String], python: String, extraArgs: [String] = [],
                                  env: [String: String] = [:], timeout: TimeInterval = 120,
                                  log: (@Sendable (String) -> Void)? = nil,
                                  onObject: (([String: Any]) -> Void)? = nil) throws -> [String: Any] {
    let p = Foundation.Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = ["-m", "palaver"] + extraArgs + args
    var merged = ProcessInfo.processInfo.environment
    for (k, v) in env { merged[k] = v }
    p.environment = merged
    let out = Pipe()
    p.standardOutput = out
    let err = Pipe()
    p.standardError = log == nil ? FileHandle.nullDevice : err
    p.standardInput = FileHandle.nullDevice
    let what = args.prefix(3).joined(separator: " ")
    do { try p.run() } catch {
        throw WorkerError(description: "cannot start \(python): \(error.localizedDescription)")
    }
    var errThread: Thread?
    let errDone = DispatchSemaphore(value: 0)
    if let log {
        // Read concurrently: a child writing a lot to stderr must not block on a full pipe.
        let t = Thread {
            var pending = Data()
            let h = err.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    if !line.isEmpty { log(line) }
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            if !pending.isEmpty { log(String(decoding: pending, as: UTF8.self)) }
            errDone.signal()
        }
        t.start()
        errThread = t
    }
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { p.terminate() }
    timer.resume()
    var buffer = Data(), last: [String: Any]?
    func take(_ line: Data) {
        guard !line.isEmpty, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let previous = last { onObject?(previous) }
        last = obj
    }
    let handle = out.fileHandleForReading
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            take(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
    }
    take(buffer)
    p.waitUntilExit()
    timer.cancel()
    if errThread != nil { errDone.wait() }
    guard let answer = last else {
        throw WorkerError(description: "palaver \(what): no JSON answer (exit \(p.terminationStatus))")
    }
    if let err = answer["error"] as? String { throw WorkerError(description: err) }
    return answer
}
