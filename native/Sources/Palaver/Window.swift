// The Meetings window (webapp/window.py): a native window with a WKWebView showing the page its
// server process serves (WebSupervisor), inside the menu bar app. Everything here runs on the main
// thread. The menus, the address, the bridge's scripts and the repeat-key guard are PalaverCore's
// WindowMenus/WindowPage (tested there); this file only puts them into AppKit.
//
// The app is a menu bar app (no Dock icon) until the window opens; while it is open the app shows
// in the Dock and the app switcher, and gets a main menu so copy/paste and ⌘W work in the window.
import AppKit
import PalaverCore
import PalaverDaemon
import WebKit

@MainActor
final class MeetingsWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var web: WKWebView?
    /// The menus whose items run the page's commands (Meeting, View, Help).
    private var commandMenus: [NSMenu] = []
    /// The page's commands that work right now (its last `commands` message).
    private var enabled: Set<String> = []
    /// "Palaver", or what records (MenuText.windowTitle), also for a window made later.
    private var title = WindowPage.title
    /// Palaver → Quit Palaver (⌘Q): the app's own quit, so a recording is handled as after the
    /// menu bar's Quit; nil: the app just terminates.
    var quit: (() -> Void)?

    // MARK: opening

    /// Shows the window at `url`, creating it on first use. A load carries the app's `key`, which
    /// the server keeps as a cookie and drops from the address (WindowPage.withKey).
    func open(url: String, key: String?) {
        NSApp.setActivationPolicy(.regular)
        dockIcon()
        if window == nil {
            let (w, v) = makeWindow(NSRect(x: 0, y: 0, width: WindowPage.size.0, height: WindowPage.size.1))
            window = w
            web = v
            w.center()
            w.setFrameAutosaveName(WindowPage.autosaveName)
        }
        guard let window, let web else { return }
        installMainMenu()
        if WindowPage.needsLoad(current: web.url?.absoluteString, url: url),
           let address = URL(string: WindowPage.withKey(url, key: key)) {
            web.load(URLRequest(url: address))
        }
        if window.isMiniaturized { window.deminiaturize(nil) }  // a Dock click or Open restores it (#20)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The server at `base` was restarted (WebSupervisor's onReady with restarted): load the
    /// window's page again where it is. Nothing before the window was first opened. Whether it
    /// reloaded.
    @discardableResult
    func reloadInPlace(base: String) -> Bool {
        guard let web, WindowPage.reloadsAfterRestart(current: web.url?.absoluteString, base: base) else { return false }
        web.reload()
        return true
    }

    /// A recording in the window's title and on the Dock icon (#23): seen while the window is open,
    /// also when the menu bar icon is hidden behind the notch. Called on every refresh.
    func showRecording(title: String, badge: String?) {
        if self.title != title {
            self.title = title
            window?.title = title
        }
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    /// Palaver's icon in the Dock while the window is open, when the process has no bundle icon of
    /// its own (a development run).
    private func dockIcon() {
        if let url = Bundle.main.url(forResource: "Palaver", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    /// The window with its web view; this object is the delegate of both and gets the page's
    /// messages.
    private func makeWindow(_ rect: NSRect) -> (NSWindow, WKWebView) {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: WindowPage.minSize.0, height: WindowPage.minSize.1)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: WindowPage.messageHandler)
        let web = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.allowsBackForwardNavigationGestures = true  // a two-finger swipe goes Back and Forward
        window.contentView = web
        window.delegate = self
        web.uiDelegate = self
        return (window, web)
    }

    // MARK: the menu bar

    /// The window's menu bar: Palaver, Edit, Meeting, View, Help (WindowMenus). The command menus'
    /// items carry their command as representedObject and are enabled from the page's message.
    private func installMainMenu() {
        func item(_ title: String, _ action: String?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action.map { Selector($0) }, keyEquivalent: key)
            i.target = target
            return i
        }
        func fixed(_ entry: WindowMenus.Item?) -> NSMenuItem {
            guard let entry else { return .separator() }
            let target: AnyObject? = switch entry.target {
            case .responder: nil
            case .delegate: self
            case .webView: web
            }
            return item(entry.title, entry.action, entry.key, target: target)
        }
        func command(_ entry: WindowMenus.Command?) -> NSMenuItem {
            guard let entry else { return .separator() }
            let i = item(entry.title, "runPageCommand:", entry.key, target: self)
            i.representedObject = entry.name
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let holder = item(title, nil)
            holder.submenu = m
            return holder
        }

        let bar = NSMenu()
        bar.addItem(menu("Palaver", WindowMenus.palaver.map(fixed)))
        bar.addItem(menu("Edit", WindowMenus.edit.map(fixed)))
        let meeting = menu("Meeting", WindowMenus.meeting.map(command))
        bar.addItem(meeting)
        let view = menu("View", WindowMenus.view.map(command) + [.separator(), fixed(WindowMenus.reload)])
        bar.addItem(view)
        let help = menu(WindowMenus.helpMenuTitle, WindowMenus.help.map(command))
        bar.addItem(help)
        NSApp.mainMenu = bar
        NSApp.helpMenu = help.submenu  // macOS adds its search field to it
        commandMenus = [meeting, view, help].compactMap(\.submenu)
        for m in commandMenus { m.autoenablesItems = false }  // enabled from the page's commands message
        showEnabled()
    }

    private func showEnabled() {
        for menu in commandMenus {
            for item in menu.items {
                guard let name = item.representedObject as? String else { continue }
                item.isEnabled = WindowMenus.isEnabled(command: name, enabled: enabled)
            }
        }
    }

    /// The Meeting menu's items, View → Back/Forward/palette and Help run the page's own code.
    @objc func runPageCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runOnPage(WindowPage.commandScript(name))
    }

    /// Edit → Undo: the page's undo (it hands text fields theirs).
    @objc func pageUndo(_ sender: Any?) { runOnPage(WindowPage.undoScript) }

    @objc func quitPalaver(_ sender: Any?) {
        if let quit { quit() } else { NSApp.terminate(nil) }
    }

    private func runOnPage(_ script: String) {
        guard let web, !pageSawThisKey(web) else { return }
        web.evaluateJavaScript(script, completionHandler: nil)
    }

    /// A ⌘ key that reaches the menu while the web view has the focus was the page's to take
    /// (WindowPage.pageSawThisKey): holding ⌘⌫ must not trash meeting after meeting.
    private func pageSawThisKey(_ web: WKWebView) -> Bool {
        let event = NSApp.currentEvent
        let responder = web.window?.firstResponder as? NSView
        return WindowPage.pageSawThisKey(keyDown: event?.type == .keyDown,
                                         command: event?.modifierFlags.contains(.command) ?? false,
                                         responderInWebView: responder?.isDescendant(of: web) ?? false)
    }

    // MARK: NSWindowDelegate

    /// Back to a menu bar only app.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: WKScriptMessageHandler: the page posts {type: "commands", enabled: [...]} after every render

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let commands = WindowPage.enabledCommands(message.body) else { return }
        enabled = commands
        showEnabled()
    }

    // MARK: WKUIDelegate: the page's confirm() and alert(), and <input type=file>

    /// A sheet, not a modal: the run loop (and with it the daemon's timer) keeps going while the
    /// question is open. Without a window to attach it to, the page gets the default answer.
    private func sheet(_ web: WKWebView, _ message: String, _ buttons: [String], done: @escaping (NSApplication.ModalResponse?) -> Void) {
        guard let window = web.window else { return done(nil) }
        let alert = NSAlert()
        alert.messageText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.beginSheetModal(for: window) { done($0) }
    }

    // Without these WebKit answers "Cancel" at once, so "join", "delete project" etc. did nothing.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        sheet(webView, message, ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        sheet(webView, message, ["OK"]) { _ in completionHandler() }
    }

    /// Import… (#58) and Add image in my notes. Without this WebKit opens no panel and the click
    /// does nothing.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { answer in completionHandler(answer == .OK ? panel.urls : nil) }
    }
}

/// The window's server for the app: supervised, and a restarted server reloads the window's page
/// where it was (process.py's on_ready → window.reload_in_place).
@MainActor
func startWebServer(window: MeetingsWindow, python: String, cliOptions: [String], appSocket: URL,
                    env: [String: String]? = nil, log: @escaping (String) -> Void) throws -> WebSupervisor {
    let listener = try WebListener.forWindow(log: log)
    let base = "http://127.0.0.1:\(listener.port)/"
    let supervisor = WebSupervisor.forApp(python: python, cliOptions: cliOptions, appSocket: appSocket, listener: listener,
                                          env: env, log: log, onReady: { restarted in
                                              guard restarted else { return }
                                              DispatchQueue.main.async { MainActor.assumeIsolated { _ = window.reloadInPlace(base: base) } }
                                          })
    supervisor.start()
    return supervisor
}
