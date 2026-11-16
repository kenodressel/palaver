import Foundation
import Testing
@testable import PalaverCore

/// An element of a fake Accessibility tree.
private final class Node: AXNode {
    let attributes: [String: String]
    let kids: [Node]
    private(set) var visits = 0
    init(_ attributes: [String: String] = [:], _ kids: [Node] = []) { self.attributes = attributes; self.kids = kids }
    func string(_ attribute: String) -> String? { attributes[attribute] }
    func children() -> [AXNode] { visits += 1; return kids }
}

private func button(_ id: String, _ label: String) -> Node {
    Node(["AXRole": "AXButton", "AXDOMIdentifier": id, "AXDescription": label])
}
private func text(_ s: String) -> Node { Node(["AXRole": "AXStaticText", "AXValue": s]) }
private func row(_ label: String, _ kids: [Node] = []) -> Node { Node(["AXRole": "AXGroup", "AXDescription": label], kids) }

/// New Teams' call window as Palaver expects it: the meeting's title in the window title, the mic button, a people
/// list ("In this meeting (3)") and a chat beside it, whose messages must never be read.
private func teamsCallWindow(title: String = "Northwind weekly | Microsoft Teams", roster: Bool = true) -> Node {
    let people = Node(["AXRole": "AXList", "AXDescription": "In this meeting (3)"], [
        row("Timo Strauß, Organizer", [text("Timo Strauß"), button("", "More options")]),
        row("Valerie (Guest), Muted"),
        row("Kim (External)"),
        row("Anna Lindqvist (You)"),
        button("", "Mute all"),
    ])
    let chat = Node(["AXRole": "AXGroup", "AXDOMIdentifier": "chat-pane-list"], [
        row("Carla"), text("Hi Anna"), text("Contoso"),
    ])
    let compose = Node(["AXRole": "AXTextArea", "AXValue": "Northwind"])
    let controls = Node(["AXRole": "AXToolbar"], [
        button("microphone-button", "Mute mic"), button("roster-button", "People"), button("chat-button", "Chat"),
        Node(["AXRole": "AXStaticText", "AXDOMIdentifier": "call-duration", "AXValue": "12:04"]),
    ])
    return Node(["AXRole": "AXWindow", "AXTitle": title], [controls] + (roster ? [people] : []) + [chat, compose])
}

