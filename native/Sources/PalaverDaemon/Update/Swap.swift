// The swap (updater.py's _SWAP and Installer.prepare/commit, #60), run by /bin/sh after Palaver has quit: it is
// not Palaver's child and outlives the app. The old app goes aside into previous-app, the new one takes its place
// and opens; once the new one says it started (its started-ok mark, `Updates.started`), the old one goes. If it does
// not start, or the swap fails, the old one comes back, opens, and update.json says why (`Updates.load` reads it).
// The same script as 0.5's: the releases before keep running theirs (tests/fixtures/updater_0.3.14).
import Foundation
import PalaverCore

public enum UpdateSwap {
    /// Where the swap works: `support` is ~/Library/Application Support/palaver.
    public struct Places: Sendable {
        public var target: URL
        public var staged: URL
        public var support: URL
        public init(target: URL, staged: URL, support: URL) { self.target = target; self.staged = staged; self.support = support }
        public var keep: URL { support.appendingPathComponent("previous-app", isDirectory: true) }
        public var startedOk: URL { support.appendingPathComponent("started-ok") }
        public var status: URL { support.appendingPathComponent("update.json") }
        public var script: URL { support.appendingPathComponent("updates/swap.sh") }
    }

    /// `'…'` for /bin/sh.
    public static func sh(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// What update.json says when the swap fails (no `'`: it sits in single quotes in the script).
    static func failure(_ error: String, version: String) -> String {
        JSONValue.object([("state", .string("failed")), ("from_swap", .bool(true)), ("error", .string(error)),
                          ("available", .object([("version", .string(version))]))])
            .encoded(indent: nil).replacingOccurrences(of: "'", with: "")
    }

    /// The script's text. `current`: the version that runs (nil: unknown); `pids`: what must have quit first;
    /// `startTimeout`: seconds the new version has to write started-ok.
    public static func script(current: String?, version: String, places: Places, pids: [Int32],
                              open: String = "/usr/bin/open", startTimeout: Double = 120) -> String {
        let old = current ?? "the version before"
        let notReplaced = failure("Palaver \(version) could not replace the app; \(old) stays.", version: version)
        let didNotStart = failure("Palaver \(version) did not start; \(old) is back.", version: version)
        let ticks = max(1, Int(startTimeout / 0.2))
        return """
            #!/bin/sh
            # Palaver's update from \(old) to \(version).
            target=\(sh(places.target.path))
            staged=\(sh(places.staged.path))
            keep=\(sh(places.keep.path))
            ok=\(sh(places.startedOk.path))
            status=\(sh(places.status.path))
            reopen() { \(open) "$target"; }
            failed() { printf '%s\\n' "$1" > "$status"; }

            # The app quits first: wait as long as it takes, a recording is finished on the way.
            for pid in \(pids.map { String($0) }.joined(separator: " ")); do
              while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            done
            # Anything else still running from this app (its window's server stopping): a little longer.
            n=0
            while pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done

            rm -rf "$keep" && mkdir -p "$keep" || { failed '\(notReplaced)'; reopen; exit 1; }
            if ! mv "$target" "$keep/Palaver.app"; then
              failed '\(notReplaced)'; reopen; exit 1
            fi
            if ! mv "$staged" "$target"; then
              mv "$keep/Palaver.app" "$target"; failed '\(notReplaced)'; reopen; exit 1
            fi
            rm -f "$ok"
            reopen
            n=0
            while [ "$n" -lt \(ticks) ]; do
              if [ "$(cat "$ok" 2>/dev/null)" = \(sh(version)) ]; then
                rm -rf "$keep"
                exit 0
              fi
              sleep 0.2; n=$((n + 1))
            done
            # The new version did not start: the one before comes back. The app itself is ended (the Swift app,
            # or the launcher of a version before 0.5), never a worker: they stop with it.
            pkill -TERM -f "$target/Contents/MacOS/(palaver-launcher|Palaver)\\$" 2>/dev/null
            n=0
            while pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n + 1)); done
            rm -rf "$keep/failed.app"
            mv "$target" "$keep/failed.app" && mv "$keep/Palaver.app" "$target" && rm -rf "$keep"
            failed '\(didNotStart)'
            reopen

            """
    }

    /// Installer.prepare: swap.sh written into updates/ (its path).
    @discardableResult
    public static func prepare(_ staged: StagedUpdate, current: String?, places: Places, pids: [Int32],
                               open: String = "/usr/bin/open", startTimeout: Double = 120) throws -> URL {
        let text = script(current: current, version: staged.version, places: places, pids: pids, open: open, startTimeout: startTimeout)
        try FileManager.default.createDirectory(at: places.script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: places.script, atomically: true, encoding: .utf8)
        return places.script
    }

    /// Installer.commit: the swap is certain. A new build is a new signature to macOS: the restarted app asks for
    /// its permissions at once, while idle, not in the middle of the next call. (No runtime is remembered for
    /// going back: 0.6 and later have none.)
    public static func commit(support: URL) {
        unlink(support.appendingPathComponent("permissions-requested").path)
    }
}
