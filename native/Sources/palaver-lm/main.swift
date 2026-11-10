// `palaver-lm`: the language model's worker (notes, projects, the best next question). See PalaverLM/Command.swift; the
// local model runs through MLX (PalaverMLX/LocalRunner.swift).
import Darwin
import PalaverCore
import PalaverLM
import PalaverMLX

setvbuf(stdout, nil, _IOLBF, 0)  // its lines reach the job's log as they are written
// A helper that quits without reading (the Claude Code CLI) is an error to report, not death by SIGPIPE.
signal(SIGPIPE, SIG_IGN)
// A SIGTERM or SIGINT to palaver-lm alone (not its group) still ends the helpers it started.
LiveHelpers.forwardTerminationSignals()
exit(await LMMain.run(Array(CommandLine.arguments.dropFirst()), local: { MLXLocal.factory(stores: $0, notesGB: $1.memory["notes_gb"]) }))
