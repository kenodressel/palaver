import AVFoundation
import Foundation

/// The engine hears 16 kHz mono; any WAV is converted to it on reading.
public let engineSampleRate = 16_000.0

/// Frames per read. One `AVAudioFile.read` of a whole long file comes back
/// short (about 2000 frames in a spike), so files are read in chunks.
let wavChunkFrames: AVAudioFrameCount = 1_048_576

/// Samples [start, end) of a WAV at 16 kHz mono (`start`/`end` are 16 kHz
/// sample indices; nil means the file's start or end). Any sample rate is
/// resampled and any channel count averaged to mono, chunk by chunk.
public func readWav(_ url: URL, start: Int? = nil, end: Int? = nil) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let rate = format.sampleRate
    let channels = Int(format.channelCount)
    let ratio = rate / engineSampleRate

    let first = max(start ?? 0, 0)
    // Wanted output samples (nil: to the end of the file).
    let wanted: Int? = end.map { max($0 - first, 0) }
    if wanted == 0 { return [] }
    let startFrame = min(Int((Double(first) * ratio).rounded()), Int(file.length))
    file.framePosition = AVAudioFramePosition(startFrame)

    let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: engineSampleRate, channels: 1, interleaved: false)!
    let converter: AVAudioConverter? = rate == engineSampleRate ? nil : AVAudioConverter(from: monoFormat, to: outFormat)
    if rate != engineSampleRate && converter == nil { throw EngineError("cannot convert \(Int(rate)) Hz audio") }

    var samples = [Float]()
    func full() -> Bool { wanted.map { samples.count >= $0 } ?? false }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let p = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
    }

    var remainingFrames = Int(file.length) - startFrame
    if let w = wanted { remainingFrames = min(remainingFrames, Int((Double(w) * ratio).rounded(.up)) + 4_096)  } // margin: the resampler holds some back
    while remainingFrames > 0 && !full() {
        let want = AVAudioFrameCount(min(remainingFrames, Int(wavChunkFrames)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: want),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: want) else {
            throw EngineError("cannot allocate an audio buffer")
        }
        try file.read(into: buffer, frameCount: want)
        let got = Int(buffer.frameLength)
        if got == 0 { break }
        guard let data = buffer.floatChannelData, let m = mono.floatChannelData?[0] else {
            throw EngineError("wav has no float data")
        }
        mono.frameLength = AVAudioFrameCount(got)
        if channels == 1 {
            m.update(from: data[0], count: got)
        } else {
            for i in 0..<got {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                m[i] = sum / Float(channels)
            }
        }
        if let converter {
            try convert(mono, with: converter, into: &samples, format: outFormat, ratio: ratio, last: false)
        } else {
            append(mono)
        }
        remainingFrames -= got
    }
    if let converter, !full() {
        try convert(nil, with: converter, into: &samples, format: outFormat, ratio: ratio, last: true)  // flush
    }
    if let w = wanted, samples.count > w { samples.removeSubrange(w...) }
    return samples
}

private func convert(_ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, into samples: inout [Float],
                     format: AVAudioFormat, ratio: Double, last: Bool) throws {
    let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) / ratio) + 4_096
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        throw EngineError("cannot allocate an audio buffer")
    }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
        if supplied || input == nil {
            inputStatus.pointee = last ? .endOfStream : .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return input
    }
    if status == .error { throw EngineError("resampling failed: \(error?.localizedDescription ?? "unknown")") }
    if out.frameLength > 0, let p = out.floatChannelData?[0] {
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }
}
