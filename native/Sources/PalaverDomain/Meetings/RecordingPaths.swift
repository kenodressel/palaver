// The recording-folder layout (palaver/paths.py): one URL per file a meeting folder can hold, and the
// folder names `newRecordingFolder` gives.
import Foundation
import PalaverCore

public struct RecordingPaths: Hashable, Sendable {
    public let folder: URL

    public init(_ folder: URL) { self.folder = folder }

    /// The folder's name: the meeting's id.
    public var id: String { folder.lastPathComponent }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    public var micWav: URL { file("mic.wav") }
    public var micRawWav: URL { file("mic_raw.wav") }
    public var systemWav: URL { file("system.wav") }
    public var meta: URL { file("meta.json") }
    public var micSegments: URL { file("mic_segments.json") }
    public var systemSegments: URL { file("system_segments.json") }
    /// Whisper language detected on the system track, reused for the mic.
    public var language: URL { file("language.txt") }
    /// Voice embedding per diarization label (label → vector).
    public var speakerEmbeddings: URL { file("speaker_embeddings.json") }
    /// Names recognized from the voice bank (label → name, similarity).
    public var speakersAuto: URL { file("speakers_auto.json") }
    /// Names given to diarization labels by `rename` (label → name).
    public var speakers: URL { file("speakers.json") }
    /// What the live worker has so far, while recording (#30).
    public var live: URL { file("live.json") }
    /// The realtime stream's sentences, drafts and questions (#42).
    public var stream: URL { file("stream.json") }
    public var streamPid: URL { file("stream.pid") }
    /// Voices removed as noise: a few words, a split-off fragment.
    public var speakersIgnored: URL { file("speakers_ignored.json") }
    /// Names inferred from the calendar and other meetings (#38).
    public var speakersInferred: URL { file("speakers_inferred.json") }
    /// Names the user said a voice is not (label → names), #48.
    public var speakersRejected: URL { file("speakers_rejected.json") }
    /// Voices the user can't name ("Don't Know"): unnamed, but not asked about.
    public var speakersUnknown: URL { file("speakers_unknown.json") }
    /// Names given while recording, with the voice they were given to.
    public var speakersLive: URL { file("speakers_live.json") }
    /// The title the user gave the meeting, over the event's and the notes' (titles.py).
    public var title: URL { file("title.json") }
    /// Where an imported meeting came from, and the names and voices that came with it (exchange.py, #58).
    public var imported: URL { file("imported.json") }
    /// Voices that came with an import, waiting for the user's yes: apart from speaker_embeddings.json,
    /// so nothing recognizes or learns them before it (#58).
    public var importedVoices: URL { file("imported_voices.json") }
    /// The user said no to the suggested cut (#40).
    public var cutDismissed: URL { file("cut_dismissed.json") }
    /// The user said no to removing the silence at the start or end.
    public var silenceDismissed: URL { file("silence_dismissed.json") }
    /// The user keeps this meeting on this Mac: no cloud model, not shown through MCP (#53).
    public var localOnly: URL { file("local_only.json") }
    /// Who transcribed each track: this Mac, the live worker or a cloud service (#54).
    public var transcription: URL { file("transcription.json") }
    /// What a transcription service still keeps of this meeting, to delete (#54).
    public var cloudPending: URL { file("cloud-pending.json") }
    /// Recordings that continue this one after a Palaver restart (#47).
    public var parts: URL { file("parts.json") }
    /// When the user went through the finished meeting (#32).
    public var review: URL { file("review.json") }
    /// Labels merged into another: one person the diarizer split (label → label).
    public var speakersMerged: URL { file("speakers_merged.json") }
    /// Single lines said to be someone else's (#12): start, end, the voice they were heard as, and who said them.
    public var speakersLines: URL { file("speakers_lines.json") }
    /// Voices that can't be told apart: the whole meeting, or lanes that are a room of several people (#56).
    public var speakersShared: URL { file("speakers_shared.json") }
    public var systemTurns: URL { file("system_turns.json") }
    public var transcriptJson: URL { file("transcript.json") }
    public var transcriptMd: URL { file("transcript.md") }
    /// Summary, topics, next steps and decisions (notes.py).
    public var notes: URL { file("notes.json") }
    /// The user's own notes on the meeting (my_notes.py, #44).
    public var myNotes: URL { file("my-notes.json") }
    /// Images pasted into the user's notes, and the text read from them.
    public var myNotesImages: URL { file("my-notes") }
    /// The calendar event the recording belongs to (calendar_events.py).
    public var calendar: URL { file("calendar.json") }
    public var notionInfo: URL { file("notion.json") }
    /// The recorder's audio incidents as they happen (issue #50), folded into meta.json at the stop,
    /// or by crash recovery.
    public var audioProblems: URL { file("audio_problems.json") }
    public var sessionLog: URL { file("session.log") }

    // MARK: - Folder names

    // `_FOLDER_NAME`, built once (PyRegex compiles `\d` into a big class).
    private static let folderName = try! PyRegex(#"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})(-\d+)?$"#)

    /// True for names `newRecordingFolder` creates.
    public static func isRecordingFolderName(_ name: String) -> Bool { folderName.firstMatch(in: name) != nil }

    /// The `YYYY-MM-DDTHH-MM-SS` part of a recording folder name.
    public static func recordingFolderTimestamp(_ name: String) -> String? { folderName.firstMatch(in: name)?.group(1) }

    /// Creates a fresh recording folder under `root`, named by timestamp (`now` in `timeZone`, as
    /// `strftime` on a naive local datetime). If a folder with the same timestamp exists, appends
    /// `-2`, `-3`, …
    public static func newRecordingFolder(root: URL, now: Date, timeZone: TimeZone = .current) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let c = WallTime.calendar(timeZone, at: now).dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let base = String(format: "%04d-%02d-%02dT%02d-%02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }
}
