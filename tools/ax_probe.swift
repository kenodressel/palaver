// A spike, not part of the app: does Teams' or Slack's call window say through Accessibility who is speaking?
// It reads the app's accessibility tree every --every seconds during a call (no audio, nothing recorded) and writes
// what changed between two reads, so a call's log shows which element changes when someone starts or stops talking.
//
//   swiftc -O tools/ax_probe.swift -o .build/ax-probe && .build/ax-probe teams
//
// The terminal it runs in needs Accessibility (System Settings → Privacy & Security → Accessibility). Press Enter in
// the terminal whenever you start talking: a "mark" in the log to line the changes up with. Ctrl-C ends it.
// The log holds participants' names and whatever the window shows: it stays on this Mac
// (~/Library/Logs/palaver-ax-probe), never in the repository.
import AppKit
import ApplicationServices
import Foundation

let apps = ["teams": ["com.microsoft.teams2", "com.microsoft.teams"], "slack": ["com.tinyspeck.slackmacgap"]]
let attributes = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXDOMIdentifier",
                  "AXDOMClassList", "AXSelected", "AXRoleDescription"]
let maxElements = 20_000
/// The call's controls: the subtree around one of them is what is read (a main window has 20 000+ elements).
let markers: [String: (AXUIElement) -> Bool] = [
    "teams": { string($0, "AXDOMIdentifier") == "microphone-button" },
    "slack": { ["Leave huddle", "Huddles actions"].contains(string($0, "AXDescription") ?? string($0, "AXTitle") ?? "") },
]
/// The call's area: the highest ancestor of the marker with at most this many elements.
let maxArea = 3_000
let interesting = try! NSRegularExpression(
    pattern: "speak|talk|spricht|redet|sprechen|audio|mute|stumm|voice|active", options: [.caseInsensitive])

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return fallback }
    args.removeSubrange(i...(i + 1))
    return v
}
let every = option("--every", 0.5)
let minutes = option("--minutes", 90)
let which = args.first ?? "teams"
guard let bundleIds = apps[which] else {
    print("usage: ax-probe [teams|slack] [--every seconds] [--minutes n]")
    exit(2)
}

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("This terminal may not use Accessibility yet: allow it under System Settings → Privacy & Security → "
        + "Accessibility, then quit and reopen the terminal and run this again.")
    exit(1)
}
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/palaver-ax-probe/\(stamp)-\(which)", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: dir.appendingPathComponent("changes.jsonl").path, contents: nil)
let changes = try! FileHandle(forWritingTo: dir.appendingPathComponent("changes.jsonl"))
let started = Date()
let lock = NSLock()

func write(_ handle: FileHandle, _ object: [String: Any]) {
    var o = object
    o["t"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
    guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
    lock.withLock { handle.write(data + Data("\n".utf8)) }
}

func string(_ e: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

func parent(_ e: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &value) == .success, let v = value else { return nil }
    return (v as! AXUIElement)
}

/// How many elements under `e`, counting at most `cap + 1`.
func size(_ e: AXUIElement, cap: Int) -> Int {
    var queue = [e], next = 0
    while next < queue.count, queue.count <= cap {
        queue.append(contentsOf: children(queue[next]))
        next += 1
    }
    return queue.count
}

/// The call's area in the app: the marker found breadth first, then its highest ancestor of at most maxArea elements.
func callArea(_ pid: pid_t) -> AXUIElement? {
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)  // Electron/Chromium
    AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    var queue = [root], next = 0
    var marker: AXUIElement?
    while next < queue.count, next < 60_000 {
        let e = queue[next]
        next += 1
        if markers[which]!(e) { marker = e; break }
        queue.append(contentsOf: children(e))
    }
    guard var area = marker else { return nil }
    while let up = parent(area), size(up, cap: maxArea) <= maxArea { area = up }
    return area
}

/// One element as read: its attributes (as text) and the label of the nearest ancestor that has one.
struct Node { var attrs: [String: String]; var context: String }

func text(_ value: AnyObject?) -> String? {
    switch value {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    case let a as [String]: return a.isEmpty ? nil : a.joined(separator: " ")
    case let a as [Any]: return a.isEmpty ? nil : a.map { "\($0)" }.joined(separator: " ")
    default: return nil
    }
}