private final class FakeReader: CallWindowReader {
    var reading: CallWindowReading = .noWindow
    var reads = 0
    func read() -> CallWindowReading { reads += 1; return reading }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite struct CallWindowTests {
    @Test func theCallWindowsTitleAndPeopleAreRead() {
        let main = Node(["AXRole": "AXWindow", "AXTitle": "Chat | Contoso | Microsoft Teams"], [text("Carla")])
        let info = TeamsCallWindow.read(windows: [main, teamsCallWindow()])
        #expect(info == CallWindowInfo(title: "Northwind weekly", participants: ["Timo Strauß", "Valerie", "Kim"]))
    }

    @Test func neverTheChatNorWhatIsTyped() {
        let info = TeamsCallWindow.read(windows: [teamsCallWindow()])!
        for word in ["Carla", "Hi Anna", "Contoso", "Northwind"] where word != info.title {
            #expect(!info.participants.contains(word))
        }
    }

    @Test func withoutTheMicButtonThereIsNoCallWindow() {
        let main = Node(["AXRole": "AXWindow", "AXTitle": "Calendar | Microsoft Teams"], [row("Timo Strauß")])
        #expect(TeamsCallWindow.read(windows: [main]) == nil)
        #expect(TeamsCallWindow.read(windows: []) == nil)
    }

    @Test func aWindowThatShowsNothingGivesNothing() {
        let bare = teamsCallWindow(title: "Meeting compact view | Microsoft Teams", roster: false)
        #expect(TeamsCallWindow.read(windows: [bare]) == CallWindowInfo())
    }

    @Test func theWalkIsBounded() {
        // A huge tree before the call's controls (a level of 10 000 elements above them): the walk stops, nothing is
        // made up.
        let deep = Node(["AXRole": "AXWindow", "AXTitle": "Northwind weekly | Microsoft Teams"],
                        (0..<100).map { _ in Node([:], (0..<100).map { _ in Node() }) }
                            + [Node([:], [button("microphone-button", "Mute mic")])])
        #expect(TeamsCallWindow.read(windows: [deep], maxElements: 1_000) == nil)
        var t = 0.0
        #expect(TeamsCallWindow.read(windows: [teamsCallWindow()], deadline: 1, now: { t += 1; return t }) == nil)
    }

    @Test func titles() {
        #expect(TeamsCallWindow.title("Northwind weekly | Microsoft Teams") == "Northwind weekly")
        #expect(TeamsCallWindow.title("Meeting | Contoso review | Microsoft Teams") == "Contoso review")
        #expect(TeamsCallWindow.title("Microsoft Teams") == nil)
        #expect(TeamsCallWindow.title("Chat | Microsoft Teams") == nil)
        #expect(TeamsCallWindow.title("00:12:04 | Microsoft Teams") == nil)
        #expect(TeamsCallWindow.title(nil) == nil)
        #expect(TeamsCallWindow.title(String(repeating: "x", count: 300))?.count == 200)
    }

    @Test func names() {
        #expect(TeamsCallWindow.personName("Timo Strauß, Organizer") == "Timo Strauß")
        #expect(TeamsCallWindow.personName("Valerie (Guest) (Unverified)") == "Valerie")
        #expect(TeamsCallWindow.personName("Anna (You)") == nil)
        #expect(TeamsCallWindow.personName("Mute all") == nil)
        #expect(TeamsCallWindow.personName("In this meeting (3)") == nil)
        #expect(TeamsCallWindow.personName("see you at 10:30") == nil)
        #expect(TeamsCallWindow.personName("thanks everyone") == nil)
        #expect(TeamsCallWindow.personName("I think we should ship it before the review") == nil)
        #expect(TeamsCallWindow.personName("anna@contoso.com") == nil)
    }

    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-callwin-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stored(_ dir: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("call-window.json").path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func theWatcherKeepsWhatItReadsAndLogsNoNames() {
        let dir = folder(), reader = FakeReader(), said = Said()
        let w = CallWindowWatcher(app: "teams", reader: reader, folder: dir,
                                  wall: { Date(timeIntervalSince1970: 1_772_614_800) }, timeZone: TimeZone(secondsFromGMT: 3600)!,
                                  schedule: false, log: { said.add($0) })
        w.check()
        #expect(stored(dir) == nil)  // no window yet
        reader.reading = .info(CallWindowInfo(title: "Northwind weekly", participants: ["Timo Strauß"]))
        w.check()
        reader.reading = .info(CallWindowInfo(title: nil, participants: ["Valerie", "timo strauß"]))
        w.check()
        let file = stored(dir)!
        #expect(file["app"] as? String == "teams")
        #expect(file["title"] as? String == "Northwind weekly")
        #expect(file["participants"] as? [String] == ["Timo Strauß", "Valerie"])
        #expect(file["read_at"] as? String == "2026-03-04T10:00:00+01:00")
        #expect(!said.all.joined().contains("Northwind") && !said.all.joined().contains("Timo"))
        #expect(said.all.filter { $0.contains("isn't found") }.count == 1)
    }

    @Test func notTrustedSaysSoOnceAndNeverWrites() {
        let dir = folder(), reader = FakeReader(), said = Said()
        reader.reading = .notTrusted
        let w = CallWindowWatcher(app: "teams", reader: reader, folder: dir, schedule: false, log: { said.add($0) })
        w.check(); w.check()
        #expect(stored(dir) == nil)
        #expect(said.all == ["Palaver may not use Accessibility: the meeting's title isn't read from Teams' call window"])
    }

    @Test func withACalendarEventNothingIsRead() {
        let dir = folder(), reader = FakeReader()
        reader.reading = .info(CallWindowInfo(title: "Northwind weekly"))
        let w = CallWindowWatcher(app: "teams", reader: reader, folder: dir, wanted: { false }, schedule: false, log: { _ in })
        w.check()
        #expect(reader.reads == 0 && stored(dir) == nil)
    }
}
