// Secrets in the macOS login Keychain (palaver/keychain.py, config.py `_token`): the cloud providers' API keys
// (account "<provider>.api_key") and the NOTION_TOKEN / HF_TOKEN tokens. Palaver 0.6 keeps them as generic passwords
// under the service "palaver.v2", each with one access list that trusts every Palaver executable of this app (Palaver,
// palaver-server, palaver-worker, palaver-lm, bin/palaver), so a key allowed once is allowed for all of them.
//
// The Python app (0.3, 0.5, and the developer fallback) wrote them with `keyring` under "palaver" (tokens also under the
// app's old name, "meeting-transcribe"), trusting only the Python that wrote them. Those items are never deleted here (a
// program they don't trust can't delete them without the user, and the developer fallback's Python still reads them):
// the first read of a key that is only there copies it into a new "palaver.v2" item with the shared access list. That read is the one the Keychain asks the user about ("Allow" is enough, no "Always Allow" needed);
// every Palaver program reads the copy silently afterwards, also after an update re-signs them.
//
// A presence check (`has`) reads the item's attributes only, never the secret, so it never asks the user anything;
// only a real use (`read`) reads the secret. Nothing here logs a key or puts one into an error.
import CKeychainACL
import Foundation
import PalaverCore
import PalaverDomain
import Security

/// Where secrets live. `KeychainStore` is the real one; tests and the end-to-end server use `FileKeyStore` (DEBUG).
public protocol KeyStore: AnyObject, Sendable {
    /// An item is there: attributes only, never a prompt.
    func has(_ account: String) -> Bool
    /// The secret; nil when there is none. May ask the user (the Keychain's own prompt).
    func read(_ account: String) throws -> String?
    func write(_ account: String, _ value: String) throws
    /// Removes it; none there is no error.
    func delete(_ account: String) throws
}

/// The Keychain failed (`keychain.KeychainError`); the text names the account, never a value.
public struct KeychainError: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

/// A value that is no API key (keychain.set's ValueError); the text never quotes the value.
public struct KeyRefused: Error, CustomStringConvertible {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var description: String { text }
}

public enum APIKey {
    /// Longer than any API key; a pasted file is not a key.
    public static let MAX_LENGTH = 4096

    /// `keychain.set`'s checks: the value stripped, then at most 4096 characters, one line, no whitespace inside and
    /// latin-1 only (it goes into an HTTP header). The checked value, or `KeyRefused`.
    public static func checked(_ value: String) throws -> String {
        let v = Py.strip(value)
        let scalars = v.unicodeScalars
        if v.isEmpty || scalars.count > MAX_LENGTH || scalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw KeyRefused("that is not an API key")
        }
        if scalars.contains(where: isSpace) {
            throw KeyRefused("an API key has no spaces inside; copy it again without them")
        }
        if scalars.contains(where: { $0.value > 0xFF }) {
            throw KeyRefused("the key has a character no API key has (copied with a dash or quote that was changed?); "
                             + "copy it again")
        }
        return v
    }

    /// `str.isspace` for one character.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }
}

public enum KeyStores {
    #if DEBUG
    /// `PALAVER_TEST_KEYSTORE`: a JSON file standing in for the Keychain. Debug builds only (tests, the end-to-end
    /// server): a release build does not know the name, so no environment can move its keys out of the Keychain.
    public static let TEST_ENV = "PALAVER_TEST_KEYSTORE"
    #endif

    /// The Keychain; in a debug build with `PALAVER_TEST_KEYSTORE` set, that file instead.
    public static func make(env: [String: String] = ProcessInfo.processInfo.environment) -> KeyStore {
        #if DEBUG
        if let file = env[TEST_ENV], !file.isEmpty { return FileKeyStore(URL(fileURLWithPath: file)) }
        #endif
        return KeychainStore()
    }
}

