import Foundation

public let fluidAudioVersion = "0.18.2"

/// One request line: `{"id": 1, "cmd": "hello", ...}`. Requests are parsed by
/// hand (the extra fields differ per command), so `args` holds the whole
/// object, `id` and `cmd` included. Replies are plain dictionaries: the
/// handler's result plus `id` and `ok`, or `id`, `ok: false` and `error`.
public struct Request {
    public var id: Int
    public var cmd: String
    public var args: [String: Any]

    public init(id: Int, cmd: String, args: [String: Any] = [:]) {
        self.id = id; self.cmd = cmd; self.args = args
    }
}

public struct EngineError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func parseRequest(_ line: Data) throws -> Request {
    guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any],
          let id = obj["id"] as? Int, let cmd = obj["cmd"] as? String
    else { throw EngineError("request needs an integer id and a string cmd") }
    return Request(id: id, cmd: cmd, args: obj)
}

func encode(_ dict: [String: Any]) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]))
        ?? Data(#"{"id":-1,"ok":false,"error":"unencodable reply"}"#.utf8)
    return data + Data("\n".utf8)
}

/// Lets a handler write progress lines (`{"id","progress","phase"}`) before its
/// reply. Safe to call from any thread (FluidAudio reports from its own queues).
public final class Emitter: @unchecked Sendable {
    private let id: Int
    private let output: FileHandle
    private let lock = NSLock()
    /// `output` gets the progress lines (an in-process caller that wants none passes `FileHandle.nullDevice`).
    public init(id: Int, output: FileHandle) { self.id = id; self.output = output }

    private var last: (phase: String, fraction: Double)?

    /// Writes one progress line. Lines that tell the caller nothing new (same
    /// phase, less than 1 % further, not the end) are dropped.
    public func progress(_ fraction: Double, phase: String) {
        let f = min(max(fraction, 0), 1)
        lock.lock(); defer { lock.unlock() }
        if let l = last, l.phase == phase, f < 1, f - l.fraction < 0.01 { return }
        last = (phase, f)
        output.write(encode(["id": id, "progress": f, "phase": phase]))
    }
}

/// Reads request lines from `input` until EOF, one at a time and in order, and
/// writes one flushed reply line per request to `output`, after any progress
/// lines the handler emitted. Never throws: a bad line or a failing handler
/// becomes an `ok: false` reply.
public func serve(input: FileHandle, output: FileHandle,
                  handler: (Request, Emitter) async throws -> [String: Any]) async {
    var buffer = Data()
    var eof = false
    while !eof || !buffer.isEmpty {
        var line: Data
        if let nl = buffer.firstIndex(of: 0x0A) {
            line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
        } else if eof {
            line = buffer; buffer = Data()
        } else {
            let chunk = input.availableData
            if chunk.isEmpty { eof = true } else { buffer.append(chunk) }
            continue
        }
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
        let reply: [String: Any]
        do {
            let request = try parseRequest(line)
            do {
                var result = try await handler(request, Emitter(id: request.id, output: output))
                result["id"] = request.id
                result["ok"] = true
                reply = result
            } catch {
                reply = ["id": request.id, "ok": false, "error": "\(error)"]
            }
        } catch {
            reply = ["id": -1, "ok": false, "error": "bad request: \(error)"]
        }
        output.write(encode(reply))
    }
}

/// The engine's command table. Later tasks add commands here.
public func engineHandler(version: String, modelsDir: URL = ModelStore.defaultDirectory,
                          recognizer: (() async throws -> Recognizer)? = nil,
                          diarizer: (() async throws -> Diarizing)? = nil)
    -> (Request, Emitter) async throws -> [String: Any]
{
    let engine = SpeechEngine(store: ModelStore(directory: modelsDir), recognizer: recognizer)
    let speakers = SpeakerEngine(store: engine.store, diarizer: diarizer)
    return { request, emit in
        switch request.cmd {
        case "hello":
            return ["engine": version, "fluidaudio": fluidAudioVersion,
                    "models": engine.store.readiness()]
        case "prepare":
            return try await engine.prepare(request.args["models"], emit: emit)
        case "transcribe":
            return try await engine.transcribe(request.args)
        case "transcribe_window":
            return try await engine.transcribeWindow(request.args)
        case "diarize":
            return try await speakers.diarize(request.args)
        case "embed":
            return try await speakers.embed(request.args)
        default:
            throw EngineError("unknown command: \(request.cmd)")
        }
    }
}
