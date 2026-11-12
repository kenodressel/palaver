import Darwin
import Foundation
@testable import PalaverDomain
import Testing

@Suite struct FileTimesTests {
    private func mtime(_ sec: Int, _ nsec: Int) throws -> Int? {
        let t = TempFolder("filetimes"); defer { t.remove() }
        let file = t.url.appendingPathComponent("f")
        try Data().write(to: file)
        let stamp = timespec(tv_sec: sec, tv_nsec: nsec)
        #expect(utimensat(AT_FDCWD, file.path, [stamp, stamp], 0) == 0)
        var st = stat()
        #expect(stat(file.path, &st) == 0)
        return FileTimes.mtimeNs(st)
    }

    @Test func test_a_time_beyond_int_nanoseconds_is_nil() {
        // APFS clamps a file's time to Int.max nanoseconds itself, so this is tried on the timespec (other file
        // systems, network shares and odd mounts can report what a Python int holds and an Int does not).
        #expect(FileTimes.ns(timespec(tv_sec: 32_503_680_000, tv_nsec: 5)) == nil)  // year 3000
        #expect(FileTimes.ns(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_807)) == Int.max)
        #expect(FileTimes.ns(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_808)) == nil)
        #expect(FileTimes.ns(timespec(tv_sec: -9_223_372_037, tv_nsec: 0)) == nil)
    }

    @Test func test_a_file_set_to_year_3000_does_not_trap() throws {
        _ = try mtime(32_503_680_000, 5)  // clamped by APFS; must simply return
    }
}
