// The provider actions the window's routes ask (palaver/provider_helper.py's actions): the language model's and
// transcription's settings, their API keys and Test buttons, and the providers' readiness for the setup assistant.
// `Providers` answers all of them in this process (PalaverCloud: the Keychain, settings.json, the HTTP transport, the
// transcription services); none goes to Python. Adding Palaver to Claude is McpAPI.install (McpSetup).
//
// A key is held only for the call (no copy kept, never logged), and no error text that comes back holds it.
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

/// The provider actions in this process: what api.py's language_model … set_transcription_key and llm.test answer.
public final class Providers: ProviderHelper, @unchecked Sendable {
    /// The budget of a settings call.
    public static let TIMEOUT = 120.0
    /// The budget of a Test button: the provider's own request may take ten minutes.
    public static let TEST_TIMEOUT = 650.0
    static func TOO_LONG(_ seconds: Double) -> String { "The test took longer than \(Int(seconds)) seconds; it was stopped." }

    let configURL: URL
    let stores: StorePaths
    let keys: KeyStore
    let env: [String: String]
    let http: HTTPClient

    /// `configURL`: config.toml, read again for each call (an edit shows without a restart).
    public init(configURL: URL, stores: StorePaths, keys: KeyStore, env: [String: String] = ProcessInfo.processInfo.environment,
                http: HTTPClient = HTTPClient()) {
        self.configURL = configURL
        self.stores = stores
        self.keys = keys
        self.env = env
        self.http = http
    }

    func settings() -> ProviderSettings {
        ProviderSettings(config: Config.load(configURL, environment: env), stores: stores, keys: keys, env: env)
    }

    public func call(_ action: String, body: JSONValue, timeout: Double) throws -> JSONValue {
        do {
            return try answer(action, body, timeout: timeout)
        } catch {
            throw Self.answered(error, action: action, body: body, timeout: timeout)
        }
    }

    /// What the page gets for `error`: a refused setting 400, a provider's failure 502, never the key given. Anything
    /// else a Test button met (a sound file that can't be made, a transport error) is the tested service's failure
    /// too (502 with why, not the server's 500); elsewhere it stays the server's.
    static func answered(_ error: Error, action: String, body: JSONValue, timeout: Double) -> Error {
        switch error {
        case is TimedOut: return BadGateway(TOO_LONG(timeout))
        case let e as SettingRefused: return Refused(withoutKey(e.text, body: body))
        case let e as EngineUnavailable: return BadGateway(withoutKey(e.message, body: body))
        case let e as CloudError: return BadGateway(withoutKey(e.message, body: body))
        case let e as JobFailed: return BadGateway(withoutKey(e.description, body: body))
        case let e as ContextTooLong: return BadGateway(e.message)
        case is BadRequest, is Refused, is BadGateway: return error
        default:
            guard TEST_ACTIONS.contains(action) else { return error }
            return BadGateway(withoutKey(HTTPClient.redactedDescription(error, key: nil), body: body))
        }
    }

    /// The Test buttons' actions: whatever fails there is the tested service's failure.
    static let TEST_ACTIONS: Set<String> = ["test", "test-transcription"]

    /// `text` with the key that was given left out (the messages leave it out already: never shown, whatever failed).
    static func withoutKey(_ text: String, body: JSONValue) -> String {
        guard case .string(let key)? = body["key"] else { return text }
        var out = text
        for given in [key, Py.strip(key)] where !given.isEmpty {
            out = out.replacingOccurrences(of: given, with: "…", options: .literal)
        }
        return out
    }

    /// `timeout` bounds the Test buttons (TEST_TIMEOUT from the route): a provider that keeps a request open, or keeps
    /// answering 429, can't hold the page longer.
    func answer(_ action: String, _ body: JSONValue, timeout: Double) throws -> JSONValue {
        guard case .object = body else { throw BadRequest("the request must be a JSON object") }
        let s = settings()
        switch action {
        case "language-model": return try ProvidersAPI.languageModel(s)
        case "set-language-model": return try ProvidersAPI.setLanguageModel(s, body)
        case "set-key":
            try ProvidersAPI.setKey(s, body, transcriptionOnly: false)
            return try ProvidersAPI.languageModel(s)
        case "test":
            let pid = body["provider"].map(Py.str) ?? "None"
            let http = self.http
            return try runBlocking(timeout: timeout) { try await ProviderTest.run(pid, settings: s, http: http) }
        case "transcription": return try ProvidersAPI.transcription(s)
        case "set-transcription": return try ProvidersAPI.setTranscription(s, body)
        case "set-transcription-key":
            try ProvidersAPI.setKey(s, body, transcriptionOnly: true)
            return try ProvidersAPI.transcription(s)
        case "test-transcription":
            let pid = body["provider"].map(Py.str) ?? "None"
            let http = self.http
            return try runBlocking(timeout: timeout) { try await CloudTranscription.test(pid, settings: s, http: http) }
        case "registry": return try s.registry()
        default: throw BadRequest("no action \(Py.repr(.string(action)))")
        }
    }
}
