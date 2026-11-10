// API keys and tokens (keychain.py, config.py `_token`): the checks a key passes, the file key store the tests and the
// end-to-end server use, and the real Keychain code against a throwaway keychain file (never the user's).
import CKeychainACL
import Foundation
import Security
import Testing
import PalaverCore
import PalaverDomain
@testable import PalaverCloud

@Suite struct APIKeyTests {
    @Test func pastedWhitespaceIsDropped() throws {
        #expect(try APIKey.checked("  sk-ant-secret-1234  \n") == "sk-ant-secret-1234")
    }

    @Test(arguments: ["", "   ", "two\nlines", String(repeating: "x", count: 5000)])
    func whatIsNoKeyIsRefused(_ value: String) {
        let e = thrown { try APIKey.checked(value) } as? KeyRefused
        #expect(e?.text == "that is not an API key")
    }

    @Test(arguments: ["sk-ant-abc def", "sk-ant-abc\tdef", "sk-ant-ä€x", "sk-ant-—x"])
    func spacesInsideOrOddCharactersAreRefusedWithoutQuotingTheKey(_ value: String) {
        let e = thrown { try APIKey.checked(value) } as? KeyRefused
        #expect(e != nil && !(e?.text.contains(value) ?? true))
        #expect(e?.text.contains("space") == true || e?.text.contains("character") == true)
    }

    @Test func latin1IsFine() throws {
        #expect(try APIKey.checked("sk-ant-äöü") == "sk-ant-äöü")  // odd, but it fits an HTTP header
    }
}

@Suite struct FileKeyStoreTests {
    @Test func setReadHasDelete() throws {
        let home = Home()
        let keys = home.keys
        #expect(try keys.read("anthropic.api_key") == nil && !keys.has("anthropic.api_key"))
        try keys.write("anthropic.api_key", KEY)
        #expect(home.keychain == ["anthropic.api_key": KEY])
        #expect(try keys.read("anthropic.api_key") == KEY && keys.has("anthropic.api_key"))
        try keys.delete("anthropic.api_key")
        try keys.delete("anthropic.api_key")  // already gone: no error
        #expect(home.keychain.isEmpty)
    }

    @Test func theTestEnvironmentPicksTheFile() throws {
        let home = Home()
        let file = home.dir.appendingPathComponent("chosen.json")
        let keys = KeyStores.make(env: [KeyStores.TEST_ENV: file.path])
        try keys.write("openai.api_key", "sk-x")
        #expect(PythonJSON.read(file)?["openai.api_key"]?.stringValue == "sk-x")
    }
}

/// The Keychain code on a keychain file of the test's own, unlocked with a password nobody sees, deleted afterwards:
/// never the user's login keychain.
final class TestKeychain {
    let dir = tempFolder("keychain")
    let keychain: CFTypeRef

    init() throws {
        var status: OSStatus = 0
        let made = palaver_keychain_create(dir.appendingPathComponent("test.keychain-db").path, UUID().uuidString, &status)
        guard status == errSecSuccess, let out = made else { throw KeychainError("could not create a test keychain (\(status))") }
        keychain = out
    }

    deinit {
        _ = palaver_keychain_delete(keychain)
        try? FileManager.default.removeItem(at: dir)
    }

    func store(service: String = "palaver-test-\(UUID().uuidString)", legacy: [String] = []) -> KeychainStore {
        KeychainStore(service: service, legacyServices: legacy, keychain: keychain, trusted: [])
    }

    /// An item as palaver-python's keyring writes it: a plain generic password, no marker, no access list of ours.
    func addAsPython(service: String, account: String, value: String) -> OSStatus {
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: Data(value.utf8), kSecUseKeychain: keychain] as CFDictionary, nil)
    }

    /// The item's value as text, read by this (trusted) test process; nil when there is none.
    func value(service: String, account: String) -> String? {
        var out: CFTypeRef?
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
                                  kSecMatchSearchList: [keychain] as CFArray]
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
    }

    func attributes(service: String, account: String) -> [CFString: Any]? {
        var out: CFTypeRef?
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
                                  kSecMatchSearchList: [keychain] as CFArray]
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? [CFString: Any] : nil
    }
}

