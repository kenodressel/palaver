// A safetensors file (embeddings.py `load_safetensors`), memory-mapped, not read: an 8-byte little-endian header
// length, a JSON header {name: {dtype, shape, data_offsets}, "__metadata__": …}, then the data. The header's length,
// offsets and shapes come from the file, so each is checked against the file's size and the dtype's size with
// overflow-safe arithmetic: a broken file throws, never traps.
import Foundation
import PalaverCore

public enum SafetensorsError: Error, CustomStringConvertible {
    case unreadable(String)
    case badHeader(String)
    case noTensor(String)
    case unsupported(String)
    case outOfRange(String)

    public var description: String {
        switch self {
        case .unreadable(let m): return "safetensors: can't read \(m)"
        case .badHeader(let m): return "safetensors: bad header: \(m)"
        case .noTensor(let m): return "safetensors: no tensor \(m)"
        case .unsupported(let m): return "safetensors: \(m)"
        case .outOfRange(let m): return "safetensors: \(m)"
        }
    }
}

/// The mapped file, shared by the tensors that point into it.
final class SafetensorsMap: @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
}

public struct Safetensors {
    /// The tensor names in the header's order (`__metadata__` left out).
    public let names: [String]
    private let tensors: [String: SafeTensor]

    /// The file at `url`, memory-mapped (`Data(contentsOf:options: .alwaysMapped)`).
    public init(url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw SafetensorsError.unreadable("\(url.path): \(error)")
        }
        try self.init(map: SafetensorsMap(data))
    }

    init(map: SafetensorsMap) throws {
        let data = map.data
        let size = data.count
        guard size >= 8 else { throw SafetensorsError.badHeader("the file has \(size) bytes, fewer than 8") }
        var length: UInt64 = 0
        for i in 0..<8 { length |= UInt64(data[data.startIndex + i]) << (8 * UInt64(i)) }
        guard length <= UInt64(size - 8) else {
            throw SafetensorsError.badHeader("its length \(length) is more than the file's \(size - 8) bytes after it")
        }
        let headerEnd = 8 + Int(length)
        let header: JSONValue
        do { header = try PythonJSON.parse(data.subdata(in: data.startIndex + 8 ..< data.startIndex + headerEnd)) } catch {
            throw SafetensorsError.badHeader("\(error)")
        }
        guard case .object(let fields) = header else { throw SafetensorsError.badHeader("not an object") }
        let available = size - headerEnd
        var names: [String] = []
        var tensors: [String: SafeTensor] = [:]
        for (name, info) in fields where name != "__metadata__" {
            guard let dtypeName = info["dtype"]?.stringValue else { throw SafetensorsError.badHeader("\(name): no dtype") }
            guard let dtype = SafeTensor.DType(rawValue: dtypeName) else {
                throw SafetensorsError.unsupported("\(name): dtype \(dtypeName) is not F32, F16 or I64")
            }
            guard let dims = info["shape"]?.arrayValue else { throw SafetensorsError.badHeader("\(name): no shape") }
            var shape: [Int] = []
            var count = 1
            for d in dims {
                guard case .int(let n) = d, n >= 0 else { throw SafetensorsError.badHeader("\(name): bad shape") }
                let (product, overflow) = count.multipliedReportingOverflow(by: n)
                guard !overflow else { throw SafetensorsError.badHeader("\(name): shape too big") }
                shape.append(n)
                count = product
            }
            guard let offsets = info["data_offsets"]?.arrayValue, offsets.count == 2,
                  case .int(let start) = offsets[0], case .int(let end) = offsets[1],
                  start >= 0, start <= end, end <= available
            else { throw SafetensorsError.badHeader("\(name): data_offsets outside the file's data") }
            let (bytes, overflow) = count.multipliedReportingOverflow(by: dtype.size)
            guard !overflow, bytes == end - start else {
                throw SafetensorsError.badHeader("\(name): \(end - start) bytes for shape \(shape) of \(dtypeName)")
            }
            if tensors[name] == nil { names.append(name) }
            tensors[name] = SafeTensor(map: map, name: name, offset: headerEnd + start, shape: shape, dtype: dtype, count: count)
        }
        self.names = names
        self.tensors = tensors
    }

    /// The tensor `name`; an error when the file has none of that name.
    public func tensor(_ name: String) throws -> SafeTensor {
        guard let t = tensors[name] else { throw SafetensorsError.noTensor(name) }
        return t
    }
}

