// What the pipeline asks of the speech engine (transcriber.py `EngineTranscriber`, diarizer.py `EngineDiarizer`):
// segments of a WAV, the words of a window of samples, the speakers of a WAV with their voices. `InProcessEngine`
// answers in this process; debug builds can answer from a file instead (`FakeEngine`, `PALAVER_TEST_ENGINE`).
import Foundation
import PalaverDomain

/// The engine does not have its models (yet): the meeting waits for the download (exit 4, failed.json "models").
public struct ModelsMissing: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public protocol EngineCalls: AnyObject {
    /// The segments of `wav`, the dictionary applied; `[]` for a track that holds no audio.
    func transcribe(wav: URL) async throws -> [Segment]
    /// The words of 16 kHz mono samples (the live worker's windows), the dictionary applied.
    func transcribeWindow(_ samples: [Float]) async throws -> [Word]
    /// The speaker turns of `wav` (sorted by start) and a voice per label; nothing for a track that holds no audio.
    func diarize(wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: PyDict<[Double]>)
    /// Whether the speech models are on this Mac.
    func modelsReady() -> Bool
    /// The commands answered well so far (engine.py `SUCCEEDED`): "transcribe" and "diarize" both are the proof that
    /// the speech models work.
    var succeeded: Set<String> { get }
    /// Lets go of the loaded models (memory) until a call needs them again.
    func release() async
}

public enum EngineAudio {
    /// transcriber.py `MIN_AUDIO_SECONDS`: less audio than this holds no word (the engine refuses under 10 ms).
    public static let MIN_AUDIO_SECONDS = 0.05

    /// `holds_audio`: whether `wav` is worth a model call. A system track can be a bare header (the tap delivered
    /// nothing). A file that can't be read is left to the model to complain about.
    public static func holdsAudio(_ wav: URL) -> Bool {
        guard let info = try? Wav16.info(wav) else { return true }
        return Double(info.frames) >= MIN_AUDIO_SECONDS * Double(info.rate)
    }
}
