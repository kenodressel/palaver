// `palaver app install|uninstall|autostart|restart-web|ping` (cli.py `_cmd_app`, app_bundle.py): the app in
// ~/Applications and its login item, and what is asked of the running app over app.sock.
import Darwin
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

extension CLICommand {
    static let APP_NAME = "Palaver"
    /// The app under a name it had before: one bundle id, one app.
    static let OLD_APP_NAMES = ["Meeting Transcribe"]
    /// The running server finishes its changes, the new one has its time to come up: wait longer than both
    /// (cli.py `RESTART_WEB_TIMEOUT`).
    static let RESTART_WEB_TIMEOUT = 100.0

    func app() -> Int32 {
        switch parsed.one("action") ?? "install" {
        case "ping": return ping()
        case "restart-web": return restartWeb()
        case "autostart": return autostart()
        case "uninstall": return uninstall()
        default: return install()
        }
    }

    /// `_ping_app`: whether the running app (the one recording) answers on app.sock.
    func ping() -> Int32 {
        do {
            let answer = try AppCtlClient.call("ping", path: ctx.appSocket)
            say("Palaver answers on \(ctx.appSocket.path) (pid \(Py.str(answer["pid"] ?? .null))).")
            return 0
        } catch {
            say("Palaver does not answer on \(ctx.appSocket.path): \(error)")
            return 1
        }
    }

    /// `_restart_web` (#57): only the Meetings window's server restarts, at any time, also during a call; the recording
    /// runs in the app and is never touched.
    func restartWeb() -> Int32 {
        let answer: JSONValue
        do {
            answer = try AppCtlClient.call("restart_web", path: ctx.appSocket, timeout: Self.RESTART_WEB_TIMEOUT)
        } catch let e as AppCtlClient.CallRefused {
            say("Palaver did not restart the window's server: \(e.message)")
            return 1
        } catch {
            say("Palaver is not running, or did not answer, or still runs the window's server inside the\n"
                + "app (a version from before #57: restart the whole app once). Nothing was restarted.")
            return 1
        }
        guard let pid = answer["pid"], pid.truthy else {
            say("Palaver restarted the window's server, but it is not up yet; see the log.")
            return 1
        }
        say("Restarted the window's server (pid \(Py.str(pid))); the window reloads where it was.")
        return 0
    }

    /// `app autostart [on|off]`: the LaunchAgent that opens ~/Applications/Palaver.app at login.
    func autostart() -> Int32 {
        let state = parsed.one("state")
        guard state == nil || state == "on" || state == "off" else {
            ctx.err("palaver app autostart: expected on or off")
            return 1
        }
        let on = state != "off"
        do {
            try Autostart.set(on, stores: ctx.stores)
        } catch {
            say("error: \(error)")
            return 1
        }
        say(on ? "Palaver starts at login." : "Autostart removed.")
        return 0
    }

    /// app_bundle `_quit_and_remove`: the app of this name in ~/Applications quit and deleted; nil when none is there.
    func quitAndRemove(_ name: String) throws -> URL? {
        let app = ctx.stores.applications.appendingPathComponent("\(name).app", isDirectory: true)
        guard Self.exists(app) else { return nil }
        ctx.quitApp(name)
        try FileManager.default.removeItem(at: app)
        return app
    }

    /// `app uninstall`: the login item and the app (under its earlier names too); recordings, settings and models stay.
    func uninstall() -> Int32 {
        var removed: [URL] = []
        do {
            let agent = ctx.stores.launchAgent
            if Self.exists(agent) {
                try FileManager.default.removeItem(at: agent)
                removed.append(agent)
            }
            for name in [Self.APP_NAME] + Self.OLD_APP_NAMES {
                if let app = try quitAndRemove(name) { removed.append(app) }
            }
        } catch {
            say("error: \(error)")
            return 1
        }
        say(removed.isEmpty ? "Nothing installed." : removed.map { "Removed \($0.path)" }.joined(separator: "\n"))
        return 0
    }