/// One tensor of a mapped safetensors file. F32 is used in place from the map (copied once only when the file puts
/// it at an offset that is not 4-aligned); F16 is converted to Float32: all of it once, on first use, and kept, or
/// one row at a time.
public struct SafeTensor {
    public enum DType: String, Sendable {
        case f32 = "F32", f16 = "F16", i64 = "I64"
        var size: Int { switch self { case .f32: return 4; case .f16: return 2; case .i64: return 8 } }
    }

    public let name: String
    public let shape: [Int]
    public let dtype: DType
    /// The number of elements.
    public let count: Int
    let map: SafetensorsMap
    /// Byte offset of the first element in the file.
    let offset: Int
    private let cache = Cache()

    init(map: SafetensorsMap, name: String, offset: Int, shape: [Int], dtype: DType, count: Int) {
        self.map = map
        self.name = name
        self.offset = offset
        self.shape = shape
        self.dtype = dtype
        self.count = count
    }

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var floats: [Float]?
        var rowsConverted = 0
    }

    /// How many single rows `row(_:)` has converted from F16 (a test's counter).
    public var rowsConverted: Int { cache.lock.withLock { cache.rowsConverted } }
    /// Whether the whole tensor was converted (or copied) and kept.
    public var isConverted: Bool { cache.lock.withLock { cache.floats != nil } }

    /// The bytes of `range` (in elements) of this tensor.
    private func withBytes<R>(_ elements: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try map.data.withUnsafeBytes { all in
            let from = offset + elements.lowerBound * dtype.size, to = offset + elements.upperBound * dtype.size
            return try body(UnsafeRawBufferPointer(rebasing: all[from..<to]))
        }
    }

    private static func converted(_ raw: UnsafeRawBufferPointer, _ dtype: DType) -> [Float] {
        switch dtype {
        case .f32:
            return (0 ..< raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        case .f16:
            return (0 ..< raw.count / 2).map { halfToFloat(raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        case .i64:
            return []
        }
    }

    /// The tensor as Float32, row-major: F32 in place from the map; F16 converted on first use and kept.
    public func withFloat32<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) throws -> R {
        guard dtype != .i64 else { throw SafetensorsError.unsupported("\(name) is I64, not a float tensor") }
        if dtype == .f32 {
            let inPlace: R? = try map.data.withUnsafeBytes { all -> R? in
                guard let base = all.baseAddress, Int(bitPattern: base + offset) % MemoryLayout<Float>.alignment == 0
                else { return nil }
                return try body(UnsafeBufferPointer(start: (base + offset).assumingMemoryBound(to: Float.self), count: count))
            }
            if let inPlace { return inPlace }
        }
        let floats: [Float] = cache.lock.withLock {
            if let kept = cache.floats { return kept }
            let made = withBytes(0..<count) { Self.converted($0, dtype) }
            cache.floats = made
            return made
        }
        return try floats.withUnsafeBufferPointer(body)
    }

    /// Row `i` of a 2-D tensor as Float32. An F16 row is converted alone (the vocabulary is never converted whole
    /// for a lookup), unless the whole tensor already was.
    public func row(_ i: Int) throws -> [Float] {
        guard shape.count == 2 else { throw SafetensorsError.unsupported("\(name) is not 2-D") }
        guard dtype != .i64 else { throw SafetensorsError.unsupported("\(name) is I64, not a float tensor") }
        guard i >= 0, i < shape[0] else { throw SafetensorsError.outOfRange("row \(i) of \(name) with \(shape[0]) rows") }
        let cols = shape[1]
        let range = i * cols ..< (i + 1) * cols
        if dtype == .f16 {
            let kept: [Float]? = cache.lock.withLock {
                if let all = cache.floats { return Array(all[range]) }
                cache.rowsConverted += 1
                return nil
            }
            if let kept { return kept }
        }
        return withBytes(range) { Self.converted($0, dtype) }
    }
}

/// IEEE 754 half → single, exactly (subnormals, infinities and NaN included).
func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exponent = UInt32(h >> 10) & 0x1f
    var mantissa = UInt32(h & 0x3ff)
    switch exponent {
    case 0:
        if mantissa == 0 { return Float(bitPattern: sign) }
        var e: UInt32 = 127 - 15 + 1
        while mantissa & 0x400 == 0 { mantissa <<= 1; e -= 1 }
        mantissa &= 0x3ff
        return Float(bitPattern: sign | (e << 23) | (mantissa << 13))
    case 0x1f:
        return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
    default:
        return Float(bitPattern: sign | ((exponent + 127 - 15) << 23) | (mantissa << 13))
    }
}
