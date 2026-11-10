// `palaver-worker calendar-attach [--since H]` (app_update.py `calendar_attach`): earlier recordings get their
// calendar events (those started in the last H hours; all without), then voices are recognized again with the
// invitees known. The app skips this while it transcribes: processing looks the event up itself.
import Foundation
import PalaverCore
import PalaverDomain

public enum CalendarAttach {
    /// How many recordings got an event.
    public static func run(outputDir: URL, since hours: Double?, provider: CalendarProvider, userName: String,
                           stores: StorePaths = .current(), now: PyDateTime = Queries.localNow()) throws -> Int {
        let since = try hours.flatMap { $0 != 0 ? try now.adding(seconds: -$0 * 3600) : nil }
        let found = try CalendarEvents.attachAll(outputDir: outputDir, provider: provider, since: since, stores: stores)
        if found > 0 {
            _ = try People.refreshRecognition(outputDir: outputDir, userName: userName, stores: stores)
        }
        return found
    }

    /// The command's answer: `{"attached": n}`, or `{"attached": 0, "skipped": why}` when the calendar is off or
    /// not allowed (`provider` nil and `enabled` says which).
    public static func answer(config: Config, enabled: Bool, provider: CalendarProvider?, since: Double?,
                              stores: StorePaths = .current()) throws -> JSONValue {
        guard enabled else { return .object([("attached", .int(0)), ("skipped", .string("calendar is off"))]) }
        guard let provider else { return .object([("attached", .int(0)), ("skipped", .string("no calendar access"))]) }
        let userName = SettingsFile.currentUserName(default: config.userName, stores: stores)
        return .object([("attached", .int(try run(outputDir: config.outputDir, since: since, provider: provider,
                                                    userName: userName, stores: stores)))])
    }
}
