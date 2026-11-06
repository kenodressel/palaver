// Test helper for tests/test_notify_swift_contract.py: binds the notify socket with a recording
// fake center (no UserNotifications, no prompts). argv: <directory> <record-file>.
// Prints the socket path, then appends one JSON line per posted notification to the record file.
import Foundation
import PalaverCore

final class RecordingCenter: NotificationCenterLike, @unchecked Sendable {
    let file: String
    init(file: String) { self.file = file }
    func post(title: String, body: String, userInfo: [String: String], completion: @escaping @Sendable (Error?) -> Void) {
        let obj: [String: Any] = ["title": title, "message": body, "open": userInfo["open"] ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let h = FileHandle(forWritingAtPath: file) {
            h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close()
        }
        completion(nil)
    }
    func authorizationStatus(completion: @escaping @Sendable (NotifyPermission) -> Void) { completion(.notAsked) }
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
}

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: palaver-notify-helper <dir> <record>\n".utf8)); exit(64) }
FileManager.default.createFile(atPath: args[2], contents: nil)
let n = Notifications(center: RecordingCenter(file: args[2]), directory: args[1],
                      opener: { _ in }, fallback: { _, _ in })
guard n.start() else { exit(1) }
print("\(n.socketPath)\n\(n.statePath)")
fflush(stdout)
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { n.stop(); exit(0) }
term.resume()
dispatchMain()
