import Foundation
import WorkbenchCore

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--version", "version":
    print("workbench \(Workbench.version)")
case nil, "--help", "help":
    print("""
    usage: workbench <command>

    commands:
      version    print the version
    """)
default:
    FileHandle.standardError.write(Data("workbench: unknown command '\(arguments[0])'\n".utf8))
    exit(2)
}
