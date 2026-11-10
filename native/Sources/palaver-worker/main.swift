// The pipeline's worker (phase 3): the Swift port of `palaver process|run|live|stream|coach|index`,
// `calendar attach` and `app query` (WorkerMain).
import Foundation
import PalaverWorker

setvbuf(stdout, nil, _IOLBF, 0)
exit(await WorkerMain.run(Array(CommandLine.arguments.dropFirst())))