/// The macOS Keychain: generic passwords under `service`, account as given; reads fall back to `legacyServices` (the
/// Python app's items), whose items are copied into `service` at their first read and never deleted.
public final class KeychainStore: KeyStore, @unchecked Sendable {
    /// Where Palaver 0.6 keeps the keys: its own items, each with the shared access list.
    public static let SERVICE = "palaver.v2"
    /// The Python app's service (palaver/keychain.py): read and copied; a write here updates its value; never deleted.
    public static let PYTHON_SERVICE = "palaver"
    /// Tokens stored under the app's old name (config.OLD_KEYCHAIN_SERVICE).
    public static let OLD_SERVICE = "meeting-transcribe"
    /// The programs a key is shared with: whichever of them sit in the app's Contents/MacOS (or the build folder) of
    /// the running one, plus the `palaver` command in the bundle (`CLI_IN_BUNDLE`). palaver-cli is that command's
    /// build name (`palaver mcp`, Claude's tools); it can't be `palaver` beside `Palaver` on a case-insensitive disk.
    /// palaver-lm sits in Contents/MacOS like the others (in a checkout it is xcodebuild's, outside the build folder: a
    /// development detail). No Python: 0.6 ships none (the developer fallback's Python reads the "palaver" items).
    /// When the programs or their places change, the new list needs a new service name (copied from this one at the
    /// first read, silently, by any program this one's list trusts).
    public static let EXECUTABLES = ["Palaver", "palaver-server", "palaver-worker", "palaver-lm", "palaver-cli"]
    /// The `palaver` command in Palaver.app (McpSetup.CLI_IN_BUNDLE).
    public static let CLI_IN_BUNDLE = McpSetup.CLI_IN_BUNDLE
    /// Set on every item added with the shared access list (kSecAttrGeneric), to tell them apart in a dump.
    static let MARKER = Data("palaver-acl-4".utf8)
    /// Set on the item `delete` leaves in `service` while the Python app's item is still there (it can't be removed):
    /// the key is gone for Palaver, and the old item is not copied back at the next read.
    static let REMOVED = Data("palaver-removed".utf8)

    let service: String
    let legacyServices: [String]
    /// A keychain file to use instead of the user's search list (tests); nil: the login keychain.
    let keychain: CFTypeRef?
    let trusted: [String]

    /// Stand-ins for tests: SecItemAdd, the update that never asks, the access list (nil: it can't be made) and the log
    /// (stderr).
    var secAdd: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    var updateQuietly: (CFDictionary, CFDictionary) -> OSStatus = { palaver_update_without_asking($0, $1) }
    var makeAccess: ([String], String) -> CFTypeRef? = { palaver_access_trusting($0 as CFArray, $1 as CFString) }
    var log: (String) -> Void = { FileHandle.standardError.write(Data("palaver: \($0)\n".utf8)) }

    /// The keys this process could not copy (account as UTF-8 bytes): logged once, not at every read.
    private var copyFailed = Set<Data>()
    private let lock = NSLock()

    public init(service: String = SERVICE, legacyServices: [String] = [PYTHON_SERVICE, OLD_SERVICE],
                keychain: CFTypeRef? = nil, trusted: [String]? = nil) {
        self.service = service
        self.legacyServices = legacyServices
        self.keychain = keychain
        self.trusted = trusted ?? Self.palaverExecutables()
    }

    /// The other Palaver executables of this process's app (its Contents/MacOS and Contents/Resources/bin/palaver,
    /// whichever of them this process is) or build folder.
    public static func palaverExecutables(running: URL? = Bundle.main.executableURL,
                                          isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String] {
        guard let me = running?.resolvingSymlinksInPath().standardizedFileURL else { return [] }
        let candidates: [String]
        if let bundle = McpSetup.bundle(of: me) {
            let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            candidates = EXECUTABLES.map { macOS.appendingPathComponent($0).path } + [bundle.appendingPathComponent(CLI_IN_BUNDLE).path]
        } else {
            candidates = EXECUTABLES.map { me.deletingLastPathComponent().appendingPathComponent($0).path }
        }
        return candidates.filter { $0 != me.path && isExecutable($0) }
    }

    /// Every call goes through here: in a test process only a test keychain may be used, never the user's (made here
    /// it touches nothing; the first use would).
    private func query(_ service: String, _ account: String) -> [CFString: Any] {
        #if DEBUG
        if keychain == nil && TestIsolation.isTestProcess {
            fatalError("TestIsolation: a test would use the user's real Keychain; give it a test keychain or a FileKeyStore")
        }
        #endif
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if let keychain { q[kSecMatchSearchList] = [keychain] as CFArray }
        return q
    }

    /// The item's attributes (never its secret): nil when there is none.
    private func attributes(_ service: String, _ account: String) -> [CFString: Any]? {
        var q = query(service, account)
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? (out as? [CFString: Any]) ?? [:] : nil
    }

    private static func isRemoved(_ item: [CFString: Any]) -> Bool { (item[kSecAttrGeneric] as? Data) == REMOVED }

    public func has(_ account: String) -> Bool {
        if let item = attributes(service, account) { return !Self.isRemoved(item) }
        return legacyServices.contains { attributes($0, account) != nil }
    }

    public func read(_ account: String) throws -> String? {
        if let item = attributes(service, account) {
            return Self.isRemoved(item) ? nil : try secret(service, account).flatMap(Self.text)
        }
        for legacy in legacyServices {
            guard let data = try secret(legacy, account) else { continue }
            guard let value = Self.text(data) else { return nil }
            copy(account, value, from: legacy)
            return value
        }
        return nil
    }

