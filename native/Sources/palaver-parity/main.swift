// Test-only: one parity op on one side, for tools/parity/run.py (tests/test_parity.py).
//   palaver-parity <op> --side <dir> [--args <json>]
// Prints the op's answer as one JSON line and exits 0; on a failure {"error": message, "kind":
// kind} and exit 1. Kinds: unknown_op and bad_args (the harness's), or the error's ParityErrorKind.
// It runs only on a parity side (SideGuard): XDG_CONFIG_HOME and PALAVER_HOME are the side's config/ and home/, the
// side has its config.toml and config.toml's output_dir is inside the side; otherwise it answers bad_args before the
// op runs (and before anything is read, but for the side's own config.toml, settings.json and events.json).
import Foundation
import PalaverCore
import PalaverDomain

func fail(_ message: String, kind: String) -> Never {
    print(PythonJSON.dumps(.object([("error", .string(message)), ("kind", .string(kind))])))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
if let why = SideGuard.environmentProblem(env) { fail(why, kind: "bad_args") }

let argv = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

guard let op = argv.first, !op.hasPrefix("-") else { fail("usage: palaver-parity <op> --side <dir> [--args <json>]", kind: "bad_args") }
guard let sidePath = option("--side") else { fail("--side <dir> is missing", kind: "bad_args") }
if let why = SideGuard.sideProblem(sidePath, env) { fail(why, kind: "bad_args") }
let side = ParitySide.load(root: URL(fileURLWithPath: sidePath, isDirectory: true), env: env)
if let why = SideGuard.recordingsProblem(side.recordings, side: sidePath) { fail(why, kind: "bad_args") }
guard let run = ParityOps.table[op] else { fail("unknown op \(op)", kind: "unknown_op") }
var args = JSONValue.object([])
if let text = option("--args") {
    do { args = try PythonJSON.parse(Data(text.utf8)) } catch { fail("--args is no JSON: \(error)", kind: "bad_args") }
}
do {
    print(PythonJSON.dumps(try run(side, args)))
} catch {
    fail("\(error)", kind: (error as? ParityErrorKind)?.parityKind ?? "other")
}
