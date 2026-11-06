// Dev check for Keno's hardware test (Task 6): a real recording through the real sources.
// `Palaver --capture-check <seconds> <folder>` opens the microphone and the system-audio tap
// (macOS asks for both permissions the first time, for the terminal that runs it). Nothing
// else runs it: no test, no app path.
import Darwin
import Foundation
import PalaverCapture

func runCaptureCheck(_ args: [String]) -> Int32 {
    guard args.count == 2, let seconds = Double(args[0]), seconds > 0 else {
        print("usage: Palaver --capture-check <seconds> <folder>")
        return 2
    }
    let folder = URL(fileURLWithPath: args[1])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let say: (String) -> Void = { print("[\(String(format: "%.1f", monotonicSeconds()))] \($0)") }
    let recorder = CaptureRecorder(micURL: folder.appendingPathComponent("mic_raw.wav"),
                                   systemURL: folder.appendingPathComponent("system.wav"),
                                   sources: .live(log: say), log: say, debug: say)
    do { try recorder.start() } catch {
        print("start failed: \(error)")
        return 1
    }
    print("system=\(recorder.systemSource ?? "none") mic=\(recorder.micSource ?? "none") missing=\(recorder.missing)")
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        Thread.sleep(forTimeInterval: 1)
        func rate(_ r: Double?) -> String { r.map { String(format: "%g", $0) } ?? "-" }
        print("mic \(recorder.micDevice ?? "-") @ \(rate(recorder.micRate))  system \(recorder.systemDevice ?? "-") @ "
            + "\(rate(recorder.systemRate))  write failures \(recorder.writeFailures.count)")
    }
    do {
        let lengths = try recorder.stop()
        let mic = Double(lengths?.mic ?? 0) / 16_000, system = Double(lengths?.system ?? 0) / 16_000
        print(String(format: "stopped: mic %.2f s, system %.2f s (asked for %.0f s)", mic, system, seconds))
        return 0
    } catch {
        print("stop failed: \(error)")
        return 1
    }
}
