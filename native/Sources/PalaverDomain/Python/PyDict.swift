// Python's dict where its order reaches a file, a response or a tie-break: string keys in
// insertion order. Setting an existing key keeps its place; a removed key set again goes last.
import PalaverCore

/// A string as Python compares it: by code points (Swift's `String ==` and hashing treat canonically equivalent
/// spellings, "Zoë" as one letter or as e + diaeresis, as one key).
public struct ScalarKey: Hashable, Sendable {
    let scalars: [UInt32]
    public init(_ s: String) { scalars = s.unicodeScalars.map(\.value) }
}

public struct PyDict<Value>: Sequence {
    public typealias Element = (key: String, value: Value)

    public private(set) var keys: [String] = []
    public private(set) var values: [Value] = []
    private var index: [ScalarKey: Int] = [:]

    public init() {}

    /// `dict(pairs)`: a repeated key keeps its first place and takes its last value.
    public init(_ pairs: [(String, Value)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// `d.get(key)`; setting nil is `d.pop(key, None)`.
    public subscript(key: String) -> Value? {
        get { index[ScalarKey(key)].map { values[$0] } }
        set {
            guard let newValue else { removeValue(forKey: key); return }
            if let i = index[ScalarKey(key)] {
                values[i] = newValue
            } else {
                index[ScalarKey(key)] = keys.count
                keys.append(key)
                values.append(newValue)
            }
        }
    }

    /// `d.pop(key, None)`.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> Value? {
        guard let i = index.removeValue(forKey: ScalarKey(key)) else { return nil }
        keys.remove(at: i)
        let value = values.remove(at: i)
        for j in i..<keys.count { index[ScalarKey(keys[j])] = j }
        return value
    }

    public func makeIterator() -> AnyIterator<Element> {
        var i = 0
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], values[i])
        }
    }
}

extension PyDict: Equatable where Value: Equatable {
    /// Python's dict `==`: the same keys with equal values, in any order.
    public static func == (a: PyDict, b: PyDict) -> Bool {
        a.count == b.count && zip(a.keys, a.values).allSatisfy { key, value in b[key] == value }
    }
}

extension PyDict where Value == JSONValue {
    /// The fields of a JSON object, in file order; nil for anything else.
    public init?(_ json: JSONValue) {
        guard case .object(let fields) = json else { return nil }
        self.init(fields)
    }

    /// As a JSON object, keys in order.
    public var json: JSONValue { .object(zip(keys, values).map { ($0, $1) }) }
}
