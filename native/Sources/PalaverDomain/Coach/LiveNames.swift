// Who has spoken so far in a recording (live_coach.py `live_names`): the voices the live worker has clustered
// (live.json), with names from the voice bank (the invitees first) and those given while recording.
import Foundation
import PalaverCore

extension Speakers {
    /// (talk seconds by label, label → name). Nothing when live.json is missing or broken; no names before the live
    /// worker has voices. Throws when the voice bank or a voice is unreadable (the coach is then not sure).
    public static func liveNames(_ paths: RecordingPaths, invitees: [String], bank: VoiceBank) throws
        -> (talk: PyDict<Double>, names: PyDict<String>) {
        guard let live = PythonJSON.read(paths.live), case .object = live else { return (PyDict(), PyDict()) }
        let turns = try (live["turns"]?.arrayValue ?? []).map { try SpeakerTurn(json: $0) }
        let talk = talkSeconds(turns)
        guard case .object(let fields)? = live["embeddings"], !fields.isEmpty else { return (talk, PyDict()) }
        let embeddings = PyDict(try fields.map { ($0.0, try VoiceMath.vector($0.1, "a live voice")) })
        let known = try bank.names().keys
        let invited = invitees.compactMap { CalendarEvents.resolve($0, known) }
        var names = PyDict(try Voices.recognize(embeddings, talk: talk, bank: bank, invited: invited)
            .map { ($0.key, $0.value.0) })
        for (label, name) in try matchLiveNames(embeddings, loadLiveNames(paths)) { names[label] = name }
        return (talk, names)
    }
}
