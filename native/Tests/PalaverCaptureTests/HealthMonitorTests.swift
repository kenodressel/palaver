import Foundation
import PalaverCore
import Testing
@testable import PalaverCapture

// The monitor as the recorder drives it: events with Python's names and fields, audio_problems.json.

private struct Event: Sendable { let level: String; let name: String; let fields: [String: String] }

private final class Harness: @unchecked Sendable {
    let dir = tempDir()
    let events = Locked<[Event]>([])
    let debug = Locked<[String]>([])
    var file: URL { dir.appendingPathComponent("audio_problems.json") }
    let monitor: AudioHealthMonitor
    init(fileSystem: ProblemsFileSystem = .real) {
        let events = events, debug = debug
        monitor = AudioHealthMonitor(
            problemsURL: dir.appendingPathComponent("audio_problems.json"),
            events: { level, name, fields in
                events.with { $0.append(Event(level: level, name: name, fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.0, JSONLines.value($0.1)) }))) }
            },
            debug: { line in debug.with { $0.append(line) } },
            wall: { ISO8601DateFormatter().date(from: "2026-10-29T12:06:00+01:00")! },
            timeZone: TimeZone(secondsFromGMT: 3600)!, fileSystem: fileSystem)
    }
    func status(_ now: Double, micStalled: Bool = false, dropped: [CaptureTrack: Int] = [:],
                writeFailures: [CaptureTrack: String] = [:]) -> CaptureStatus {
        CaptureStatus(now: now, written: [:], startPts: nil, access: [:], micStalled: micStalled, systemStalled: false,
                      writeFailures: writeFailures, dropped: dropped)
    }
    func json() throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
    }
}

@Suite struct HealthMonitorTests {
    @Test func anOpeningIncidentIsLoggedAndKept() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))
        let e = try #require(h.events.get.first)
        #expect(e.level == "WARNING" && e.name == "audio_problem")
        #expect(e.fields["kind"] == "\"stalled\"" && e.fields["track"] == "\"mic\"")
        #expect(e.fields["start"] == "40.0" && e.fields["at"] == "\"2026-10-29T12:06:00+01:00\"")
        #expect(e.fields["text"] == "\"No microphone audio is arriving\"" && e.fields["reanchors_per_minute"] == "0")
        let kept = try h.json()
        #expect(kept.count == 1 && kept[0]["kind"] as? String == "stalled" && kept[0]["id"] == nil)
        #expect(kept[0]["end"] is NSNull && kept[0]["start"] as? Double == 40.0)
    }

    @Test func anEndingIncidentIsLoggedAndTheFileUpdated() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))
        try h.monitor.check(h.status(1041))
        let over = try #require(h.events.get.last)
        #expect(over.level == "INFO" && over.name == "audio_problem_over")
        #expect(over.fields == ["kind": "\"stalled\"", "track": "\"mic\"", "end": "41.0"])
        #expect(try h.json()[0]["end"] as? Double == 41.0)
    }

    @Test func noFileWhileThereAreNoIncidents() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1001))
        try h.monitor.close(now: 1002)
        #expect(!FileManager.default.fileExists(atPath: h.file.path))
        #expect(!FileManager.default.fileExists(atPath: h.file.path + ".tmp"))
    }

    @Test func theStopEndsWhatIsOpenAndKeepsIt() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))
        try h.monitor.close(now: 1050)
        #expect(try h.json()[0]["end"] as? Double == 50.0)
        #expect(h.monitor.openProblems.isEmpty && h.monitor.problems.count == 1)
    }

    @Test func aNewRecordingStartsAfresh() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))
        try h.monitor.begin(now: 2000)
        #expect(h.monitor.problems.isEmpty)
    }

    @Test func theFileIsWrittenThroughTmpAndRenamed() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))
        // Both indents of Python's json.dumps(indent=2).
        let text = try String(contentsOf: h.file, encoding: .utf8)
        #expect(text.hasPrefix("[\n  {\n    \"kind\": \"stalled\",\n    \"track\": \"mic\",\n"))
        #expect(text.hasSuffix("\n  }\n]"))
        #expect(!FileManager.default.fileExists(atPath: h.file.path + ".tmp"))
    }

    @Test func aFailingFileSystemOnlyLogsADebugLine() throws {
        let fs = ProblemsFileSystem(exists: { _ in false }, writeAtomically: { _, _ in throw CaptureError("disk full") })
        let h = Harness(fileSystem: fs)
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1040, micStalled: true))  // does not throw
        #expect(h.debug.get.first?.hasPrefix("could not keep the audio problems") == true)
        #expect(h.events.get.count == 1)
    }

    @Test func droppedBuffersAndWriteFailuresReachTheLogAndTheFile() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        try h.monitor.check(h.status(1001, dropped: [.system: 4], writeFailures: [.mic: "No space left on device"]))
        let names = h.events.get.map { "\($0.name)/\($0.fields["kind"]!)/\($0.fields["track"]!)" }
        #expect(names == ["audio_problem/\"dropped\"/\"system\"", "audio_problem/\"write\"/\"mic\""])
        #expect(h.events.get[1].fields["text"]!.contains("cannot be written to disk"))
        #expect(try h.json().map { $0["kind"] as! String } == ["dropped", "write"])
    }

    @Test func reanchorsAreCountedAndTheAnswerIsWhetherASpeedIncidentIsOpen() throws {
        let h = Harness()
        try h.monitor.begin(now: 1000)
        #expect(try h.monitor.reanchor(.system, now: 1001, drift: 0.01) == false)
        #expect(try h.monitor.reanchor(.system, now: 1002, drift: 0.01) == false)
        try h.monitor.check(h.status(1040, micStalled: true))
        #expect(h.events.get[0].fields["reanchors_per_minute"] == "0")  // the mic's, not the system's
    }
}