    /// The item's secret (this read may ask the user); nil when there is no item.
    private func secret(_ service: String, _ account: String) throws -> Data? {
        var q = query(service, account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError("could not read \(account) from the Keychain")
        }
        return data
    }

    /// A stored secret as text; nil when it is empty or no UTF-8.
    private static func text(_ data: Data) -> String? {
        String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the key in `service` with the shared access list (this program's own item: replacing it asks nothing).
    /// The Python app's item, when there is one, gets the new value too if that needs nobody (a new value is not a read:
    /// measured silent), so the developer fallback's Python stays in step; its access list stays as it is.
    public func write(_ account: String, _ value: String) throws {
        let deleted = SecItemDelete(query(service, account) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound, add(account, Data(value.utf8), plainIfRefused: true) else {
            throw KeychainError("could not save \(account) in the Keychain")
        }
        guard let python = legacyServices.first, attributes(python, account) != nil else { return }
        let status = updateQuietly(query(python, account) as CFDictionary, [kSecValueData: Data(value.utf8)] as CFDictionary)
        if status != errSecSuccess {
            log("Keychain: \(account) in the Python app's item (\(python)) keeps its old value (\(status))")
        }
    }

    /// Removes the key from `service`; when the Python app's item is there (which stays), a removed-mark takes the
    /// key's place so that item isn't copied back. None there is no error.
    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError("could not remove \(account) from the Keychain")
        }
        guard legacyServices.contains(where: { attributes($0, account) != nil }) else { return }
        guard add(account, Data(), generic: Self.REMOVED, plainIfRefused: true) else {
            throw KeychainError("could not remove \(account) from the Keychain")
        }
    }

    /// Adds the item to `service` with the shared access list and `generic` (the marker). When the list can't be made
    /// or is refused: `plainIfRefused` adds it without them (a key the user saves is kept, even if other programs will
    /// ask for it), else nothing is added. true: added.
    private func add(_ account: String, _ data: Data, generic: Data = MARKER, plainIfRefused: Bool) -> Bool {
        var item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                     kSecValueData: data]
        if let keychain { item[kSecUseKeychain] = keychain }
        if let access = makeAccess(trusted, "Palaver: \(account)") {
            var marked = item
            marked[kSecAttrAccess] = access
            marked[kSecAttrGeneric] = generic
            if secAdd(marked as CFDictionary) == errSecSuccess { return true }
        }
        if !plainIfRefused { return false }
        if generic != Self.MARKER { item[kSecAttrGeneric] = generic }
        return secAdd(item as CFDictionary) == errSecSuccess
    }

    /// The Python app's key, read just now, copied into `service` (only with the shared access list: a copy that
    /// trusts only this program would hide the old item from the others behind a prompt of its own). Another Palaver
    /// program copying it at the same moment is fine (one of the adds finds the other's item). A failure is logged once
    /// per process, without the value; the key is still read from the old item meanwhile.
    private func copy(_ account: String, _ value: String, from legacy: String) {
        if add(account, Data(value.utf8), plainIfRefused: false) || attributes(service, account) != nil { return }
        guard lock.withLock({ copyFailed.insert(Data(account.utf8)).inserted }) else { return }
        log("Keychain: \(account) could not be copied from the Python app's item (\(legacy)); it is read from there")
    }
}

#if DEBUG
/// A JSON object `{account: value}` in a file, standing in for the Keychain (`PALAVER_TEST_KEYSTORE`): tests and the
/// end-to-end server, which read it back as the Python e2e harness's fake keychain does.
public final class FileKeyStore: KeyStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    public init(_ url: URL) { self.url = url }

    private func all() -> [(String, String)] {
        guard let data = try? Data(contentsOf: url), case .object(let fields)? = JSONValue.parse(data) else { return [] }
        return fields.compactMap { k, v in v.stringValue.map { (k, $0) } }
    }

    private func save(_ fields: [(String, String)]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSONValue.object(fields.map { ($0.0, .string($0.1)) }).encoded(indent: nil).utf8).write(to: url, options: .atomic)
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    public func has(_ account: String) -> Bool { lock.withLock { all().contains { Self.same($0.0, account) } } }

    public func read(_ account: String) throws -> String? {
        lock.withLock { all().first { Self.same($0.0, account) }?.1 }
    }

    public func write(_ account: String, _ value: String) throws {
        try lock.withLock { try save(all().filter { !Self.same($0.0, account) } + [(account, value)]) }
    }

    public func delete(_ account: String) throws {
        try lock.withLock { try save(all().filter { !Self.same($0.0, account) }) }
    }
}
#endif
