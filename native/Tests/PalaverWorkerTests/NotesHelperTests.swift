// The worker's notes step without a usable palaver-lm: no notes, and the meeting's log and stderr say where it was
// looked for (never Python instead).
import Foundation
import PalaverCore
@testable import PalaverDomain
@testable import PalaverWorker
import Testing

@Suite struct NotesHelperTests {
    @Test(arguments: ["missing", "not executable", "none"]) func aMissingPalaverLMWritesNoNotesAndSaysWhere(_ how: String) throws {
        let t = Temp(); defer { t.remove() }
        let h = Harness(t)
        let folder = h.config.outputDir.appendingPathComponent("2026-10-20T14-35-17", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var setup = h.setup(fake("{}"))
        switch how {
        case "missing": setup.lm = t.file("palaver-lm").path
        case "not executable":
            t.write("palaver-lm", "#!/bin/sh\nexit 0\n")  // there, but not a program
            setup.lm = t.file("palaver-lm").path
        default: setup.lm = nil
        }
        let log = SessionLog(url: RecordingPaths(folder).sessionLog, logger: "palaver.worker")
        #expect(Pipeline.runNotesHelper(folder, setup, log: log) == false)
        let text = (try? String(contentsOf: RecordingPaths(folder).sessionLog, encoding: .utf8)) ?? ""
        #expect(text.contains("palaver-lm is missing"))
        if how != "none" { #expect(text.contains("(looked for \(t.file("palaver-lm").path))")) }
    }
}
