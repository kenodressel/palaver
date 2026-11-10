// A recording the app died making, made whole before it is processed (cli.py `_promote_part_files`,
// `_synthesize_meta_from_audio`, `_fold_audio_problems`): the growing `.part` tracks renamed into place (their
// headers already say what was written), meta.json rebuilt from the folder's name and the audio's length, and the
// audio problems the recorder kept beside the audio folded into meta.json.
import Darwin
import Foundation
import PalaverCore

public enum Recovery {
    /// `<track>.part` → `<track>` for both captured tracks, unless the final file exists (a clean stop wrote it).
    public static func promoteParts(_ paths: RecordingPaths) throws {
        for final in [paths.micRawWav, paths.systemWav] {
            let part = final.path + ".part"
            if access(part, F_OK) == 0 && access(final.path, F_OK) != 0 {
                guard rename(part, final.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
    }

    /// meta.json from the folder's name (the recording's start, local wall time) and the length of mic_raw.wav,
    /// else system.wav; then the audio problems folded in. False when there is no readable audio or the name is no
    /// start time (nothing written).
    @discardableResult
    public static func synthesizeMeta(_ paths: RecordingPaths, timeZone: TimeZone = .current) -> Bool {
        let fm = FileManager.default
        let audio = fm.fileExists(atPath: paths.micRawWav.path) ? paths.micRawWav : paths.systemWav
        guard fm.fileExists(atPath: audio.path), let info = try? Wav16.info(audio),
              let start = startTime(paths.folder.lastPathComponent, timeZone: timeZone) else { return false }
        let duration = Double(info.frames) / Double(info.rate)
        guard let end = try? start.adding(seconds: duration) else { return false }
        let meta: JSONValue = .object([("start_time", .string(start.iso)), ("end_time", .string(end.iso)),
                                       ("duration_seconds", .double(duration))])
        guard (try? PythonJSON.write(meta, to: paths.meta, indent: 2, ensureAscii: true)) != nil else { return false }
        foldAudioProblems(paths)
        return true
    }

    /// `datetime.strptime(name, "%Y-%m-%dT%H-%M-%S").astimezone()`: the folder's name read as local wall time, with
    /// that moment's offset.
    static func startTime(_ name: String, timeZone: TimeZone) -> PyDateTime? {
        let fields = name.split(separator: "T", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let day = fields[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let time = fields[1].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard day.count == 3, time.count == 3, day.allSatisfy({ $0 != nil }), time.allSatisfy({ $0 != nil }),
              fields[0].count == 10, fields[1].count == 8 else { return nil }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (day[0], day[1], day[2])
        (parts.hour, parts.minute, parts.second) = (time[0], time[1], time[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard parts.isValidDate(in: calendar), let date = calendar.date(from: parts) else { return nil }
        return PyDateTime(date, offset: timeZone.secondsFromGMT(for: date))
    }

    /// The audio problems kept in audio_problems.json (#50), into meta.json when a crash left them there: one still
    /// open lasted to the end. meta.json's own (a clean stop wrote them) win. The file is gone afterwards; nothing
    /// happens when either file can't be read.
    public static func foldAudioProblems(_ paths: RecordingPaths) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.audioProblems.path), fm.fileExists(atPath: paths.meta.path),
              let keptData = try? Data(contentsOf: paths.audioProblems), let kept = try? PythonJSON.parse(keptData),
              let metaData = try? Data(contentsOf: paths.meta), let parsed = try? PythonJSON.parse(metaData),
              var meta = PyDict<JSONValue>(parsed) else { return }
        if !(meta["audio_problems"]?.truthy ?? false) {
            let duration = meta["duration_seconds"].flatMap { $0.truthy ? $0.doubleValue : nil } ?? 0
            let problems: [JSONValue] = (kept.arrayValue ?? []).compactMap { p in
                guard var problem = PyDict<JSONValue>(p), problem["start"] != nil else { return nil }
                if problem["end"] == nil || problem["end"]!.isNull { problem["end"] = .double(duration) }
                return problem.json
            }
            if !problems.isEmpty {
                meta["audio_problems"] = .array(problems)
                guard (try? PythonJSON.write(meta.json, to: paths.meta, indent: 2, ensureAscii: true,
                                             via: paths.meta.lastPathComponent + ".tmp")) != nil else { return }
            }
        }
        unlink(paths.audioProblems.path)
    }
}
