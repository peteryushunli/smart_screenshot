import Foundation
import SmartScreenshotCore

let status = await SmartScreenshotCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment
)
exit(status)
