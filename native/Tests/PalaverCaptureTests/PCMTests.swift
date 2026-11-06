import Foundation
import Testing
@testable import PalaverCapture

private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

@Suite struct PCMTests {
    @Test func monoFloat32IsUnchanged() {
        let x = sine(512)
        #expect(PCM.decodeMono(bytes(x), channels: 1, bits: 32, isFloat: true, nonInterleaved: false) == x)
    }

    @Test func interleavedStereoDownmixes() {
        let interleaved = (0..<100).flatMap { _ in [Float(0.2), Float(0.4)] }
        let out = PCM.decodeMono(bytes(interleaved), channels: 2, bits: 32, isFloat: true, nonInterleaved: false)!
        #expect(out.count == 100)
        #expect(out.allSatisfy { abs($0 - 0.3) < 1e-6 })
    }

    @Test func planarStereoIsSplitByChannel() {
        // Reshaping planar buffers as interleaved would scramble the timeline.
        let left = sine(100), right = sine(100)
        let out = PCM.decodeMono(bytes(left + right), channels: 2, bits: 32, isFloat: true, nonInterleaved: true)!
        #expect(zip(out, left).allSatisfy { abs($0 - $1) < 1e-6 })
        let interleavedReading = PCM.decodeMono(bytes(left + right), channels: 2, bits: 32, isFloat: true,
                                                nonInterleaved: false)!
        #expect(!zip(interleavedReading, left).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func planarDifferentChannelsAverage() {
        let left = [Float](repeating: 0.1, count: 50), right = [Float](repeating: -0.5, count: 50)
        let out = PCM.decodeMono(bytes(left + right), channels: 2, bits: 32, isFloat: true, nonInterleaved: true)!
        #expect(out.count == 50 && out.allSatisfy { abs($0 + 0.2) < 1e-6 })
    }

    @Test func int16ScalesBy32768() {
        let x: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
        let out = PCM.decodeMono(bytes(x), channels: 1, bits: 16, isFloat: false, nonInterleaved: false)!
        #expect(out == [0, 0.5, -0.5, Float(32_767) / 32_768, -1])
    }

    @Test func int32ScalesBy2Pow31() {
        let x: [Int32] = [0, 1 << 30, -(1 << 30), Int32.min]
        let out = PCM.decodeMono(bytes(x), channels: 1, bits: 32, isFloat: false, nonInterleaved: false)!
        #expect(out == [0, 0.5, -0.5, -1])
    }

    @Test func float64InterleavedAndInt16Planar() {
        let d: [Double] = [0.25, 0.75, -0.5, 0.5]  // two stereo frames
        #expect(PCM.decodeMono(bytes(d), channels: 2, bits: 64, isFloat: true, nonInterleaved: false) == [0.5, 0])
        let p: [Int16] = [16_384, 16_384, 0, -16_384]  // planar: L = [.5, .5], R = [0, -.5]
        #expect(PCM.decodeMono(bytes(p), channels: 2, bits: 16, isFloat: false, nonInterleaved: true) == [0.25, 0])
    }

    @Test func oddTailFrameIsDropped() {
        // frames = size // channels, as numpy's reshape after trimming.
        let x: [Float] = [0.2, 0.4, 0.6]
        #expect(PCM.decodeMono(bytes(x), channels: 2, bits: 32, isFloat: true, nonInterleaved: false)!.count == 1)
    }

    @Test func rejectsWhatPythonRejects() {
        #expect(PCM.decodeMono(Data([1, 2, 3]), channels: 1, bits: 16, isFloat: false, nonInterleaved: false) == nil)
        #expect(PCM.decodeMono(Data([1, 2, 3]), channels: 1, bits: 24, isFloat: false, nonInterleaved: false) == nil)
        let f = PCMFormat(sampleRate: 48_000, formatFlags: PCMFormat.flagIsFloat, channels: 1, bitsPerChannel: 32)
        #expect(PCM.mono(bytes([Float(0.1)]), format: f)?.rate == 48_000)
        var notPCM = f; notPCM.formatID = 0x6161_6320  // 'aac '
        #expect(PCM.mono(bytes([Float(0.1)]), format: notPCM) == nil)
        var noRate = f; noRate.sampleRate = 0
        #expect(PCM.mono(bytes([Float(0.1)]), format: noRate) == nil)
        var noChannels = f; noChannels.channels = 0
        #expect(PCM.mono(bytes([Float(0.1)]), format: noChannels) == nil)
        #expect(PCM.mono(Data(), format: f) == nil)
    }

    @Test func formatFlagsDecideFloatAndPlanar() {
        let planarInt = PCMFormat(sampleRate: 24_000, formatFlags: PCMFormat.flagIsNonInterleaved | 0x4,
                                  channels: 2, bitsPerChannel: 16)
        #expect(!planarInt.isFloat && planarInt.nonInterleaved)
        let out = PCM.mono(bytes([Int16(16_384), 16_384, 0, -16_384]), format: planarInt)!
        #expect(out.samples == [0.25, 0] && out.rate == 24_000)
    }

    @Test func int16ConversionMatchesNumpy() {
        // np.clip(x * 32767.0, -32768, 32767).astype(np.int16): Float32 product, clip, truncate toward zero.
        let x: [Float] = [0, 1, -1, 1.5, -1.5, 0.5, -0.5, 0.99999, -0.99999, 1e-5, -3.3e-5, 0.000_030_6, .nan]
        #expect(PCM.int16(x[...]) == [0, 32_767, -32_767, 32_767, -32_768, 16_383, -16_383, 32_766, -32_766,
                                      0, -1, 1, 0])
    }
}
