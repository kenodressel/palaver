import Darwin
import Foundation
@testable import PalaverDomain
import Testing

@Suite struct FileTimesTests {
    @Test func test_a_time_beyond_int_nanoseconds_is_nil() {
        // APFS clamps a file's time to Int.max nanoseconds itself, so this is tried on the timespec (other file
        // systems, network shares and odd mounts can report what a Python int holds and an Int does not).
        #expect(FileTimes.ns(timespec(tv_sec: 32_503_680_000, tv_nsec: 5)) == nil)  // year 3000
        #expect(FileTimes.ns(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_807)) == Int.max)
        #expect(FileTimes.ns(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_808)) == nil)
        #expect(FileTimes.ns(timespec(tv_sec: -9_223_372_037, tv_nsec: 0)) == nil)
    }
}
