import Foundation
import Testing
@testable import PalaverEngine

/// Feeds `lines` to `serve` through pipes; returns the parsed reply lines.
private func run(_ lines: [String]) async throws -> [[String: Any]] {
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "9.9.9"))
    try outPipe.fileHandleForWriting.close()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
}

@Test func helloReportsVersions() async throws {
    let r = try await run([#"{"id":1,"cmd":"hello"}"#])
    #expect(r.count == 1)
    #expect(r[0]["id"] as? Int == 1)
    #expect(r[0]["ok"] as? Bool == true)
    #expect(r[0]["fluidaudio"] as? String == "0.18.2")
    #expect(r[0]["engine"] as? String == "9.9.9")
    let models = r[0]["models"] as? [String: Bool]
    #expect(models?.keys.sorted() == ["asr", "diarizer"])
}

@Test func unknownCommandIsAnError() async throws {
    let r = try await run([#"{"id":2,"cmd":"nope"}"#])
    #expect(r[0]["id"] as? Int == 2)
    #expect(r[0]["ok"] as? Bool == false)
    #expect((r[0]["error"] as? String)?.contains("nope") == true)
}

@Test func badJsonIsAnErrorNotACrash() async throws {
    let r = try await run(["{", #"{"id":3,"cmd":"hello"}"#])
    #expect(r.count == 2)
    #expect(r[0]["id"] as? Int == -1)
    #expect(r[0]["ok"] as? Bool == false)
    #expect(r[1]["id"] as? Int == 3)
    #expect(r[1]["ok"] as? Bool == true)
}

@Test func exitsWhenStdinCloses() async throws {
    let r = try await run([])
    #expect(r.isEmpty)
}

@Test func handlerReceivesTheArgs() async throws {
    let inPipe = Pipe(), outPipe = Pipe()
    inPipe.fileHandleForWriting.write(Data(#"{"id":4,"cmd":"echo","path":"/x.wav","n":3}"#.utf8 + [0x0A]))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting) { request, _ in
        ["path": request.args["path"] as Any, "n": request.args["n"] as Any]
    }
    try outPipe.fileHandleForWriting.close()
    let r = try JSONSerialization.jsonObject(with: outPipe.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
    #expect(r["id"] as? Int == 4)
    #expect(r["path"] as? String == "/x.wav")
    #expect(r["n"] as? Int == 3)
}

/// The default models folder follows PALAVER_HOME (make engine-test sets a temporary one): a test never reaches the
/// user's real models.
@Test func theDefaultModelsFolderIsUnderPalaverHome() {
    let home = ProcessInfo.processInfo.environment["PALAVER_HOME"] ?? "<unset>"
    #expect(ModelStore.defaultDirectory.path == home + "/Library/Application Support/palaver/models/fluidaudio")
}
