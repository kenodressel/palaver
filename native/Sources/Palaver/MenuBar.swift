// The menu bar item (palaver/menubar.py's MeetingApp menu, Clicker and show_menu_once). All words and
// rules come from MenuText (PalaverDaemon, tested without AppKit); this only binds them to an NSStatusItem.
// It is compiled but never run in tests: nothing here is created before Task 14 wires the app.
import AppKit
import Foundation
import PalaverCore
import PalaverDaemon

/// What the menu's items do; the app (Tasks 11, 12 and 14) supplies them.
struct MenuActions {
    var openMeetings: () -> Void = {}
    var openSettings: () -> Void = {}
    var startManual: () -> Void = {}
    var stopManual: () -> Void = {}
    var keepRecording: () -> Void = {}
    /// "Check for Updates…" / "Update available (…)": installs the update there is, else checks now.
    var updateClicked: () -> Void = {}
    var reportProblem: () -> Void = {}
    var quit: () -> Void = {}
    /// Whether the daemon is recording right now, asked when the start/stop item is clicked.
    var isRecording: () -> Bool = { false }
}

/// Everything one refresh shows, as the daemon, the level tracker and the updater give it.
struct MenuSnapshot {
    /// The daemon status with the record switches applied (`MenuText.withRecordSwitches`).
    var status: JSONValue
    var levels: [(label: String, db: Double?, silentFor: Double)] = []
    var now: Date = Date()
    var progress: MenuText.Progress?
    /// update.json's content (`MenuText.updateTitle` reads it); .null before the updater reports.
    var update: JSONValue = .object([("state", .string("unsupported"))])
    var error = false
}

@MainActor
final class MenuBar: NSObject {
    private let actions: MenuActions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let liveItems: [NSMenuItem]
    private let manualItem = NSMenuItem(title: MenuText.startTitle, action: nil, keyEquivalent: "")
    private let keepItem = NSMenuItem(title: MenuText.keepTitle, action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: MenuText.updateItemTitle, action: nil, keyEquivalent: "")
    private var hasIcon = true
    private let mono = [NSAttributedString.Key.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]

    init(actions: MenuActions, statusBar: NSStatusBar = .system) {
        self.actions = actions
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        liveItems = (0..<MenuText.menuLines).map { _ in NSMenuItem(title: "", action: nil, keyEquivalent: "") }
        super.init()
        let icon = Self.icon()
        statusItem.button?.image = icon
        hasIcon = icon != nil
        if icon == nil { statusItem.button?.title = "Palaver" }  // no icon found: say so in text
        statusItem.button?.imagePosition = .imageLeft
        buildMenu()
        installClick()
    }

    /// The black template icon: macOS tints it for light and dark menu bars.
    private static func icon() -> NSImage? {
        // Never Bundle.module: its generated accessor is a fatalError when the resource bundle is missing.
        let dirs = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        let url = ResourceLookup.find("menubar", "png", searchDirs: dirs, bundleSuffix: "_Palaver.bundle")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        return image
    }

    private func item(_ title: String, _ key: String = "", _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        for live in liveItems {
            live.isEnabled = false
            live.isHidden = true
            menu.addItem(live)
        }
        menu.addItem(.separator())
        let byTitle: [String: NSMenuItem] = [
            MenuText.startTitle: configured(manualItem, #selector(toggleManual)),
            MenuText.keepTitle: configured(keepItem, #selector(keep)),
            MenuText.openTitle: item(MenuText.openTitle, "m", #selector(openMeetings)),  // ⌘M
            MenuText.settingsTitle: item(MenuText.settingsTitle, ",", #selector(openSettings)),  // ⌘,
            MenuText.reportTitle: item(MenuText.reportTitle, "", #selector(reportProblem)),
            MenuText.updateItemTitle: configured(updateItem, #selector(updateClicked)),
            MenuText.quitTitle: item(MenuText.quitTitle, "q", #selector(quit)),  // ⌘Q
        ]
        for title in MenuText.layout {
            if let title, let entry = byTitle[title] { menu.addItem(entry) } else { menu.addItem(.separator()) }
        }
        keepItem.isHidden = true
        for entry in menu.items where entry.keyEquivalent != "" { entry.keyEquivalentModifierMask = .command }
    }

    private func configured(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem {
        item.target = self
        item.action = action
        return item
    }

    // MARK: clicks: left opens the window, right (or ctrl) shows the menu for that one click

    private func installClick() {
        // The status item has no menu of its own, which would open on every click.
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent.map { (rightMouseUp: $0.type == .rightMouseUp, control: $0.modifierFlags.contains(.control)) }
        switch MenuText.clickAction(event) {
        case .open: actions.openMeetings()
        case .menu:
            MenuText.showMenuOnce(setMenu: { [statusItem, menu] on in statusItem.menu = on ? menu : nil },
                                  click: { [statusItem] in statusItem.button?.performClick(nil) })
        }
    }

    // MARK: items

    @objc private func toggleManual(_ sender: NSMenuItem) {
        switch MenuText.manualAction(shown: sender.title, recording: actions.isRecording()) {
        case .start: actions.startManual()
        case .stop: actions.stopManual()
        case nil: break
        }
    }

    @objc private func keep(_ sender: Any?) { actions.keepRecording() }
    @objc private func openMeetings(_ sender: Any?) { actions.openMeetings() }
    @objc private func openSettings(_ sender: Any?) { actions.openSettings() }
    @objc private func reportProblem(_ sender: Any?) { actions.reportProblem() }
    @objc private func updateClicked(_ sender: Any?) { actions.updateClicked() }
    @objc private func quit(_ sender: Any?) { actions.quit() }

    // MARK: refresh (each tick)

    func refresh(_ s: MenuSnapshot) {
        let title = MenuText.title(s.status, error: s.error, now: s.now, progress: s.progress,
                                   update: MenuText.updateArrow(s.update))
        statusItem.button?.title = hasIcon ? title : ("Palaver " + title).trimmingCharacters(in: .whitespaces)
        statusLine.title = MenuText.statusLine(s.status, now: s.now, progress: s.progress)
        manualItem.title = MenuText.manualTitle(s.status)
        keepItem.isHidden = !MenuText.keepVisible(s.status)
        let update = MenuText.updateTitle(s.update)
        updateItem.title = update ?? MenuText.updateItemTitle
        updateItem.isHidden = update == nil  // from a checkout: nothing to update
        let lines = s.status["state"]?.stringValue == "recording" ? MenuText.recordingLines(s.status, levels: s.levels, now: s.now) : []
        for (i, live) in liveItems.enumerated() {
            let text = i < lines.count ? lines[i] : ""
            live.title = text
            live.attributedTitle = NSAttributedString(string: text, attributes: mono)  // monospaced so the level bars line up
            live.isHidden = text.isEmpty
        }
    }
}
