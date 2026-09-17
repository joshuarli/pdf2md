import Darwin
import PdfmdCore

let code = await runCLI(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
