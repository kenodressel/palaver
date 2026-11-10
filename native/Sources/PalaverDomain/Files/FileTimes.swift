import Darwin

/// A file's modification time as Python's `st_mtime_ns` (an arbitrary-precision int that never fails).
public enum FileTimes {
    /// `tv_sec * 1_000_000_000 + tv_nsec`, or nil when it does not fit an Int (a year beyond about 2262): callers
    /// choose what "unknown" means for them (never "current") instead of trapping in a periodic scan.
    public static func mtimeNs(_ st: stat) -> Int? { ns(st.st_mtimespec) }

    static func ns(_ time: timespec) -> Int? {
        let (product, overflowed) = Int(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflowed else { return nil }
        let (sum, overflowedSum) = product.addingReportingOverflow(Int(time.tv_nsec))
        return overflowedSum ? nil : sum
    }
}
