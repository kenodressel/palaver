// The Meetings window's server (phase 3): the Swift port of `palaver webapp-serve` (ServeMain).
import Foundation
import PalaverServer

exit(ServeMain.run(Array(CommandLine.arguments.dropFirst())))
