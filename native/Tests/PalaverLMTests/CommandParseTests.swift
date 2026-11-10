// palaver-lm's arguments as the `palaver` command forwards them (CLICommands.run: the global options first, then the
// command as the user gave it; CLIProcessTests checks that side) and as the server and the worker start it.
@testable import PalaverLM
import Testing

struct CommandParseTests {
    @Test func theCLIsNotesAndProjectsArgumentsParse() throws {
        let notes = try LMMain.parse(["--config", "/c/config.toml", "--dictionary", "/d.txt", "--no-notify", "notes", "/r/f", "--force"])
        #expect(notes.command == "notes" && notes.folder == "/r/f" && notes.force && notes.noNotify)
        #expect(notes.config == "/c/config.toml" && notes.dictionary == "/d.txt")
        let suggest = try LMMain.parse(["projects", "--no-wait", "suggest"])
        #expect(suggest.command == "projects" && suggest.action == "suggest" && suggest.target == nil && suggest.noWait)
        let describe = try LMMain.parse(["--no-notify", "projects", "describe", "contoso"])
        #expect(describe.action == "describe" && describe.target == "contoso" && !describe.noWait)
        let folder = try LMMain.parse(["projects", "suggest", "/r/f"])
        #expect(folder.target == "/r/f")
    }

    @Test func wrongArgumentsAreUsageErrors() {
        for args in [[], ["notes"], ["notes", "/a", "/b"], ["projects", "sort"], ["next-question", "/r/f", "--force"],
                     ["notes", "/r/f", "--no-wait"], ["record"]] {
            #expect(throws: LMMain.UsageError.self) { try LMMain.parse(args) }
        }
    }
}
