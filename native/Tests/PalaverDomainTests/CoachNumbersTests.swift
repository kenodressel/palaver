// The coach's numbers (coach.py, test_coach.py; two coach tests of test_shared_mic.py): one meeting, the cache, the
// history, the baseline on disk and the trends; then the goldens section `coach` (statistics, partial_ratio, analyze
// on random meetings, baseline, trends and highlights). `test_process_refreshes_the_baseline` is in the ledger.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct CoachNumbersTests {
    /// A temporary output dir and config dir.
    struct Place {
        let temp = TempFolder("coach")
        var root: URL { temp.url.appendingPathComponent("Recordings", isDirectory: true) }
        var stores: StorePaths {
            StorePaths.current(env: ["XDG_CONFIG_HOME": temp.url.appendingPathComponent("config").path,
                                     "PALAVER_HOME": temp.url.appendingPathComponent("home").path])
        }

        func remove() { temp.remove() }

        static func write(_ url: URL, _ value: JSONValue) {
            try! PythonJSON.write(value, to: url, indent: nil, ensureAscii: true)
        }

        /// test_coach.py's `_meeting`: meta.json, the transcript (labels for SPEAKER_xx) and no system turns.
        @discardableResult
        func meeting(_ name: String, _ lines: [(String, Double, Double, String)]) -> RecordingPaths {
            let paths = RecordingPaths(root.appendingPathComponent(name, isDirectory: true))
            try! FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            Self.write(paths.meta, .object([("start_time", .string("2026-10-27T10:00:00+01:00")), ("duration_seconds", .int(900))]))
            Self.write(paths.transcriptJson, .array(lines.map { who, s, e, t in
                var fields: [(String, JSONValue)] = [("speaker", .string(who)), ("start", .double(s)), ("end", .double(e)),
                                                     ("text", .string(t))]
                if who.hasPrefix("SPEAKER") { fields.append(("label", .string(who))) }
                return .object(fields)
            }))
            Self.write(paths.systemTurns, .array([]))
            return paths
        }
    }

    static let LINES: [(String, Double, Double, String)] = [
        ("Timo", 0, 100, "Also ich habe das halt irgendwie quasi so gedacht, halt ganz anders und irgendwie besser."),
        ("Timo", 101, 200, "Und dann halt nochmal, weil das halt wichtig ist und ich das so sehe, ähm, genau."),
        ("SPEAKER_00", 205, 230, "Okay, verstehe ich, und was machen wir mit dem Budget, das ist ja noch offen?"),
        ("Timo", 228, 240, "Das Budget klären wir morgen mit dem Team, ganz sicher."),  // cuts in at 228
        ("SPEAKER_00", 240.5, 241, "Ja."),
        ("Timo", 245, 250, "Wie siehst du das?"),
        ("SPEAKER_00", 254, 280, "Ich finde das gut, wir sollten aber die Kosten im Blick behalten."),
    ]

    static let usual: JSONValue = .object([
        ("share_1on1", .double(0.5)), ("share_group", .double(0.4)), ("wpm", .int(150)),
        ("fillers_per_minute", .object([("de", .double(1.0))])), ("meetings", .int(5)), ("questions_per_hour", .int(20)),
    ])

    private func dumps(_ v: JSONValue?) -> String { v.map { PythonJSON.dumps($0, ensureAscii: false) } ?? "nil" }

    // MARK: - test_coach.py

    @Test func test_numbers_of_one_meeting() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)
        let r = try Coach.analyze(p, userName: "Timo", invited: ["Valerie", "Carla"], names: PyDict([("SPEAKER_00", "Valerie")]),
                                  stores: place.stores)
        #expect(r["talk"]?["people"] == .int(2) && r["talk"]?["fair"] == .double(0.5))
        #expect(r["talk"]?["share"] == .double(Py.round(216 / (216 + 51.5), 3)))  // 100 + 99 + 12 + 5 s of mine
        #expect(dumps(r["monologues"]) == #"[{"start": 0.0, "seconds": 200}]"#)  // one stretch: 0-200 s, a 1 s gap
        let top = r["fillers"]?["top"]?.arrayValue ?? []
        #expect(top.first { $0["word"] == .string("halt") }?["count"] == .int(4))
        #expect(r["fillers"]?["hesitations"] == .int(1))
        #expect(r["questions"]?["count"] == .int(1) && r["questions"]?["open"] == .int(1) && r["questions"]?["wait"] == .double(4.0))
        #expect(r["questions"]?["kept_talking"] == .int(0))
        #expect(r["interruptions"]?["by_me"] == .int(1))
        #expect(dumps(r["interruptions"]?["by_me_at"]?.arrayValue?.first) == #"{"start": 228.0, "who": "Valerie"}"#)
        #expect(dumps(r["quiet_invitees"]) == #"[{"name": "Carla", "seconds": 0}]"#)
        #expect(r["language"] == .string("de"))
    }

    @Test func test_a_room_of_several_people_leaves_out_talk_share_monologues_and_quiet_invitees() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)
        Place.write(p.systemTurns, .array([.object([("speaker", .string("SPEAKER_00")), ("start", .int(205)), ("end", .int(280))])]))
        try SharedMic.setLane(p, "SPEAKER_00", true, name: "Lab")
        let r = try Coach.analyze(p, userName: "Timo", invited: ["Valerie", "Carla"], stores: place.stores)
        #expect(r["talk"]?["share"] == .null && r["talk"]?["fair"] == .null && r["talk"]?["shared"] == .bool(true))
        #expect(r["monologues"] == .array([]) && r["quiet_invitees"] == .array([]))
        #expect(r["questions"]?["count"] == .int(1) && r["fillers"]?["hesitations"] == .int(1))  // my own track stays
        let said = try Coach.highlights(r, Self.usual)
        #expect(!said.contains { $0.hasPrefix("You talked") || $0.hasPrefix("Longest stretch") || $0.hasPrefix("Barely heard") })
    }

    @Test func test_highlights_compare_with_what_is_usual() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)
        let r = try Coach.analyze(p, userName: "Timo", stores: place.stores)
        let said = try Coach.highlights(r, Self.usual)
        #expect(said[0].hasPrefix("You talked 81 % of the time; in 1:1s you usually talk 50 %"))
        #expect(said.contains { $0.hasPrefix("Longest stretch without anyone else: 3:20") })
        #expect(said.contains { $0.contains("“halt”") })
    }

    /// A hand-edited coach result or baseline with numbers past Int: the window's request fails, nothing traps.
    @Test func numbersPastIntInTheFilesThrowInsteadOfTrapping() throws {
        let place = Place(); defer { place.remove() }
        let r = try Coach.analyze(place.meeting("2026-10-27T10-00-00", Self.LINES), userName: "Timo", stores: place.stores)
        guard case .object(var fields) = r, case .object(var talk)? = r["talk"] else { Issue.record("no talk"); return }
        for share: JSONValue in [.double(1e300), .int(Int.max)] {
            talk = talk.map { $0.0 == "share" ? ("share", share) : $0 }
            fields = fields.map { $0.0 == "talk" ? ("talk", .object(talk)) : $0 }
            #expect(throws: Py.IntError.self) { try Coach.highlights(.object(fields), Self.usual) }
        }
        let rows: [JSONValue] = [.object([("start", .string("2026-10-27T10:00:00+01:00")), ("kind", .string("1:1")),
                                          ("minutes_talked", .int(10)), ("talk", .object([("share", .double(0.5))])),
                                          ("pace", .object([("wpm", .double(.infinity))])),
                                          ("fillers", .object([("per_minute", .double(1))]))])]
        #expect(throws: Py.IntError.self) { try Coach.trends(rows) }
    }

    /// The coach half: the window's `coach_meeting` and `coach_overview` (api.py) go with the window's routes.
    @Test func test_the_window_gets_numbers_and_an_overview() throws {
        let place = Place(); defer { place.remove() }
        place.meeting("2026-10-27T10-00-00", Self.LINES)
        let history = Coach.history(place.root, userName: "Timo", stores: place.stores, cache: Coach.Cache())
        let base = try Coach.baseline(history)
        #expect(base["meetings"] == .int(1))
        #expect(try !Coach.highlights(history[0], base).isEmpty)
        let trends = try Coach.trends(history)
        #expect(dumps(trends["weeks"]) == dumps(.array([.object([
            ("week", .string("2026-10-26")), ("meetings", .int(1)), ("share", .double(0.807)),
            ("wpm", history[0]["pace"]!["wpm"]!), ("fillers", history[0]["fillers"]!["per_minute"]!),
        ])])))
        #expect(trends["kinds"]?.arrayValue?.map { $0["kind"] } == [.string("1:1")])
    }

    @Test func test_results_are_kept_until_the_meeting_changes() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)
        let cache = Coach.Cache()
        let first = try Coach.result(p, userName: "Timo", stores: place.stores, cache: cache)
        #expect(try Coach.result(p, userName: "Timo", stores: place.stores, cache: cache) == first)
        #expect(cache.analyzed.count == 1)
        var st = stat()
        stat(p.transcriptJson.path, &st)
        var times = [st.st_atimespec, timespec(tv_sec: st.st_mtimespec.tv_sec + 1, tv_nsec: st.st_mtimespec.tv_nsec)]
        #expect(utimensat(AT_FDCWD, p.transcriptJson.path, &times, 0) == 0)
        _ = try Coach.result(p, userName: "Timo", stores: place.stores, cache: cache)
        #expect(cache.analyzed.count == 2)
    }

    @Test func test_a_file_time_beyond_int_nanoseconds_does_not_trap() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)
        var times = [timespec(tv_sec: 32_503_680_000, tv_nsec: 5), timespec(tv_sec: 32_503_680_000, tv_nsec: 5)]  // year 3000
        #expect(utimensat(AT_FDCWD, p.transcriptJson.path, &times, 0) == 0)
        let cache = Coach.Cache()
        let first = try Coach.result(p, userName: "Timo", stores: place.stores, cache: cache)
        #expect(try Coach.result(p, userName: "Timo", stores: place.stores, cache: cache) == first)
        #expect(cache.analyzed.count == 1)
    }

    @Test func test_history_has_every_meeting_with_its_day_and_kind() throws {
        let place = Place(); defer { place.remove() }
        place.meeting("2026-10-27T10-00-00", Self.LINES)
        place.meeting("2026-10-20T10-00-00", Self.LINES + [("SPEAKER_01", 300, 340, "Und ich sehe das auch so, das passt für uns gut.")])
        let h = Coach.history(place.root, userName: "Timo", stores: place.stores, cache: Coach.Cache())
        #expect(h.map { [$0["id"]!, $0["kind"]!] } == [[.string("2026-10-20T10-00-00"), .string("group")],
                                                      [.string("2026-10-27T10-00-00"), .string("1:1")]])
        #expect(h[0]["start"]?.stringValue?.hasPrefix("2026-10-27") == true)  // meta.json's start_time
    }

    private static func row(_ id: String, _ kind: String, _ share: Double, _ wpm: Int?, _ fillers: Double?,
                            lang: String = "de", minutes: Double = 10.0) -> JSONValue {
        .object([
            ("id", .string(id)), ("start", .string(String(id.prefix(10)) + "T10:00:00+01:00")), ("kind", .string(kind)),
            ("language", .string(lang)), ("minutes_talked", .double(minutes)),
            ("talk", .object([("share", .double(share)), ("people", .int(kind == "1:1" ? 2 : 4))])),
            ("pace", .object([("wpm", wpm.map { .int($0) } ?? .null)])),
            ("fillers", .object([("per_minute", fillers.map { .double($0) } ?? .null)])),
        ])
    }

    @Test func test_trends_per_week_and_per_kind() throws {
        let rows = [Self.row("2026-10-12T10-00-00", "1:1", 0.6, 150, 2.0),
                    Self.row("2026-10-14T10-00-00", "group", 0.2, 130, 1.0),
                    Self.row("2026-10-20T10-00-00", "group", 0.3, 140, 1.5),
                    Self.row("2026-10-21T10-00-00", "group", 0.5, nil, nil, minutes: 1.0)]
        let t = try Coach.trends(rows)
        let weeks = t["weeks"]?.arrayValue ?? []
        #expect(weeks.map { [$0["week"]!, $0["meetings"]!] } == [[.string("2026-10-12"), .int(2)], [.string("2026-10-19"), .int(2)]])
        #expect(weeks[0]["share"] == .double(0.4) && weeks[0]["wpm"] == .int(140) && weeks[0]["fillers"] == .double(1.5))
        #expect(weeks[1]["share"] == .double(0.4) && weeks[1]["wpm"] == .int(140))  // a meeting without pace leaves it out
        #expect(dumps(t["kinds"]) == #"[{"kind": "1:1", "meetings": 1, "share": 0.6, "wpm": 150, "fillers": 2.0}, "#
            + #"{"kind": "group", "meetings": 3, "share": 0.333, "wpm": 135, "fillers": 1.25}]"#)
    }

    @Test func test_only_the_last_weeks() throws {
        let rows = (1...10).map { Self.row(String(format: "2026-%02d-01T10-00-00", $0), "group", 0.3, 140, 1.0) }
        #expect(try Coach.trends(rows, weeks: 4)["weeks"]?.arrayValue?.count == 4)
        #expect(try Coach.trends(rows, weeks: 4)["weeks"]?.arrayValue?.last?["week"] == .string("2026-09-28"))
    }

    @Test func test_the_baseline_follows_the_recent_meetings() throws {
        func withQuestions(_ r: JSONValue) -> JSONValue {
            guard case .object(let fields) = r else { return r }
            return .object(fields + [("questions", .object([("per_hour", .int(5))]))])
        }
        let old = (1..<10).map { withQuestions(Self.row("2026-0\($0)-01T10-00-00", "1:1", 0.8, 180, 3.0)) }
        let new = (1...30).map { withQuestions(Self.row(String(format: "2026-10-%02dT10-00-00", $0), "1:1", 0.4, 130, 1.0)) }
        let base = try Coach.baseline(old + new)
        #expect(base["meetings"] == .int(Coach.BASELINE_MEETINGS) && base["share_1on1"] == .double(0.4) && base["wpm"] == .int(130))
    }

    @Test func test_an_earlier_name_of_mine_is_still_my_lane() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Self.LINES)  // recorded as "Timo"
        try SettingsFile.update([("user_name", .string("Timo Strauß")), ("user_aliases", .strings(["Timo"]))], stores: place.stores)
        let r = try Coach.analyze(p, userName: "Timo Strauß", invited: [], names: PyDict([("SPEAKER_00", "Valerie")]),
                                  stores: place.stores)
        #expect(r["talk"]?["share"] == .double(Py.round(216 / (216 + 51.5), 3)))
    }

    @Test func test_history_analyses_at_most_the_last_meetings() throws {
        let place = Place(); defer { place.remove() }
        for day in 1...35 {
            place.meeting(String(format: "2026-09-%02dT%02d-00-00", day % 30 + 1, day / 30 + 10), Self.LINES)
        }
        let cache = Coach.Cache()
        let h = Coach.history(place.root, userName: "Timo", limit: Coach.BASELINE_MEETINGS, stores: place.stores, cache: cache)
        #expect(h.count == 30 && cache.analyzed.count == 30)
        let all = try FileManager.default.contentsOfDirectory(atPath: place.root.path).sorted()
        #expect(cache.analyzed == cache.analyzed.sorted() && cache.analyzed.last == all.last)
    }

    @Test func test_the_baseline_is_kept_on_disk() throws {
        let place = Place(); defer { place.remove() }
        place.meeting("2026-10-27T10-00-00", Self.LINES)
        #expect(Coach.loadBaseline(stores: place.stores) == nil)
        let saved = try Coach.refreshBaseline(place.root, userName: "Timo", stores: place.stores, cache: Coach.Cache())
        #expect(saved["meetings"] == .int(1))
        // Read from the file alone: the meetings are gone.
        try FileManager.default.removeItem(at: place.root)
        #expect(dumps(Coach.loadBaseline(stores: place.stores)) == dumps(saved))
        let text = try String(contentsOf: Coach.baselinePath(stores: place.stores), encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"computed_at\": \"") && !text.hasSuffix("\n"))
        #expect(!FileManager.default.fileExists(atPath: Coach.baselinePath(stores: place.stores).path + ".tmp"))
    }

    // MARK: - test_shared_mic.py's coach tests

    /// test_webapp.py's `_meeting`, its transcript and turns only (the audio and notes don't reach the coach).
    private func windowMeeting(_ place: Place) -> RecordingPaths {
        let p = place.meeting("2026-10-27T16-03-07", [("Timo", 0.0, 1.0, "Hi Valerie, äh, welcome."),
                                                      ("SPEAKER_00", 1.0, 12.0, "Welcome to the hiring debrief."),
                                                      ("SPEAKER_01", 13.0, 15.0, "Thanks Valerie, the salary band is fine.")])
        Place.write(p.meta, .object([("start_time", .string("2026-10-27T16:03:07+01:00")), ("duration_seconds", .int(20))]))
        Place.write(p.systemTurns, .array([("SPEAKER_00", 1.0, 12.0), ("SPEAKER_01", 13.0, 15.0), ("SPEAKER_02", 16.0, 16.2)].map {
            .object([("speaker", .string($0.0)), ("start", .double($0.1)), ("end", .double($0.2))])
        }))
        return p
    }

    @Test func test_the_coach_leaves_out_my_pace_and_fillers_when_several_people_sat_at_my_mic() throws {
        let place = Place(); defer { place.remove() }
        let p = windowMeeting(place)
        try SharedMic.setLane(p, SharedMic.MIC, true)
        let r = try Coach.analyze(p, userName: "Timo", stores: place.stores)
        #expect(r["talk"]?["share"] == .null && r["talk"]?["at_mic"] == .bool(true) && r["monologues"] == .array([]))
        #expect(dumps(r["pace"]) == #"{"wpm": null, "fastest": null}"#)
        #expect(dumps(r["fillers"]) == #"{"per_minute": null, "top": [], "hesitations": null}"#)
    }

    @Test func test_the_coach_says_a_room_cut_in_not_a_label() throws {
        let place = Place(); defer { place.remove() }
        let p = windowMeeting(place)
        Place.write(p.transcriptJson, .array([
            .object([("speaker", .string("SPEAKER_00")), ("start", .double(0.0)), ("end", .double(10.0)),
                     ("text", .string("Das ist ein langer Satz über das Budget hier."))]),
            .object([("speaker", .string("Timo")), ("start", .double(8.0)), ("end", .double(14.0)),
                     ("text", .string("Ja aber wir müssen auch die Kosten sehen jetzt."))]),
        ]))
        try SharedMic.setLane(p, "SPEAKER_00", true, name: "Lab")
        let r = try Coach.result(p, userName: "Timo", stores: place.stores, cache: Coach.Cache())
        #expect(dumps(r["interruptions"]?["by_me_at"]) == #"[{"start": 8.0, "who": "Room (Lab)"}]"#)
    }

    // MARK: - Swift only

    /// coach.py sums with Python's `sum()`, which is compensated: 200 lines of 0.3 s are a minute (60.0), so there is a
    /// pace and a filler rate. A plain sum is 59.99999999999979 and would give neither.
    @Test func twoHundredLinesOfThreeTenthsAreAMinute() throws {
        let place = Place(); defer { place.remove() }
        let p = place.meeting("2026-10-27T10-00-00", Array(repeating: ("Timo", 0.0, 0.3, "Halt ja, genau."), count: 200))
        let r = try Coach.analyze(p, userName: "Timo", stores: place.stores)
        #expect(r["talk"]?["me"] == .int(60) && r["minutes_talked"] == .double(1.0))
        #expect(r["pace"]?["wpm"] == .int(600))
        #expect(r["fillers"]?["per_minute"] == .double(400.0))
        #expect(Py.sum(Array(repeating: 0.3, count: 200)) == 60.0)
        #expect(Array(repeating: 0.3, count: 200).reduce(0.0, +) != 60.0)  // what the plain sum would have said
    }

    // MARK: - Swift only: the goldens

}
