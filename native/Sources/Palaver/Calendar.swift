// EventKit access for the app (calendar_eventkit.py has_access / request_access): the permission belongs
// to this app, whose Info.plist carries the reason shown in the dialog; processing (a Python worker) reads
// events under the app's consent. Only `requestAccess` shows a dialog, and only the setup assistant's
// button reaches it (app.sock `calendar` connect); tests use a fake behind CalendarAccess.
import EventKit
import Foundation
import PalaverDaemon

final class EventKitCalendarAccess: CalendarAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var store: EKEventStore?

    func authorization() -> CalendarAuth {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    /// `requestFullAccessToEvents`; the store stays alive until the dialog is answered.
    func requestAccess() {
        let store = EKEventStore()
        lock.withLock { self.store = store }
        DispatchQueue.main.async {
            store.requestFullAccessToEvents { [weak self] _, _ in
                self?.lock.withLock { self?.store = nil }
            }
        }
    }
}
