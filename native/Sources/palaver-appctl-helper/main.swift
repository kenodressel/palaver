// Test helper for tests/test_appctl_swift_contract.py: serves app.sock at argv[1] with fake
// handlers for all 13 calls. Prints "<socket path> <pid>" once bound. argv: <socket path>.
import Foundation
import PalaverCore
import PalaverDaemon

final class Fake: AppActions, @unchecked Sendable {
    var recording = false
    func answerStopQuestion(choice: String, meeting: String?) -> Bool { meeting == "2026-10-30T08-02-13" }
    func switchedOff(app: String) {}
    func transcribeAgain(folder: String) -> Bool { true }
    func status() -> (state: String, folder: String?) { recording ? ("recording", "/m/2026-11-03T14-00-00") : ("idle", nil) }
    func stopManual() { recording = false }
    func startManual() -> Bool { recording = true; return true }
    func refresh() {}
    func watchHelper(folder: String, process: PidProcess) {}
    func launchHelper(kind: String, key: String, args: [String]) throws -> Int32 {
        if kind == "run" { throw CallRefused("not a helper: run") }
        return 777
    }
    func restartWeb() -> Int32? { 4321 }
    func testRecording(action: String?, mode: [String: Any], busy: () -> Bool) throws -> Any? {
        if action == "start" {
            if busy() { throw CallRefused("a meeting is being recorded; try the test after it") }
            return ["state": "recording"]
        }
        return action == "stop" ? ["state": "checking"] : ["state": "idle", "max_seconds": 20.0]
    }
}

struct Exploding: Error, LocalizedError { var errorDescription: String? { "boom" } }

guard CommandLine.arguments.count == 2 else { FileHandle.standardError.write(Data("usage: palaver-appctl-helper <socket>\n".utf8)); exit(64) }
let fake = Fake()
// The "main thread" runs on a global queue here; `hang` is a call that outlives the 1 s main-thread timeout.
let main = MainRunner(timeout: 1) { work in DispatchQueue.global().async(execute: work) }
let hangMain = MainRunner(timeout: 1) { _ in }  // a main queue that never runs
var calls = AppCalls.make(actions: fake, main: main, extra: [
    "calendar": { args in ["state": "connected", "echo": args] },
    "update_check": { _ in ["state": "idle"] },
    "update_install": { _ in ["state": "installing"] },
    "uninstall": { args in ["removing": ["/x/palaver"], "models": args["models"] ?? false] },
])
calls["busy"] = { _ in try await hangMain.run { 1 } }
calls["refuse"] = { _ in throw CallRefused("Palaver is recording already.") }
calls["explode"] = { _ in throw Exploding() }
let server = AppSocket(path: CommandLine.arguments[1], handlers: calls, readTimeout: 1)
guard server.start() else { exit(1) }
print("\(server.path) \(getpid())")
fflush(stdout)
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { server.stop(); exit(0) }
term.resume()
dispatchMain()
