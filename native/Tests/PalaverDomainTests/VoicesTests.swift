// The voice bank and recognition (voices.py, test_voices.py; the voice tests of test_attribution.py), and the numbers
// Python computes over 256-number voices (golden `voices`).
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct VoicesTests {
    private func folder() -> TempFolder { TempFolder("voices") }
    private func bank(_ t: TempFolder) -> VoiceBank { VoiceBank(directory: t.url.appendingPathComponent("palaver/voices", isDirectory: true)) }
    /// `_unit(*v)` of the Python tests: the vector over its norm.
    private func unit(_ v: Double...) -> [Double] { VoiceMath.unit(v) }
    private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func test_bank_lives_in_config_dir_one_file_per_person() throws {
        let t = folder(); defer { t.remove() }
        let stores = StorePaths.current(env: ["XDG_CONFIG_HOME": t.url.path, "PALAVER_HOME": t.url.appendingPathComponent("home").path])
        let bank = VoiceBank(directory: stores.voices)
        try bank.add("Anna Müller", unit(1, 0, 0), source: "2026-10-20T14-35-17:SPEAKER_00")
        let dir = t.url.appendingPathComponent("palaver/voices")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        #expect(files.count == 1)
        let data = try #require(PythonJSON.read(dir.appendingPathComponent(files[0])))
        #expect(data["name"]?.stringValue == "Anna Müller")
        #expect(data["samples"]?.arrayValue?.first?["source"]?.stringValue == "2026-10-20T14-35-17:SPEAKER_00")
        #expect(try VoiceBank(directory: stores.voices).names() == PyDict([("Anna Müller", 1)]))
    }

    @Test func test_add_ignores_duplicate_source() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "m1:SPEAKER_00")
        try bank.add("Anna", unit(1, 0, 0), source: "m1:SPEAKER_00")
        #expect(try bank.names() == PyDict([("Anna", 1)]))
    }

    @Test func test_match_requires_threshold_and_margin() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        try bank.add("Ben", unit(0, 1, 0), source: "b")
        #expect(try bank.match(unit(1, 0.2, 0))?.0 == "Anna")
        #expect(try bank.match(unit(0.2, 0.2, 1)) == nil)  // nobody similar enough
        #expect(try bank.match(unit(1, 1, 0)) == nil)  // Anna and Ben too close to call
    }

    @Test func test_match_uses_best_sample_per_person() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(0, 0, 1), source: "old-room")
        try bank.add("Anna", unit(1, 0, 0), source: "new-room")
        #expect(try bank.match(unit(1, 0.1, 0))?.0 == "Anna")
    }

    /// #31: what a bank read is kept for every bank of the folder, until a file changes, also by another process.
    @Test func theBanksReadIsKeptUntilAFileChanges() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t), other = self.bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        #expect(try other.match(unit(1, 0.1, 0))?.0 == "Anna")
        try other.add("Ben", unit(0, 1, 0), source: "b")  // the other bank's write: this one sees it
        #expect(try bank.names() == PyDict([("Anna", 1), ("Ben", 1)]))
        // Another process rewrites Anna's file (Ben's voice now) and adds Carla's: both seen.
        let dir = t.url.appendingPathComponent("palaver/voices")
        let anna = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("anna") })
        let sample = { (v: [Double], source: String) in
            JSONValue.object([("embedding", .array(v.map(JSONValue.double))), ("source", .string(source)), ("added", .string("2026-11-12T08:00:00+01:00"))])
        }
        try Data(PythonJSON.dumps(.object([("name", .string("Anna")), ("samples", .array([sample(unit(0, 0, 1), "x")]))])).utf8)
            .write(to: dir.appendingPathComponent(anna))
        try Data(PythonJSON.dumps(.object([("name", .string("Carla")), ("samples", .array([sample(unit(1, 0, 0), "c")]))])).utf8)
            .write(to: dir.appendingPathComponent("carla.json"))
        #expect(try bank.match(unit(1, 0.1, 0))?.0 == "Carla")
        #expect(try bank.match(unit(0, 0.1, 1))?.0 == "Anna")
        #expect(try bank.forget("Carla") && (try other.names().keys) == ["Anna", "Ben"])
    }

    @Test func test_forget_removes_person() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        #expect(try bank.forget("anna"))  // case-insensitive
        #expect(try bank.names().isEmpty)
        #expect(try !bank.forget("Anna"))
    }

    @Test func test_recognize_skips_short_talkers() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        let found = try Voices.recognize(PyDict([("SPEAKER_00", unit(1, 0, 0)), ("SPEAKER_01", unit(1, 0, 0))]),
                                         talk: PyDict([("SPEAKER_00", 60.0), ("SPEAKER_01", 3.0)]), bank: bank)
        #expect(found.keys == ["SPEAKER_00"])
        #expect(found["SPEAKER_00"]?.0 == "Anna")
        #expect(approx(found["SPEAKER_00"]!.1, 1.0))
    }

    @Test func test_remove_source_takes_a_sample_away_from_whoever_has_it() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "m1:SPEAKER_00")
        try bank.add("Anna", unit(1, 0.1, 0), source: "m2:SPEAKER_03")
        try bank.add("Bob", unit(0, 1, 0), source: "m1:SPEAKER_01")
        #expect(try bank.owner("m1:SPEAKER_01") == "Bob")
        #expect(try bank.removeSource("m1:SPEAKER_01"))
        #expect(try bank.removeSource("m1:SPEAKER_00"))
        #expect(try bank.names() == PyDict([("Anna", 1)]))  // Bob had no samples left
        #expect(try bank.owner("m1:SPEAKER_00") == nil)
        #expect(try !bank.removeSource("m1:SPEAKER_00"))
    }

    @Test func test_recognize_among_invitees_is_less_strict() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        try bank.add("Ben", unit(0, 1, 0), source: "b")
        let nearAnna = PyDict([("SPEAKER_00", unit(1, 0.9, 0.2))])  // 0.73 Anna, 0.66 Ben: too close to call, below 0.75
        let talk = PyDict([("SPEAKER_00", 60.0)])
        #expect(try Voices.recognize(nearAnna, talk: talk, bank: bank).isEmpty)
        let found = try Voices.recognize(nearAnna, talk: talk, bank: bank, invited: ["Anna"])
        #expect(found["SPEAKER_00"]?.0 == "Anna")  // only Anna was invited
        #expect(try Voices.recognize(nearAnna, talk: talk, bank: bank, invited: ["Anna", "Ben"]).isEmpty)  // margin
    }

    @Test func test_recognize_falls_back_to_everyone_when_no_invitee_matches() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "a")
        try bank.add("Ben", unit(0, 1, 0), source: "b")
        let found = try Voices.recognize(PyDict([("SPEAKER_00", unit(0, 1, 0.05))]), talk: PyDict([("SPEAKER_00", 60.0)]),
                                         bank: bank, invited: ["Anna"])
        #expect(found["SPEAKER_00"]?.0 == "Ben")  // uninvited, but unmistakable
    }

    @Test func test_every_bank_writer_waits_for_the_voices_lock() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Anna", unit(1, 0, 0), source: "m1:SPEAKER_00")
        let lock = t.url.appendingPathComponent("palaver/voices.lock")  // beside voices/, as Python's `locked(voices)`
        let writers: [(String, () throws -> Void)] = [
            ("add", { try bank.add("Ben", self.unit(0, 1, 0), source: "m1:SPEAKER_01") }),
            ("rename", { try bank.rename("Ben", "Bea") }),
            ("removeSource", { try bank.removeSource("m1:SPEAKER_01") }),
            ("removeMeeting", { try bank.removeMeeting("m1") }),
            ("forget", { try bank.forget("Anna") }),
        ]
        for (what, write) in writers {
            let held = try LockHolder(lock, seconds: 0.4)
            let start = Date()
            try write()
            #expect(Date().timeIntervalSince(start) >= 0.3, "\(what) did not wait for voices.lock")
            held.wait()
        }
        #expect(try bank.names().isEmpty)
    }

    // test_attribution.py's voice tests.

    @Test func test_recognition_skips_a_name_the_user_rejected_for_a_voice_like_this() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)
        try bank.add("Tom", unit(1, 0, 0), source: "m0:SPEAKER_00")
        let voice = PyDict([("S", unit(1, 0.3, 0))])  // 0.96 alike Tom
        let talk = PyDict([("S", 60.0)])
        let found = try Voices.recognize(voice, talk: talk, bank: bank)
        #expect(found.keys == ["S"] && found["S"]?.0 == "Tom" && approx(found["S"]!.1, 0.958, 1e-3))
        let rejected = [("Tom", unit(1, 0.32, 0))]  // "this voice is not Tom", in another meeting
        #expect(try Voices.recognize(voice, talk: talk, bank: bank, rejected: rejected).isEmpty)
        let far = [("Tom", unit(0, 1, 0))]  // a different voice rejected as Tom says nothing about this one
        #expect(try Voices.recognize(voice, talk: talk, bank: bank, rejected: far)["S"] != nil)
    }

    @Test func test_not_tom_does_not_hand_the_voice_to_the_runner_up() throws {
        let t = folder(); defer { t.remove() }
        let bank = bank(t)  // a voice 0.86 alike Tom and 0.76 alike Ben (the reviewer's numbers)
        try bank.add("Tom", [0.86, (1 - 0.86 * 0.86).squareRoot(), 0.0], source: "m0:SPEAKER_00")
        try bank.add("Ben", [0.76, 0.0, (1 - 0.76 * 0.76).squareRoot()], source: "m0:SPEAKER_01")
        let voice = PyDict([("S", [1.0, 0.0, 0.0])]), talk = PyDict([("S", 60.0)])
        let found = try Voices.recognize(voice, talk: talk, bank: bank, invited: ["Tom"])
        #expect(found.keys == ["S"] && found["S"]?.0 == "Tom" && approx(found["S"]!.1, 0.86))
        let notTom = [("Tom", unit(1, 0, 0))]
        #expect(try Voices.recognize(voice, talk: talk, bank: bank, rejected: notTom).isEmpty)  // Ben is a guess by elimination
        // Nor among the invitees, where one left would need no margin.
        #expect(try Voices.recognize(voice, talk: talk, bank: bank, invited: ["Ben"], rejected: notTom).isEmpty)
        #expect(try Voices.recognize(voice, talk: talk, bank: bank, invited: ["Tom", "Ben"], rejected: notTom).isEmpty)
    }

    // MARK: - goldens: Python's numbers and files

    private static let added = try! NSRegularExpression(pattern: #""added": "[^"]*""#)

    /// The bank's files by name, each `"added": "…"` read as `"<added>"` (as goldens.py does).
    private func files(_ dir: URL) throws -> JSONValue {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
        return .object(try Py.stableSorted(names, by: Py.less).map { name in
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            return (name, .string(Self.added.stringByReplacingMatches(in: text, range: range, withTemplate: #""added": "<added>""#)))
        })
    }

    private func vector(_ v: JSONValue?) throws -> [Double] { try VoiceMath.vector(v, "golden vector") }

    @Test func test_a_sample_is_stamped_with_the_time_it_was_added() throws {
        let t = folder(); defer { t.remove() }
        let when = Date(timeIntervalSince1970: 1_793_000_000.75)
        let bank = VoiceBank(directory: t.url.appendingPathComponent("voices", isDirectory: true), now: { when })
        try bank.add("Valerie", [0.5, 0.25], source: "m:SPEAKER_00")
        let data = try #require(PythonJSON.read(t.url.appendingPathComponent("voices/valerie.json")))
        #expect(data["samples"]?.arrayValue?.first?["added"]?.stringValue == Py.isoNow(timespec: "seconds", now: when))
    }
}
