// exchange's schema checks (exchange.py:133-280): the schemas as Python has them, `check`, `_json` and `_time` with
// Python's words for what does not fit, and the schema tests of test_exchange.py.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct JSONSchemaCheckTests {
    static func schema(_ name: String) -> JSONSchema {
        switch name {
        case "MANIFEST": return JSONSchemaCheck.MANIFEST
        case "VOICE": return JSONSchemaCheck.VOICE
        default: return JSONSchemaCheck.SCHEMAS[name]!
        }
    }

    /// The message `check` throws, or nil.
    static func message(_ value: JSONValue, _ schema: JSONSchema, _ at: String) -> String? {
        do {
            try JSONSchemaCheck.check(value, schema: schema, where: at)
            return nil
        } catch {
            return (error as? ExchangeRejected)?.message ?? "not ExchangeRejected: \(error)"
        }
    }

    // MARK: - Goldens

    @Test func theSchemasAreVerbatim() {
        let schemas: JSONValue = .object([
            ("SCHEMAS", .object(JSONSchemaCheck.SCHEMAS.map { ($0.key, $0.value.json) })),
            ("MANIFEST", JSONSchemaCheck.MANIFEST.json), ("VOICE", JSONSchemaCheck.VOICE.json),
        ])
        Goldens.expect(schemas, "exchange_zip", "schemas")
    }

    @Test func checkSaysWhatPythonSays() throws {
        var got: [JSONValue] = []
        for c in try Goldens.cases("exchange_zip", "check") {
            let m = Self.message(c[0], Self.schema(c[1].stringValue!), c[2].stringValue!)
            got.append(.array([c[0], c[1], c[2], m.map { .string($0) } ?? .null]))
        }
        Goldens.expectEach(got, "exchange_zip", "check")
    }

    @Test func jsonSaysWhatPythonSays() throws {
        var got: [JSONValue] = []
        for c in try Goldens.cases("exchange_zip", "json") {
            let result: JSONValue
            do {
                result = .object([("value", try JSONSchemaCheck.json(hexData(c[0].stringValue!), where: c[1].stringValue!))])
            } catch let e as ExchangeRejected {
                result = .object([("rejected", .string(e.message))])
            }
            got.append(.array([c[0], c[1], result]))
        }
        Goldens.expectEach(got, "exchange_zip", "json")
    }

    @Test func timeSaysWhatPythonSays() throws {
        var got: [JSONValue] = []
        for c in try Goldens.cases("exchange_zip", "time") {
            let result: JSONValue
            do {
                let t = try JSONSchemaCheck.time(c[0].stringValue!, where: c[1].stringValue!)
                result = .array([t.year, t.month, t.day, t.hour, t.minute, t.second, t.microsecond, t.utcOffset].map { .int($0) })
            } catch let e as ExchangeRejected {
                result = .object([("rejected", .string(e.message))])
            }
            got.append(.array([c[0], c[1], result]))
        }
        Goldens.expectEach(got, "exchange_zip", "time")
    }

    @Test func timesCompareAsMoments() throws {
        let a = try JSONSchemaCheck.time("2026-10-29T10:00:00+01:00", where: "a")
        let b = try JSONSchemaCheck.time("2026-10-29T09:00:00Z", where: "b")
        let c = try JSONSchemaCheck.time("2026-10-29T09:00:00.000001Z", where: "c")
        #expect(a == b && b < c)
        #expect(a.date == Date(timeIntervalSince1970: 1_793_264_400))
        #expect(c.date.timeIntervalSince(b.date) > 0)
    }

    @Test func jsonNestedTooDeeplyIsNotValidAndNoCrash() throws {
        func nested(_ n: Int) -> Data { Data(repeating: UInt8(ascii: "["), count: n) + Data(repeating: UInt8(ascii: "]"), count: n) }
        _ = try JSONSchemaCheck.json(nested(PythonJSON.MAX_DEPTH), where: "x")
        for n in [PythonJSON.MAX_DEPTH + 1, 1000, 100_000] {  // Python reads up to past 1000 (ledger)
            #expect(throws: ExchangeRejected("x is not valid JSON")) { try JSONSchemaCheck.json(nested(n), where: "x") }
        }
    }

    // MARK: - The schema tests of test_exchange.py

    @Test func test_a_json_not_fitting_its_schema_is_rejected_before_anything_is_written() throws {
        let transcript = try JSONSchemaCheck.json(Data(#"[{"start": 0, "end": 1, "text": 42, "label": "SPEAKER_00"}]"#.utf8),
                                                  where: "meeting/transcript.json")
        let m = Self.message(transcript, Self.schema("meeting/transcript.json"), "meeting/transcript.json")
        #expect(m == "meeting/transcript.json[0].text is not string")
    }

    @Test func test_unknown_keys_are_rejected() throws {
        let zip = try ZipReader(url: Goldens.url("exchange-python.zip"), maxDirectoryBytes: ExchangeZip.MAX_DIRECTORY_BYTES)
        let entry = zip.entries.first { $0.name == "meeting/meta.json" }!
        guard case .object(var meta) = try JSONSchemaCheck.json(try zip.data(entry, limit: 1 << 20), where: "meeting/meta.json") else {
            Issue.record("meta.json is not an object"); return
        }
        #expect(Self.message(.object(meta), Self.schema("meeting/meta.json"), "meeting/meta.json") == nil)
        meta.append(("run", .string("something")))
        #expect(Self.message(.object(meta), Self.schema("meeting/meta.json"), "meeting/meta.json")?.contains("which it can't have") == true)
    }

    @Test func test_nan_is_rejected() {
        #expect(throws: ExchangeRejected("meeting/turns.json has NaN, which JSON can't have")) {
            try JSONSchemaCheck.json(Data(#"[{"speaker": "SPEAKER_00", "start": NaN, "end": 1}]"#.utf8), where: "meeting/turns.json")
        }
    }

    @Test func test_a_label_that_is_not_a_speaker_label_is_rejected() throws {
        let speakers = try JSONSchemaCheck.json(Data(#"[{"label": "../../x", "name": "Valerie", "how": "hand"}]"#.utf8),
                                                where: "meeting/speakers.json")
        #expect(Self.message(speakers, Self.schema("meeting/speakers.json"), "meeting/speakers.json")?
            .contains("not in the expected form") == true)
    }

    @Test func test_a_number_json_can_only_write_as_infinity_is_rejected() throws {
        let raw = #"{"label": "SPEAKER_00", "name": "Valerie", "embedding": [1e999"# + String(repeating: ", 0.5", count: 20) + "]}"
        let voice = try JSONSchemaCheck.json(Data(raw.utf8), where: "voices/SPEAKER_00.json")
        #expect(Self.message(voice, JSONSchemaCheck.VOICE, "voices/SPEAKER_00.json") == "voices/SPEAKER_00.json.embedding[0] is not a finite number")
    }

    @Test(arguments: ["9999-12-31T23:59:59+14:00", "0001-01-01T00:00:00-12:00", "1970-01-01T00:00:00+00:00"])
    func test_a_date_out_of_range_is_rejected(_ when: String) {
        #expect(Self.message(.string(when), JSONSchemaCheck.SCHEMAS["meeting/meta.json"]!.properties["start"]!, "meta.json start") == nil)
        #expect(throws: ExchangeRejected("meta.json start is out of range")) { try JSONSchemaCheck.time(when, where: "meta.json start") }
    }
}
