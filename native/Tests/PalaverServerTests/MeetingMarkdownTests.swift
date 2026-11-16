// A meeting as Markdown (#17): the file the ⋯ menu saves, the copy in every exported zip, and the folder mirrored for
// an Obsidian vault. Synthetic meetings only: Valerie records, Timo Strauß is the other side.
import Foundation
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverServer

private let ID = "2026-10-29T10-00-00"

private func write(_ v: JSONValue, _ url: URL) throws { try PythonJSON.write(v, to: url, indent: nil, ensureAscii: true) }
private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@discardableResult
private func meeting(_ root: URL, _ name: String = ID, title: String = "Budget review") throws -> RecordingPaths {
    let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
    try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
    try write(.object([("start_time", .string("2026-10-29T10:00:00+01:00")), ("duration_seconds", .int(1500))]), paths.meta)
    let utterances = [
        Utterance(speaker: "Valerie", start: 0, end: 2, text: "Hallo zusammen."),
        Utterance(speaker: "SPEAKER_00", start: 75, end: 80, text: "Das Budget steht.\nFür beide Teams.", label: "SPEAKER_00"),
    ]
    try write(.array(utterances.map(\.json)), paths.transcriptJson)
    try write(.object([("SPEAKER_00", .string("Timo Strauß"))]), paths.speakers)
    try NotesFile.save(paths, .object([
        ("title", .string(title)), ("summary", .string("SPEAKER_00 presented the budget.")),
        ("sections", .array([.object([("heading", .string("Budget")), ("points", .array([
            .object([("text", .string("Northwind pays half")), ("details", .strings(["from January"]))]),
        ]))])])),
        ("next_steps", .array([.object([("owner", .string("Timo Strauß")), ("task", .string("Send the figures"))]),
                               .object([("owner", .string("")), ("task", .string("Book a room"))])])),
        ("decisions", .strings(["Budget approved"])),
        ("speaker_names", .array([])), ("transcript_hash", .string(Notes.transcriptHash(utterances))),
    ]))
    return paths
}

private func server() throws -> TestServer {
    try TestServer(userName: "Valerie", meetings: { try meeting($0) })
}

private func mirrorTo(_ s: TestServer, _ folder: URL) -> Int {
    s.post("/api/markdown-folder", .object([(MeetingMarkdown.SETTING, .string(folder.path))])).status
}

@Suite struct MeetingMarkdownTests {
    @Test func aMeetingReadsAsItsPageShowsIt() throws {
        let s = try server()
        defer { s.stop() }
        let (name, md) = try MeetingMarkdown.markdown(s.app, id: ID)
        #expect(name == "2026-10-29 10-00 Budget review.md")
        #expect(md.hasPrefix("# Budget review\n\n2026-10-29 10:00 · 25 min · "))
        #expect(md.contains("## Summary\n\nTimo Strauß presented the budget.\n"))  // names as the page shows them
        #expect(md.contains("## Budget\n\n- Northwind pays half\n  - from January\n"))
        #expect(md.contains("## Next steps\n\n- [ ] **Timo Strauß**: Send the figures\n- [ ] Book a room\n"))
        #expect(md.contains("## Decisions\n\n- Budget approved\n"))
        #expect(md.contains("**Timo Strauß** [10:01:15]  Das Budget steht. Für beide Teams.\n"))  // one line, wall clock
        #expect(md.hasSuffix("\n") && !md.hasSuffix("\n\n"))
    }

    @Test func aLineIsAtTheMeetingsStartPlusItsOffset() {
        #expect(MeetingMarkdown.clock("2026-10-29T23:59:30+01:00", offset: 45) == "00:00:15")
        #expect(MeetingMarkdown.clock("", offset: 75) == "1:15")
    }

    @Test func saveAsMarkdownGoesToDownloadsAndNeverOverAnEarlierOne() throws {
        let s = try server()
        defer { s.stop() }
        let first = s.post("/api/meetings/\(ID)/markdown")
        #expect(first.status == 200 && first.json?["name"] == .string("2026-10-29 10-00 Budget review.md"))
        #expect(first.json?["folder"] == .string("Downloads"))
        let saved = s.app.downloads.appendingPathComponent("2026-10-29 10-00 Budget review.md")
        #expect(try text(saved).hasPrefix("# Budget review"))
        #expect(s.post("/api/meetings/\(ID)/markdown").json?["name"] == .string("2026-10-29 10-00 Budget review 2.md"))
    }

    @Test func theExportedZipHasAReadableCopyAndStillImports() throws {
        let s = try server()
        defer { s.stop() }
        let answer = s.post("/api/meetings/\(ID)/export", .object([("notes", .bool(false))])).json ?? .null
        let zip = s.app.downloads.appendingPathComponent(answer["name"]?.stringValue ?? "")
        let package = try Exchange.readPackage(zip)  // the import reads it: the copy is skipped
        #expect(package.meta["start"] != nil)
        let archive = try ExchangeZip.open(zip)
        let entries = try ExchangeZip.entries(archive).entries
        let entry = try #require(entries[Exchange.READABLE_COPY])
        let md = String(decoding: try archive.data(entry, limit: 1 << 20), as: UTF8.self)
        #expect(md.contains("**Timo Strauß** [10:01:15]"))
        #expect(!md.contains("## Next steps"))  // the notes stayed home, so did their copy
    }

    @Test func theFolderMirrorsEveryMeetingAndFollowsItsChanges() throws {
        let s = try server()
        defer { s.stop() }
        let vault = s.dir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let mine = vault.appendingPathComponent("2026-10-29 10-00 Budget review.md")
        try Data("my own note".utf8).write(to: mine)  // a file Palaver didn't write is never touched
        #expect(mirrorTo(s, vault) == 200)
        let written = vault.appendingPathComponent("2026-10-29 10-00 Budget review (2).md")
        #expect(try text(written).hasPrefix("# Budget review") && (try text(mine)) == "my own note")
        #expect(MeetingMarkdown.mirror(s.app) == (0, 0))  // nothing changed: nothing written

        try meeting(s.app.outputDir, title: "Budget review, final")  // the notes again, with another title
        #expect(MeetingMarkdown.mirror(s.app).written == 1)
        let renamed = vault.appendingPathComponent("2026-10-29 10-00 Budget review, final.md")
        #expect(exists(renamed) && !exists(written))

        try FileManager.default.removeItem(at: s.app.outputDir.appendingPathComponent(ID))
        #expect(MeetingMarkdown.mirror(s.app) == (0, 1))
        #expect(!exists(renamed) && exists(mine))
    }

    @Test func theFolderIsAFullPathOrNone() throws {
        let s = try server()
        defer { s.stop() }
        #expect(s.post("/api/markdown-folder", .object([(MeetingMarkdown.SETTING, .string("Documents/Meetings"))])).status == 400)
        #expect(s.post("/api/markdown-folder", .object([(MeetingMarkdown.SETTING, .string(""))])).status == 200)
        #expect(MeetingMarkdown.folder(stores: s.app.stores) == nil && MeetingMarkdown.mirror(s.app) == (0, 0))
        #expect(s.get("/api/markdown-folder").json?[MeetingMarkdown.SETTING] == .string(""))
    }
}