    /// `app install [--login] [--store-tokens]`. From a checkout: the app built by the Makefile (`make app`, its zip in
    /// dist/) in ~/Applications, in place of the one there; the permissions are asked again at its next start. From an
    /// installed app: it is installed already (install.sh installs and updates it); only the login item and tokens.
    func install() -> Int32 {
        if parsed.flag("--store-tokens") {
            let keys = ctx.keys()
            var stored: [String] = []
            for name in [Tokens.NOTION, Tokens.HF] {
                guard let value = ctx.env[name], !value.isEmpty else { continue }
                do { try keys.write(name, value) } catch {
                    say("error: \(name) was not stored: \(error)")
                    return 1
                }
                stored.append(name)
            }
            say("Stored \(stored.isEmpty ? "no tokens (none set in this shell)" : stored.joined(separator: ", ")) in the login Keychain.")
        }
        let location = AppLocation(executable: ctx.executable)
        let login = parsed.flag("--login")
        let atLogin = login || Self.exists(ctx.stores.launchAgent)  // an agent from before may open the old name
        if let bundle = location.bundle {
            if atLogin, (try? Autostart.set(true, stores: ctx.stores)) == nil {
                say("error: the login item was not written")
                return 1
            }
            say("\(bundle.path) is installed (install.sh installs and updates it)" + (login ? "; it starts at login." : "."))
            return 0
        }
        guard let checkout = location.checkout else {
            say("error: palaver app install builds the app from a checkout; this palaver is in neither a checkout nor Palaver.app")
            return 1
        }
        if let busy = Self.busy(ctx.stores.daemonJson) {
            say("Palaver is \(busy) now: install it again once it is idle (palaver daemon status), so nothing is cut short.")
            return 1
        }
        say("Building Palaver.app with the Makefile (make app)…")
        guard ctx.run(["/usr/bin/make", "-C", checkout.path, "app"], nil) == 0 else {
            say("error: make app failed; nothing was installed")
            return 1
        }
        let zip = checkout.appendingPathComponent("dist/palaver-app-\(location.version()).zip")
        guard Self.exists(zip) else {
            say("error: make app left no \(zip.path); nothing was installed")
            return 1
        }
        let apps = ctx.stores.applications
        let app = apps.appendingPathComponent("\(Self.APP_NAME).app", isDirectory: true)
        let staging = apps.appendingPathComponent(".palaver-install-\(getpid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
            for name in Self.OLD_APP_NAMES { _ = try quitAndRemove(name) }
            try? FileManager.default.removeItem(at: staging)
            guard ctx.run(["/usr/bin/ditto", "-xk", zip.path, staging.path], nil) == 0,
                  Self.exists(staging.appendingPathComponent("\(Self.APP_NAME).app")) else {
                try? FileManager.default.removeItem(at: staging)
                say("error: \(zip.lastPathComponent) holds no Palaver.app; nothing was installed")
                return 1
            }
            // `make app` took minutes: is the app still idle? Replacing the bundle makes a running app quit.
            if let busy = Self.busy(ctx.stores.daemonJson) {
                try? FileManager.default.removeItem(at: staging)
                say("Palaver is \(busy) now: install it again once it is idle (palaver daemon status), so nothing is cut short.")
                return 1
            }
            try Self.swap(staging.appendingPathComponent("\(Self.APP_NAME).app"), into: app, staging: staging)
            // A new build is a new signature to macOS, which asks for System Audio Recording again: ask at the next
            // launch, not during a meeting.
            try? FileManager.default.removeItem(at: ctx.stores.permissionsMarker)
            if atLogin { try Autostart.set(true, stores: ctx.stores) }
        } catch {
            say("error: \(error)")
            return 1
        }
        say("Installed \(app.path)" + (login ? " (starts at login)" : ""))
        say("Open it, then allow Microphone and System Audio Recording for\nPalaver when macOS asks. `palaver doctor` run from\n"
            + "Terminal checks the terminal's permissions, not the app's.")
        return 0
    }

    /// `new` in place of the bundle at `app` (the one there set aside in `staging` first); when that fails, the one
    /// there is put back. `staging` is gone afterwards either way.
    static func swap(_ new: URL, into app: URL, staging: URL,
                     move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        defer { try? FileManager.default.removeItem(at: staging) }
        let old = staging.appendingPathComponent("previous.app", isDirectory: true)
        let hadOne = exists(app)
        if hadOne { try move(app, old) }
        do {
            try move(new, app)
        } catch {
            if hadOne { try? FileManager.default.moveItem(at: old, to: app) }
            throw error
        }
    }

    /// Something is at `url` (a link that leads nowhere too).
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// "recording" or "transcribing" when daemon.json names a live app doing it; nil when it is idle or not running.
    static func busy(_ daemonJson: URL) -> String? {
        guard let state = DaemonFile.read(daemonJson), let pid = state["pid"]?.doubleValue, pid > 0, pid < Double(Int32.max),
              kill(Int32(pid), 0) == 0 || errno == EPERM, state["state"] != .string("stopped") else { return nil }
        if state["state"] == .string("recording") { return "recording" }
        if state["transcribing"]?.truthy == true { return "transcribing" }
        return nil
    }
}
