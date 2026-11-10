// transcript.md (palaver/render.py): the clean verbatim as Markdown, with a line where the recording paused.
import Foundation
import PalaverCore

public enum Render {
    /// `gaps`: stretches nothing was recorded (meta.json); each shows as a line where it was. Times are
    /// the wall time of `start` in `timeZone`; pass the fixed offset `start` was written with (Python's
    /// `datetime + timedelta` keeps it). The glossary is the user's unless one is given.
    /// Throws where Python raises on a hand-edited number (a NaN or endless duration or time).
    public static func markdown(_ utterances: [Utterance], start: Date, duration: Double, gaps: [JSONValue]? = nil,
                                timeZone: TimeZone, glossary: Glossary? = nil) throws -> String {
        let shown = Readable.readable(utterances, glossary: glossary)
        let speakers = Set(shown.map(\.speaker)).count
        var lines = ["# " + (try buildMeetingTitle(start, duration, speakers, timeZone: timeZone)), ""]
        var pending = Py.stableSorted(gaps ?? []) { ($0["start"]?.doubleValue ?? 0) < ($1["start"]?.doubleValue ?? 0) }
        for u in Py.stableSorted(shown, by: { $0.start < $1.start }) {
            while let gap = pending.first, (gap["start"]?.doubleValue ?? 0) <= u.start {
                lines += ["*\(try Lifecycle.gapText(pending.removeFirst(), start: start, timeZone: timeZone))*", ""]
            }
            lines.append("**\(u.speaker)** [\(try wallTime(start, plus: u.start, timeZone))]  \(u.text)")
            lines.append("")
        }
        for gap in pending { lines += ["*\(try Lifecycle.gapText(gap, start: start, timeZone: timeZone))*", ""] }
        return Py.strip(lines.joined(separator: "\n")) + "\n"
    }

    /// `(start + timedelta(seconds=seconds)).strftime("%H:%M:%S")`: the timedelta in whole microseconds.
    public static func wallTime(_ start: Date, plus seconds: Double, _ timeZone: TimeZone) throws -> String {
        guard seconds.isFinite else { throw Py.IntError(description: "cannot convert float \(Py.repr(seconds)) to integer") }
        let micros = (start.timeIntervalSince1970 * 1e6).rounded(.toNearestOrEven) + (seconds * 1e6).rounded(.toNearestOrEven)
        return try Lifecycle.wallClock(Date(timeIntervalSince1970: (micros / 1e6).rounded(.down)), timeZone)
    }

    /// Title shared by the Markdown header and the Notion page.
    public static func buildMeetingTitle(_ start: Date, _ duration: Double, _ speakers: Int, timeZone: TimeZone) throws -> String {
        let c = WallTime.calendar(timeZone, at: start).dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let word = speakers == 1 ? "speaker" : "speakers"
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
            + " — Meeting (\(try formatDuration(duration)), \(speakers) \(word))"
    }

    /// "24 min", "1h 5min".
    public static func formatDuration(_ seconds: Double) throws -> String {
        let total = try Py.roundInt(seconds)
        let hours = Int((Double(total) / 3600).rounded(.down))
        let minutes = Int((Double(total - hours * 3600) / 60).rounded(.down))
        return hours != 0 ? "\(hours)h \(minutes)min" : "\(minutes) min"
    }
}
