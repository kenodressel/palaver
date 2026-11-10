// `palaver-worker run <folder>` (cli.py `_cmd_run`, Notion auto-sync): the pipeline, then the notes (Python's
// `palaver notes`: the language model and the projects it sorts the meeting into, one model load), then the upload to
// Notion (cli.py `_cmd_sync`, in this process: PalaverCloud's NotionSync). A failed notes run is logged and the upload
// goes on; a failed upload fails the command (no notion.json: the app tries the meeting again).
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum Run {
    public static func run(_ folder: URL, _ setup: Pipeline.Setup) async throws -> Int32 {
        let rc = try await Pipeline.process(folder, setup, notes: false, runMode: true)
        if rc != 0 { return rc }
        let paths = RecordingPaths(folder)
        if setup.config.notesEnabled {
            let log = SessionLog(url: paths.sessionLog, logger: "palaver")
            let utterances = (try? Pipeline.readList(paths.transcriptJson).map { try Utterance(json: $0) }) ?? []
            Pipeline.writeNotes(paths, utterances, setup, log: log)
        }
        return try await sync(paths, setup)
    }

    /// `_cmd_sync`: the transcript to Notion as config.toml says (page or database), the token from the environment,
    /// config.toml or the Keychain; then notion.json, `notion_upload_start/_done` in session.log and the "Uploaded to
    /// Notion" notification.
    public static func sync(_ paths: RecordingPaths, _ setup: Pipeline.Setup) async throws -> Int32 {
        let log = SessionLog(url: paths.sessionLog, logger: "palaver")
        do {
            let plan = try NotionSync.plan(paths, glossary: Glossary.current(stores: setup.stores))
            guard let token = Tokens.value(Tokens.NOTION, configToml: setup.cloud.configToml, env: setup.cloud.env,
                                           keys: setup.cloud.keys) else {
                throw NotionError("no Notion token: set [notion].token in config.toml or add it in Settings")
            }
            setup.say("Uploading to Notion (\(plan.blocks.count) blocks)…")
            let url = try await Stage.with("notion_upload", log: log, fields: [("blocks", .int(plan.blocks.count))]) { info in
                let url = try await NotionSync.upload(plan, config: setup.config, token: token,
                                                      client: NotionClient(token: token, http: setup.cloud.http))
                info["page_url"] = .string(url)
                return url
            }
            try NotionSync.writeInfo(paths, url: url)
            setup.say("✓ \(url)")
            Notify.send(title: "Uploaded to Notion", message: url)
            return 0
        } catch {
            log.message("command failed: \(error)", level: "ERROR", logger: "palaver")
            throw error
        }
    }
}
