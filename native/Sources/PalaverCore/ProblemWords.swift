// The words for an audio incident, in PalaverCore so the recorder (PalaverCapture) and the
// domain's Lifecycle texts say the same thing.
/// The words for an incident (palaver/lifecycle.py `_WARNING`, `_HAPPENED`; the last two kinds are new).
public enum ProblemWords {
    private static func name(_ track: String) -> String { track == "mic" ? "microphone" : track == "system" ? "system audio" : track }
    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// While it lasts: the menu bar, the window, the notification.
    public static func warning(kind: String, track: String) -> String {
        let n = name(track)
        switch (kind, track) {
        case ("speed", "system"): return "System audio is playing at the wrong speed; Palaver is correcting it"
        case ("speed", "mic"): return "Microphone is recording at the wrong speed; Palaver is correcting it"
        case ("stalled", "system"): return "No system audio is arriving"
        case ("device", "system"): return "System audio couldn't be rebuilt; Palaver keeps trying"
        default: break
        }
        switch kind {
        case "length": return "\(capitalized(n)) is out of step with the clock"
        case "stalled": return "No \(n) audio is arriving"
        case "access": return "\(capitalized(n)) access was turned off — allow it in System Settings → Privacy & Security"
        case "device": return "\(capitalized(n)) is unavailable; Palaver keeps trying"
        case "dropped": return "\(capitalized(n)) is losing audio: the recorder cannot keep up"
        case "write": return "\(capitalized(n)) cannot be written to disk; audio is being lost — is the disk full?"
        default: return "Audio problem"
        }
    }

    /// Afterwards: the meeting page, `palaver doctor`.
    public static func happened(kind: String, track: String) -> String? {
        let n = name(track)
        switch (kind, track) {
        case ("speed", "system"): return "system audio played at the wrong speed"
        case ("speed", "mic"): return "microphone recorded at the wrong speed"
        case ("device", "system"): return "system audio couldn't be rebuilt"
        default: break
        }
        switch kind {
        case "length": return "\(n) drifted from the clock"
        case "silent": return "\(n) sent nothing — muted?"
        case "stalled": return "\(n) stopped delivering"
        case "access": return "\(n) access was turned off"
        case "device": return "\(n) was unavailable"
        case "dropped": return "\(n) lost audio"
        case "write": return "\(n) could not be written to disk"
        default: return nil
        }
    }
}
