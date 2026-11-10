// The `palaver` command (Palaver.app's Contents/Resources/bin/palaver, which install.sh links to ~/.local/bin/palaver;
// SwiftPM builds it as `palaver-cli`, since `Sources/palaver` and `Sources/Palaver`, the app, are one folder on a
// case-insensitive disk). The commands are CLIMain's (PalaverServer/CLI); `mcp` is McpMain.
import Darwin
import PalaverServer

setvbuf(stdout, nil, _IOLBF, 0)  // each line out as it is said, also into a pipe
exit(CLIMain.run(Array(CommandLine.arguments.dropFirst())))
