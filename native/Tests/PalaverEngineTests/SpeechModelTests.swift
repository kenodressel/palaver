import Foundation
import Testing
@testable import PalaverEngine

private let enabled = ProcessInfo.processInfo.environment["PALAVER_ENGINE_MODEL_TESTS"] == "1"

private func sh(_ tool: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}

private let annaInstalled: Bool = {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return false }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\n").contains { $0.hasPrefix("Anna ") }
}()

/// Real Parakeet on synthetic speech. `say -o` writes a file and plays nothing.
@Test(.enabled(if: enabled && annaInstalled, "needs PALAVER_ENGINE_MODEL_TESTS=1 and the Anna voice"))
func transcribesSynthetic() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let aiff = tmp.appendingPathComponent("x.aiff").path, wav = tmp.appendingPathComponent("x.wav").path
    #expect(try sh("/usr/bin/say", ["-v", "Anna", "-o", aiff, "Timo Strauß von KLOUD hat das Deployment für Contoso gestartet"]) == 0)
    #expect(try sh("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav]) == 0)

    // Models: Palaver's folder, or a copy of FluidAudio's default cache (never deleted).
    let models = tmp.appendingPathComponent("models")
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FluidAudio/Models")
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    let asrFolder = ModelStore(directory: models).asrDirectory.lastPathComponent
    if FileManager.default.fileExists(atPath: cache.appendingPathComponent(asrFolder).path) {
        try FileManager.default.copyItem(at: cache.appendingPathComponent(asrFolder), to: models.appendingPathComponent(asrFolder))
    }
    let inPipe = Pipe(), outPipe = Pipe()
    let req = #"{"id":1,"cmd":"prepare","models":["asr"]}"# + "\n" + #"{"id":2,"cmd":"transcribe","wav":"\#(wav)"}"# + "\n"
    inPipe.fileHandleForWriting.write(Data(req.utf8))
    try inPipe.fileHandleForWriting.close()
    await serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting,
                handler: engineHandler(version: "t", modelsDir: models))
    try outPipe.fileHandleForWriting.close()
    let lines = try String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    let prep = lines.first { $0["id"] as? Int == 1 && $0["ok"] != nil }!
    #expect(prep["ready"] as? [String] == ["asr"])
    let reply = lines.last!
    #expect(reply["ok"] as? Bool == true)
    let text = ((reply["segments"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ").lowercased()
    let hits = ["timo", "kloud", "deployment", "contoso", "gestartet"].filter { text.contains($0) }
    print("model test: \(hits.count)/5 key words found")
    #expect(hits.count >= 3)
}
