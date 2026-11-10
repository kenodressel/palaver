// The `palaver` command's arguments, as cli.py's argparse took them: global options before the command, then the
// command's positionals and options in any order (`--x VALUE`, `--x=VALUE`, `-o VALUE`, `--` ends the options).
// A usage error says what is wrong on stderr with the usage line and exits 2; `-h`/`--help` prints the help, exit 0.
import Foundation

/// One command's positional argument.
struct CLIArg {
    enum Count { case one, optional, many }
    let name: String
    let help: String
    var count: Count = .one
    var choices: [String]? = nil
}

/// One command's option: a flag (`value` nil) or one that takes a value (`value` is its placeholder).
struct CLIOpt {
    let names: [String]
    var value: String? = nil
    let help: String
    /// `--x` / `--no-x` (argparse's BooleanOptionalAction).
    var negatable = false

    /// The long name a parse keys it by.
    var key: String { names.last! }
}

/// A command as `palaver --help` lists it and its own `--help` describes it.
struct CLISpec {
    let name: String
    let summary: String
    var args: [CLIArg] = []
    var opts: [CLIOpt] = []
    /// More said under the usage of `palaver <name> --help`.
    var description: String? = nil

    var usage: String {
        var parts = ["usage: palaver", name]
        for o in opts {
            let shown = o.negatable ? "\(o.key) | --no-\(o.key.dropFirst(2))" : o.names[0] + (o.value.map { " \($0)" } ?? "")
            parts.append("[\(shown)]")
        }
        for a in args {
            let n = a.choices.map { "{\($0.joined(separator: ","))}" } ?? a.name
            switch a.count {
            case .one: parts.append(n)
            case .optional: parts.append("[\(n)]")
            case .many: parts.append("[\(n) …]")
            }
        }
        return parts.joined(separator: " ")
    }

    var help: String {
        var lines = [usage, "", summary + "."]
        if let description { lines += ["", description] }
        if !args.isEmpty {
            lines += ["", "arguments:"]
            let width = args.map { $0.name.count }.max()!
            for a in args { lines.append("  " + a.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + a.help) }
        }
        lines += ["", "options:"]
        let shown = [("-h, --help", "show this help and exit")] + opts.map { o in
            (o.negatable ? "\(o.key), --no-\(o.key.dropFirst(2))" : o.names.joined(separator: ", ") + (o.value.map { " \($0)" } ?? ""), o.help)
        }
        let width = shown.map { $0.0.count }.max()!
        for (left, text) in shown { lines.append("  " + left.padding(toLength: width + 2, withPad: " ", startingAt: 0) + text) }
        return lines.joined(separator: "\n")
    }
}

/// What a command was given.
struct CLIParsed {
    var positional: [String: [String]] = [:]
    var flags: Set<String> = []
    var values: [String: String] = [:]
    /// `--x` / `--no-x`: the last one given, nil for neither.
    var toggles: [String: Bool] = [:]

    func one(_ name: String) -> String? { positional[name]?.first }
    func all(_ name: String) -> [String] { positional[name] ?? [] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
    func value(_ key: String) -> String? { values[key] }
}

/// A usage error: its message after "palaver <command>: error: ".
struct CLIUsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `-h`/`--help` among a command's arguments.
struct CLIHelpAsked: Error {}

extension CLISpec {
    /// The command's arguments (everything after its name) by this spec.
    func parse(_ args: [String]) throws -> CLIParsed {
        var parsed = CLIParsed()
        var operands: [String] = []
        var i = 0
        var optionsEnded = false
        while i < args.count {
            let a = args[i]
            i += 1
            if optionsEnded || !a.hasPrefix("-") || a == "-" || Double(a) != nil {
                operands.append(a)
                continue
            }
            if a == "--" { optionsEnded = true; continue }
            if a == "-h" || a == "--help" { throw CLIHelpAsked() }
            let (flag, inline): (String, String?) = {
                guard a.hasPrefix("--"), let eq = a.firstIndex(of: "=") else { return (a, nil) }
                return (String(a[..<eq]), String(a[a.index(after: eq)...]))
            }()
            if let o = opts.first(where: { $0.negatable && "--no-\($0.key.dropFirst(2))" == flag }) {
                guard inline == nil else { throw CLIUsageError("argument \(flag): ignored explicit argument '\(inline!)'") }
                parsed.toggles[o.key] = false
                continue
            }
            guard let o = opts.first(where: { $0.names.contains(flag) }) else {
                throw CLIUsageError("unrecognized arguments: \(a)")
            }
            let label = o.names.joined(separator: "/")
            if o.value == nil {
                guard inline == nil else { throw CLIUsageError("argument \(label): ignored explicit argument '\(inline!)'") }
                if o.negatable { parsed.toggles[o.key] = true } else { parsed.flags.insert(o.key) }
                continue
            }
            if let inline { parsed.values[o.key] = inline; continue }
            guard i < args.count, !(args[i].hasPrefix("-") && args[i] != "-" && Double(args[i]) == nil) else {
                throw CLIUsageError("argument \(label): expected one argument")
            }
            parsed.values[o.key] = args[i]
            i += 1
        }
        var rest = operands[...]
        var missing: [String] = []
        for (n, a) in self.args.enumerated() {
            switch a.count {
            case .one:
                if let v = rest.popFirst() { parsed.positional[a.name] = [v] } else { missing.append(a.name) }
            case .optional:
                // Leave enough for the required ones after it.
                let needed = self.args[(n + 1)...].filter { $0.count == .one }.count
                if rest.count > needed, let v = rest.popFirst() { parsed.positional[a.name] = [v] }
            case .many:
                let needed = self.args[(n + 1)...].filter { $0.count == .one }.count
                parsed.positional[a.name] = Array(rest.prefix(max(0, rest.count - needed)))
                rest = rest.dropFirst(max(0, rest.count - needed))
            }
            if let choices = a.choices {
                for v in parsed.positional[a.name] ?? [] where !choices.contains(v) {
                    throw CLIUsageError("argument \(a.name): invalid choice: '\(v)' (choose from "
                                        + choices.map { "'\($0)'" }.joined(separator: ", ") + ")")
                }
            }
        }
        if !missing.isEmpty { throw CLIUsageError("the following arguments are required: \(missing.joined(separator: ", "))") }
        if !rest.isEmpty { throw CLIUsageError("unrecognized arguments: \(rest.joined(separator: " "))") }
        return parsed
    }
}
