// `palaver-worker engine-serve`: palaver-engine's JSON-lines protocol (`hello`, `transcribe`, `diarize`) answered by
// the worker's in-process engine, so the local quality gate (tools/eval_engine.py --worker) measures the code
// path the worker runs, with palaver-engine's reply shapes.
import Foundation
import PalaverEngine

public enum EngineServe {
    public static let COMMANDS: Set<String> = ["hello", "transcribe", "diarize"]

    /// Serves `input` until it ends; one reply line per request on `output`.
    public static func run(engine: InProcessEngine, input: FileHandle = .standardInput,
                           output: FileHandle = .standardOutput) async {
        await serve(input: input, output: output) { request, _ in
            guard COMMANDS.contains(request.cmd) else { throw EngineError("unknown command: \(request.cmd)") }
            do {
                return try await engine.call(request.cmd, request.args)
            } catch let missing as ModelsMissing {
                throw EngineError(missing.description)  // the line palaver-engine writes: "models missing: …"
            }
        }
    }
}
