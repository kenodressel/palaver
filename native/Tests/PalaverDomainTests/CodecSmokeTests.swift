import COgg
import COpus
import Testing

@Suite struct CodecSmokeTests {
    @Test func opusEncodesAndDecodesASilentFrame() throws {
        var err: Int32 = 0
        let enc = try #require(opus_encoder_create(16000, 1, OPUS_APPLICATION_AUDIO, &err))
        #expect(err == OPUS_OK)
        defer { opus_encoder_destroy(enc) }
        let dec = try #require(opus_decoder_create(16000, 1, &err))
        #expect(err == OPUS_OK)
        defer { opus_decoder_destroy(dec) }

        let pcm = [Float](repeating: 0, count: 320)  // 20 ms at 16 kHz
        var packet = [UInt8](repeating: 0, count: 4000)
        let n = opus_encode_float(enc, pcm, 320, &packet, Int32(packet.count))
        #expect(n > 0)

        var out = [Float](repeating: 1, count: 320)
        let got = opus_decode_float(dec, packet, n, &out, 320, 0)
        #expect(got == 320)
        #expect(out.allSatisfy { abs($0) < 0.01 })
    }

    @Test func oggStreamInitWorks() {
        var os = ogg_stream_state()
        #expect(ogg_stream_init(&os, 1) == 0)
        ogg_stream_clear(&os)
    }
}
