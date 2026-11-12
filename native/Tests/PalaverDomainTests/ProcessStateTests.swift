// failed.json (palaver/process_state.py): why a recording has no transcript yet.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct ProcessStateTests {
    private func paths(_ t: TempFolder) -> RecordingPaths { RecordingPaths(t.url) }

    @Test func anErrorKeepsItsWords() throws {
        let t = TempFolder("failed"); defer { t.remove() }
        try ProcessState.mark(paths(t), reason: ProcessState.error, error: "Unable to reach MTLCompilerService — äh")
        let text = try #require(t.text("failed.json"))
        #expect(text.contains("\"missing\": []") && text.contains("\\u00e4h"))  // ensure_ascii, as json.dumps(indent=2)
        #expect(ProcessState.read(paths(t))?["error"]?.stringValue == "Unable to reach MTLCompilerService — äh")
    }

    @Test func aFailureOfAnotherKindOrBrokenFileIsNoFailure() {
        let t = TempFolder("failed"); defer { t.remove() }
        #expect(ProcessState.read(paths(t)) == nil)
        t.write("failed.json", #"{"reason": "other"}"#)
        #expect(ProcessState.read(paths(t)) == nil)
        t.write("failed.json", "[1]")
        #expect(ProcessState.read(paths(t)) == nil)
        t.write("failed.json", "{broken")
        #expect(ProcessState.read(paths(t)) == nil)
    }

    @Test func clearRemovesTheFileAndMissesNothing() throws {
        let t = TempFolder("failed"); defer { t.remove() }
        ProcessState.clear(paths(t))
        try ProcessState.mark(paths(t), reason: ProcessState.error, error: "x")
        ProcessState.clear(paths(t))
        #expect(!t.exists("failed.json"))
        #expect(ProcessState.exitModels == 4)
    }

    @Test func test_a_meeting_waiting_for_its_models_says_which() throws {
        // What the window shows (api.get_meeting) is `read`; transcribe_again asks missing_models.
        let t = TempFolder("failed"); defer { t.remove() }
        try ProcessState.mark(paths(t), reason: ProcessState.models, missing: ["Speech models"])
        let waiting = try #require(ProcessState.read(paths(t)))
        #expect(waiting["reason"]?.stringValue == "models" && waiting["missing"] == .strings(["Speech models"]))
        #expect(ProcessState.missingModels(transcriber: "parakeet", paths: paths(t), speechModelsHere: { false }) == ["Speech models"])
        #expect(ProcessState.missingModels(transcriber: "parakeet", paths: paths(t), speechModelsHere: { true }) == [])
    }

    @Test func missingModelsSkipsTranscribedFolders() {
        let t = TempFolder("failed"); defer { t.remove() }
        let p = paths(t)
        var asked = 0
        func missing(_ transcriber: String = "parakeet") -> [String] {
            ProcessState.missingModels(transcriber: transcriber, paths: p, speechModelsHere: { asked += 1; return false })
        }
        // Nothing done yet: speech to text and the speakers both need the models.
        #expect(missing() == ["Speech models"])
        // Transcribed, speakers not told apart yet: the diarizer still needs them.
        t.write("mic_segments.json", "[]"); t.write("system_segments.json", "[]")
        #expect(missing() == ["Speech models"])
        t.write("system_turns.json", "[]")
        #expect(missing() == ["Speech models"])  // the embeddings are still missing
        // Everything transcribed and diarized: nothing to download, nothing asked.
        t.write("speaker_embeddings.json", "{}")
        asked = 0
        #expect(missing() == [] && asked == 0)
        // One track only is not transcribed: Parakeet's text is missing, another transcriber's is not ours to fetch.
        try? FileManager.default.removeItem(at: p.micSegments)
        #expect(missing() == ["Speech models"])
        asked = 0
        #expect(missing("whisper") == [] && asked == 0)
        // Another transcriber than Parakeet does not need the speech models for the text, only for the speakers.
        try? FileManager.default.removeItem(at: p.speakerEmbeddings)
        #expect(missing("whisper") == ["Speech models"])
        t.write("speaker_embeddings.json", "{}")
        #expect(missing("whisper") == [])
        #expect(missing("parakeet-mlx") == ["Speech models"])
    }
}
