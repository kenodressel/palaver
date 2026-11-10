// Free memory (daemon.py available_memory_gb): the daemon's queues and the window's server ask it
// before a local model starts.
import Darwin
import Foundation

public enum FreeMemory {
    /// Memory macOS can hand out without swapping: free, inactive, speculative and purgeable pages
    /// (daemon.py available_memory_gb, from the kernel's counters instead of `vm_stat`); unknown
    /// counts as plenty.
    public static func availableGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return .infinity }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return Double(pages) * Double(page) / 1_073_741_824
    }

    /// The same sum from `vm_stat`'s output; nil when it can't be read.
    public static func fromVMStat(_ out: String) -> Double? {
        guard let r = out.range(of: #"page size of (\d+)"#, options: .regularExpression),
              let page = Double(out[r].split(separator: " ").last ?? "") else { return nil }
        var pages: [String: Double] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let n = Double(v) else { return nil }
            pages[parts[0].trimmingCharacters(in: .whitespaces)] = n
        }
        let kinds = ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"]
        return kinds.reduce(0) { $0 + (pages[$1] ?? 0) } * page / 1_073_741_824
    }
}
