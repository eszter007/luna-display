import Foundation
import os

private let lunaOSLog = OSLog(subsystem: "local.luna", category: "luna")
private let stderrFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// Project-wide logging (`NSLog` drop-in: printf-style format + arguments).
///
/// Goes to the unified log as **public** text — NSLog bodies are persisted as
/// `<private>` and never show up in `log show`, which made the sender and the
/// camera extension impossible to debug from outside — and to stderr for
/// headless runs and the test harnesses. Read it with:
///
///     /usr/bin/log show --last 10m --info --predicate 'subsystem == "local.luna"' --style compact
public func lunaLog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    os_log("%{public}@", log: lunaOSLog, type: .default, message)
    let line = "\(stderrFormatter.string(from: Date())) \(ProcessInfo.processInfo.processName)[\(getpid())] \(message)\n"
    if let data = line.data(using: .utf8) { FileHandle.standardError.write(data) }
}