/// The call's area, breadth first; an element's key is its path of child indices (stable while the tree is).
func read(_ root: AXUIElement) -> [String: Node] {
    var out: [String: Node] = [:]
    var queue: [(AXUIElement, String, String)] = [(root, "app", "")]
    var next = 0
    while next < queue.count, out.count < maxElements {
        let (e, key, context) = queue[next]
        next += 1
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(e, attributes as CFArray, [], &values)
        var attrs: [String: String] = [:]
        for (i, v) in ((values as? [AnyObject]) ?? []).enumerated() where i < attributes.count {
            if CFGetTypeID(v) == AXValueGetTypeID() { continue }  // an AXError placeholder or a geometry value
            if let s = text(v) { attrs[attributes[i]] = s }
        }
        let label = attrs["AXDescription"] ?? attrs["AXTitle"] ?? attrs["AXValue"]
        out[key] = Node(attrs: attrs, context: context)
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            for (i, c) in list.enumerated() { queue.append((c, "\(key)/\(i)", label.map { String($0.prefix(80)) } ?? context)) }
        }
    }
    return out
}

func appPid() -> pid_t? {
    for id in bundleIds { if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a.processIdentifier } }
    return nil
}

func snapshot(_ nodes: [String: Node], _ name: String) {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
    let h = try! FileHandle(forWritingTo: dir.appendingPathComponent(name))
    for (key, n) in nodes.sorted(by: { $0.key < $1.key }) where !n.attrs.isEmpty {
        write(h, ["key": key, "attrs": n.attrs, "context": n.context])
    }
    try? h.close()
}

// Enter in the terminal: a mark ("I start talking now").
Thread.detachNewThread {
    var n = 0
    while readLine() != nil {
        n += 1
        write(changes, ["mark": n])
        print("mark \(n)")
    }
}
signal(SIGINT) { _ in
    try? changes.synchronize()
    print("\nstopped; the log is in the folder printed at the start")
    exit(0)
}

print("Reading \(which)'s accessibility tree every \(every) s for at most \(Int(minutes)) min.")
print("Log: \(dir.path)")
print("Press Enter whenever you start talking; Ctrl-C ends it.")
var previous: [String: Node] = [:]
var lastSnapshot = -1.0
var area: AXUIElement?
var areaFound = -100.0
while Date().timeIntervalSince(started) < minutes * 60 {
    let tick = Date()
    guard let pid = appPid() else {
        write(changes, ["note": "\(which) is not running"])
        Thread.sleep(forTimeInterval: 5)
        continue
    }
    if area == nil && Date().timeIntervalSince(started) - areaFound > 5 || Date().timeIntervalSince(started) - areaFound > 30 {
        let found = callArea(pid)
        if (found == nil) != (area == nil) || areaFound < 0 {
            print(found == nil ? "no call controls found: waiting for a call" : "call found")
        }
        if let found, let area, !CFEqual(found, area) { previous = [:] }
        area = found
        areaFound = Date().timeIntervalSince(started)
    }
    guard let current = area else {
        Thread.sleep(forTimeInterval: 2)
        continue
    }
    let nodes = read(current)
    if nodes.count <= 1 {  // the call window closed: look again
        area = nil
        areaFound = -100
        continue
    }
    let took = Date().timeIntervalSince(tick)
    let elapsed = Date().timeIntervalSince(started)
    if elapsed - lastSnapshot >= 60 || lastSnapshot < 0 {
        snapshot(nodes, String(format: "tree-%03d.jsonl", Int(elapsed / 60)))
        lastSnapshot = elapsed
        write(changes, ["tree": nodes.count, "read_seconds": (took * 1000).rounded() / 1000])
    }
    var appeared = 0, gone = 0
    for (key, n) in nodes {
        guard let before = previous[key] else { appeared += 1; continue }
        var changed: [String: [String]] = [:]
        for name in Set(n.attrs.keys).union(before.attrs.keys) where n.attrs[name] != before.attrs[name] {
            changed[name] = [before.attrs[name] ?? "", n.attrs[name] ?? ""]
        }
        guard !changed.isEmpty else { continue }
        write(changes, ["key": key, "changed": changed, "role": n.attrs["AXRole"] ?? "", "context": n.context])
        let all = changed.values.flatMap { $0 }.joined(separator: " ")
        if interesting.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) != nil {
            print(String(format: "%7.1f s  %@: %@", elapsed, n.context.isEmpty ? key : n.context,
                         changed.map { "\($0.key) \($0.value[0]) → \($0.value[1])" }.joined(separator: "; ")))
        }
    }
    for key in previous.keys where nodes[key] == nil { gone += 1 }
    if !previous.isEmpty && (appeared > 0 || gone > 0) { write(changes, ["appeared": appeared, "gone": gone]) }
    previous = nodes
    Thread.sleep(forTimeInterval: max(0, every - Date().timeIntervalSince(tick)))
}
print("done after \(Int(minutes)) min")
