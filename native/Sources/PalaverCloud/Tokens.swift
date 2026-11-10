// The Notion and Hugging Face tokens (config.py `_token`): the environment, then config.toml ([notion].token,
// [hf].token), then the Keychain (account NOTION_TOKEN / HF_TOKEN under "palaver", then under the app's old name
// "meeting-transcribe") — apps started from Finder or at login don't see the shell's environment. A token is never
// logged or shown; `present` only says whether there is one and never reads a secret from the Keychain.
import Foundation
import PalaverCore
import PalaverDomain

public enum Tokens {
    public static let NOTION = "NOTION_TOKEN"
    public static let HF = "HF_TOKEN"

    /// The config.toml key each token is set under.
    static func tomlKey(_ name: String) -> String? {
        switch name {
        case NOTION: return "notion.token"
        case HF: return "hf.token"
        default: return nil
        }
    }

    /// The token written in config.toml at `configToml`, nil when there is none.
    static func configured(_ name: String, configToml: URL) -> String? {
        guard let key = tomlKey(name), let data = try? Data(contentsOf: configToml),
              case .string(let s)? = Toml.parse(String(decoding: data, as: UTF8.self))[key], !s.isEmpty else { return nil }
        return s
    }

    /// The token itself, for the request only: the environment, config.toml, then the Keychain (a read there may ask).
    public static func value(_ name: String, configToml: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                             keys: KeyStore) -> String? {
        if let v = env[name], !v.isEmpty { return v }
        if let v = configured(name, configToml: configToml) { return v }
        return (try? keys.read(name)) ?? nil
    }

    /// The Hugging Face token for a model download: `value(HF)`, else the one `huggingface-cli login` saved
    /// (`$HF_TOKEN_PATH`, else `$HF_HOME/token`, else `~/.cache/huggingface/token`), which huggingface_hub used when
    /// Palaver gave it none. Asked only when a download starts (a Keychain read may ask the user).
    public static func huggingFace(configToml: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                                   keys: KeyStore, home: URL) -> String? {
        if let v = value(HF, configToml: configToml, env: env, keys: keys) { return v }
        let file: URL
        if let p = env["HF_TOKEN_PATH"], !p.isEmpty {
            file = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else if let h = env["HF_HOME"], !h.isEmpty {
            file = URL(fileURLWithPath: (h as NSString).expandingTildeInPath).appendingPathComponent("token")
        } else {
            file = home.appendingPathComponent(".cache/huggingface/token")
        }
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Whether there is a token: the same places, the Keychain by its attributes only (never a prompt).
    public static func present(_ name: String, configToml: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                               keys: KeyStore) -> Bool {
        if let v = env[name], !v.isEmpty { return true }
        if configured(name, configToml: configToml) != nil { return true }
        return keys.has(name)
    }

    /// `notion-auto-sync` (app_query): a recording is uploaded after the call (`run`) when there is a Notion token and
    /// `[notion].auto_sync` (default true) says so; `notes`: `[notes].enabled`.
    public static func notionAutoSync(config: Config, configToml: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                                      keys: KeyStore) -> (autoSync: Bool, notes: Bool) {
        let token = config.hasNotionToken || present(NOTION, configToml: configToml, env: env, keys: keys)
        return (token && config.notionAutoSyncSetting, config.notesEnabled)
    }
}
