import Foundation

public enum ShellError: LocalizedError, Sendable {
    case nonZero(command: String, code: Int32, output: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .nonZero(let command, let code, let output):
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.isEmpty { return "\(command) exited \(code)" }
            return tail
        case .cancelled:
            return "Cancelled"
        }
    }
}

enum Shell {
    static let extraPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func resolve(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        for dir in extraPath {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return name
    }

    static func run(_ launchPath: String, _ args: [String], admin: Bool = false) throws -> String {
        if admin {
            return try runAdmin(launchPath, args)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolve(launchPath))
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let path = (env["PATH"] ?? "")
        env["PATH"] = (extraPath + [path]).joined(separator: ":")
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        let combined = (stdout + stderr)
        if process.terminationStatus != 0 {
            throw ShellError.nonZero(
                command: ([launchPath] + args).joined(separator: " "),
                code: process.terminationStatus,
                output: combined
            )
        }
        return combined
    }

    static func runAdmin(_ launchPath: String, _ args: [String]) throws -> String {
        let tokens = ([resolve(launchPath)] + args).map(quotePOSIX).joined(separator: " ")
        // osascript needs backslash-escaped double quotes inside the AppleScript string.
        let escaped = tokens
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        do {
            return try run("/usr/bin/osascript", ["-e", script])
        } catch let ShellError.nonZero(_, code, output) {
            if output.localizedCaseInsensitiveContains("canceled")
                || output.localizedCaseInsensitiveContains("cancelled")
                || code == -128
            {
                throw ShellError.cancelled
            }
            throw ShellError.nonZero(command: tokens, code: code, output: output)
        }
    }

    private static func quotePOSIX(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"$`\\!*?[]{}();&|<>")) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