@Suite(.serialized) struct KeychainStoreTests {
    @Test func writeHasReadDeleteInAKeychain() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)"
        let keys = kc.store(service: service)
        #expect(!keys.has("anthropic.api_key"))
        #expect(try keys.read("anthropic.api_key") == nil)
        try keys.write("anthropic.api_key", KEY)
        #expect(keys.has("anthropic.api_key"))
        #expect(try keys.read("anthropic.api_key") == KEY)
        try keys.write("anthropic.api_key", "sk-ant-replaced-0000")  // saved again: one item, the new value
        #expect(try keys.read("anthropic.api_key") == "sk-ant-replaced-0000")
        // Written here: the marker that it carries Palaver's access list.
        #expect(kc.attributes(service: service, account: "anthropic.api_key")?[kSecAttrGeneric] as? Data == KeychainStore.MARKER)
        try keys.delete("anthropic.api_key")
        try keys.delete("anthropic.api_key")  // none there: no error
        #expect(!keys.has("anthropic.api_key"))
    }

    /// The upgrade (final review I1, option b): the Python app's item is copied into a new item with the shared
    /// access list at its first read, and never changed or deleted.
    @Test func aKeyThePythonAppWroteIsCopiedIntoANewItemAndTheOldOneStays() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "openai.api_key", value: "sk-proj-from-python-0123") == errSecSuccess)
        let keys = kc.store(service: service, legacy: [python])
        #expect(keys.has("openai.api_key"))
        #expect(kc.attributes(service: service, account: "openai.api_key") == nil)  // `has` copies nothing
        #expect(try keys.read("openai.api_key") == "sk-proj-from-python-0123")
        // The copy: Palaver's own item, with the access list (marker); the old item as it was.
        #expect(kc.attributes(service: service, account: "openai.api_key")?[kSecAttrGeneric] as? Data == KeychainStore.MARKER)
        #expect(kc.value(service: service, account: "openai.api_key") == "sk-proj-from-python-0123")
        #expect(kc.attributes(service: python, account: "openai.api_key")?[kSecAttrGeneric] == nil)
        #expect(kc.value(service: python, account: "openai.api_key") == "sk-proj-from-python-0123")
        // From now on the copy is read first: the old item is not read again (a later change there is not seen).
        #expect(SecItemUpdate([kSecClass: kSecClassGenericPassword, kSecAttrService: python, kSecAttrAccount: "openai.api_key",
                               kSecMatchSearchList: [kc.keychain] as CFArray] as CFDictionary,
                              [kSecValueData: Data("sk-proj-changed-by-python".utf8)] as CFDictionary) == errSecSuccess)
        #expect(try kc.store(service: service, legacy: [python]).read("openai.api_key") == "sk-proj-from-python-0123")
    }

    @Test func aWriteGoesToTheNewItemAndLeavesThePythonOne() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "NOTION_TOKEN", value: "secret_from_python") == errSecSuccess)
        let keys = kc.store(service: service, legacy: [python])
        try keys.write("NOTION_TOKEN", "secret_set_in_settings")
        #expect(try keys.read("NOTION_TOKEN") == "secret_set_in_settings")
        #expect(kc.attributes(service: service, account: "NOTION_TOKEN")?[kSecAttrGeneric] as? Data == KeychainStore.MARKER)
        // The Python item stays (the developer fallback reads it) with the new value: updated, not replaced.
        #expect(kc.value(service: python, account: "NOTION_TOKEN") == "secret_set_in_settings")
        #expect(kc.attributes(service: python, account: "NOTION_TOKEN")?[kSecAttrGeneric] == nil)
    }

    @Test func aPythonItemThatCantBeUpdatedQuietlyKeepsItsValueAndTheWriteStillWorks() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "NOTION_TOKEN", value: "secret_from_python") == errSecSuccess)
        let logged = Lines()
        let keys = kc.store(service: service, legacy: [python])
        keys.updateQuietly = { _, _ in errSecInteractionNotAllowed }
        keys.log = { logged.add($0) }
        try keys.write("NOTION_TOKEN", "secret_set_in_settings")
        #expect(try keys.read("NOTION_TOKEN") == "secret_set_in_settings")
        #expect(kc.value(service: python, account: "NOTION_TOKEN") == "secret_from_python")
        #expect(logged.all.count == 1 && logged.all[0].contains("NOTION_TOKEN") && !logged.all[0].contains("secret_"))
    }

    @Test func aWriteMakesNoPythonItem() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        try kc.store(service: service, legacy: [python]).write("NOTION_TOKEN", "secret_set_in_settings")
        #expect(kc.attributes(service: python, account: "NOTION_TOKEN") == nil)
    }

    @Test func aRemovedKeyStaysRemovedWhileThePythonItemIsThere() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "openai.api_key", value: "sk-proj-from-python-0123") == errSecSuccess)
        let keys = kc.store(service: service, legacy: [python])
        #expect(try keys.read("openai.api_key") == "sk-proj-from-python-0123")
        try keys.delete("openai.api_key")
        #expect(!keys.has("openai.api_key"))
        #expect(try keys.read("openai.api_key") == nil)  // not copied back
        #expect(try kc.store(service: service, legacy: [python]).read("openai.api_key") == nil)
        #expect(kc.value(service: python, account: "openai.api_key") == "sk-proj-from-python-0123")  // never deleted
        try keys.delete("openai.api_key")  // again: no error
        try keys.write("openai.api_key", "sk-proj-new-0456")
        #expect(keys.has("openai.api_key"))
        #expect(try keys.read("openai.api_key") == "sk-proj-new-0456")
        // Without an old item, a delete leaves nothing behind.
        try keys.delete("openai.api_key")
        try keys.write("anthropic.api_key", KEY)
        try keys.delete("anthropic.api_key")
        #expect(kc.attributes(service: service, account: "anthropic.api_key") == nil)
    }

    @Test func noCopyWithoutTheAccessListAndTheFailureIsLoggedOnce() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "openai.api_key", value: "sk-proj-from-python-0123") == errSecSuccess)
        let logged = Lines()
        let keys = kc.store(service: service, legacy: [python])
        keys.makeAccess = { _, _ in nil }  // the list can't be made
        keys.log = { logged.add($0) }
        for _ in 0..<3 { #expect(try keys.read("openai.api_key") == "sk-proj-from-python-0123") }
        #expect(kc.attributes(service: service, account: "openai.api_key") == nil)  // no copy that trusts only this program
        #expect(logged.all.count == 1 && logged.all[0].contains("openai.api_key") && !logged.all[0].contains("sk-proj"))
        // The next program that can make the list copies it.
        #expect(try kc.store(service: service, legacy: [python]).read("openai.api_key") == "sk-proj-from-python-0123")
        #expect(kc.attributes(service: service, account: "openai.api_key")?[kSecAttrGeneric] as? Data == KeychainStore.MARKER)
    }

    @Test func anotherProgramCopyingAtTheSameMomentIsFine() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: python, account: "openai.api_key", value: "sk-proj-from-python-0123") == errSecSuccess)
        let logged = Lines()
        let keys = kc.store(service: service, legacy: [python])
        keys.secAdd = { item in _ = SecItemAdd(item, nil); return errSecDuplicateItem }  // the other one was first
        keys.log = { logged.add($0) }
        #expect(try keys.read("openai.api_key") == "sk-proj-from-python-0123")
        #expect(logged.all.isEmpty)
    }

    @Test func aWriteWithoutTheAccessListStillKeepsTheKey() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)"
        let keys = kc.store(service: service)
        keys.makeAccess = { _, _ in nil }
        try keys.write("anthropic.api_key", KEY)
        #expect(try keys.read("anthropic.api_key") == KEY)
        #expect(kc.attributes(service: service, account: "anthropic.api_key")?[kSecAttrGeneric] == nil)
    }

    @Test func tokensUnderTheOldNameAreFoundAfterThePythonService() throws {
        let kc = try TestKeychain()
        let service = "palaver-test-\(UUID().uuidString)", python = "palaver-py-test-\(UUID().uuidString)",
            old = "meeting-transcribe-test-\(UUID().uuidString)"
        #expect(kc.addAsPython(service: old, account: "NOTION_TOKEN", value: "secret_old_notion") == errSecSuccess)
        #expect(kc.store(service: service, legacy: [python, old]).has("NOTION_TOKEN"))
        #expect(kc.addAsPython(service: python, account: "NOTION_TOKEN", value: "secret_python_notion") == errSecSuccess)
        #expect(try kc.store(service: service, legacy: [python, old]).read("NOTION_TOKEN") == "secret_python_notion")
        #expect(kc.value(service: service, account: "NOTION_TOKEN") == "secret_python_notion")
    }

    @Test func theDefaultsAreTheNewServiceThenThePythonOnes() {
        #expect(KeychainStore.SERVICE == "palaver.v2")
        let store = KeychainStore(keychain: nil, trusted: [])
        #expect(store.service == "palaver.v2" && store.legacyServices == ["palaver", "meeting-transcribe"])
    }

    @Test func theAccessListTrustsTheGivenExecutables() throws {
        let access = palaver_access_trusting(["/usr/bin/true", "/nothing/here"] as CFArray, "Palaver: test" as CFString)
        #expect(access != nil)  // a path that can't be read is skipped, not a failure
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Who a key is shared with: every Palaver program of the same app or build folder, the `palaver` command (MCP)
/// included, whichever of them is writing.
@Suite struct TrustedProgramsTests {
    static let APP = "/Applications/Palaver.app"
    static let ALL = ["Contents/MacOS/Palaver", "Contents/MacOS/palaver-server", "Contents/MacOS/palaver-worker",
                      "Contents/MacOS/palaver-lm", "Contents/Resources/bin/palaver"].map { "\(APP)/\($0)" }

    @Test func theServerSharesWithTheAppTheWorkerAndThePalaverCommand() {
        let trusted = KeychainStore.palaverExecutables(running: URL(fileURLWithPath: "\(Self.APP)/Contents/MacOS/palaver-server"),
                                                       isExecutable: { Self.ALL.contains($0) })
        #expect(trusted == Self.ALL.filter { !$0.hasSuffix("/palaver-server") })
    }

    @Test func thePalaverCommandInResourcesSharesWithTheProgramsInMacOS() {
        let trusted = KeychainStore.palaverExecutables(running: URL(fileURLWithPath: "\(Self.APP)/Contents/Resources/bin/palaver"),
                                                       isExecutable: { Self.ALL.contains($0) })
        #expect(trusted == Self.ALL.filter { !$0.hasSuffix("/bin/palaver") })
    }

    @Test func aBuildFolderSharesWithPalaverCliAndNeverNamesTheAppTwice() {
        let build = "/src/native/.build/release"
        let there = ["Palaver", "palaver-server", "palaver-worker", "palaver-cli"].map { "\(build)/\($0)" }
        // A case-insensitive disk: `palaver` would be the app again.
        let trusted = KeychainStore.palaverExecutables(running: URL(fileURLWithPath: "\(build)/palaver-server"),
                                                       isExecutable: { p in there.contains { $0.lowercased() == p.lowercased() } })
        #expect(trusted == ["\(build)/Palaver", "\(build)/palaver-worker", "\(build)/palaver-cli"])
    }
}

@Suite struct TokensTests {
    @Test func theEnvironmentThenConfigTomlThenTheKeychain() throws {
        let home = Home()
        let toml = home.dir.appendingPathComponent("config.toml")
        let keys = CountingKeyStore(["NOTION_TOKEN": "from-keychain", "HF_TOKEN": "hf-from-keychain"])
        #expect(Tokens.value(Tokens.NOTION, configToml: toml, env: [:], keys: keys) == "from-keychain")
        try "[notion]\ntoken = \"from-toml\"\n[hf]\ntoken = \"hf-from-toml\"\n".write(to: toml, atomically: true, encoding: .utf8)
        #expect(Tokens.value(Tokens.NOTION, configToml: toml, env: [:], keys: keys) == "from-toml")
        #expect(Tokens.value(Tokens.HF, configToml: toml, env: [:], keys: keys) == "hf-from-toml")
        #expect(Tokens.value(Tokens.NOTION, configToml: toml, env: ["NOTION_TOKEN": "from-env"], keys: keys) == "from-env")
        #expect(keys.reads == ["NOTION_TOKEN"])  // the Keychain only when nothing else has it
    }

    @Test func presenceNeverReadsASecret() throws {
        let home = Home()
        let toml = home.dir.appendingPathComponent("config.toml")
        let keys = CountingKeyStore(["NOTION_TOKEN": "from-keychain"])
        #expect(Tokens.present(Tokens.NOTION, configToml: toml, env: [:], keys: keys))
        #expect(!Tokens.present(Tokens.HF, configToml: toml, env: [:], keys: keys))
        #expect(Tokens.present(Tokens.HF, configToml: toml, env: ["HF_TOKEN": "x"], keys: keys))
        #expect(keys.reads.isEmpty)
    }

    @Test func notionAutoSyncNeedsATokenAndItsSwitch() throws {
        let home = Home()
        let toml = home.dir.appendingPathComponent("config.toml")
        let none = CountingKeyStore()
        #expect(Tokens.notionAutoSync(config: Config(), configToml: toml, env: [:], keys: none) == (false, true))
        let kept = CountingKeyStore(["NOTION_TOKEN": "t"])
        #expect(Tokens.notionAutoSync(config: Config(), configToml: toml, env: [:], keys: kept) == (true, true))
        let off = Config(toml: "[notion]\nauto_sync = false\n[notes]\nenabled = false\n")
        #expect(Tokens.notionAutoSync(config: off, configToml: toml, env: [:], keys: kept) == (false, false))
        #expect(kept.reads.isEmpty)
    }
}
