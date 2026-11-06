import Foundation
import PalaverEngine

// stdout carries protocol lines only; logs go to stderr.
// `--version X` is the Palaver version, passed in by the Python caller.
var version = "dev"
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--version"), i + 1 < args.count { version = args[i + 1] }

// `--models DIR` is the FluidAudio model folder (default: Palaver's own).
var modelsDir = ModelStore.defaultDirectory
if let i = args.firstIndex(of: "--models"), i + 1 < args.count {
    modelsDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
}

await serve(input: FileHandle.standardInput, output: FileHandle.standardOutput,
            handler: engineHandler(version: version, modelsDir: modelsDir))
