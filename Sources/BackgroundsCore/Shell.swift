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

public struct ShellResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int32

    public var combined: String { stdout + stderr }
}

enum Shell {
    static let extraPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/opt/orbstack/bin",
    ]

    static func resolve(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        for dir in extraPath {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return name
    }

    static func isInstalled(_ name: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: resolve(name))
    }

    /// Runs a command and returns stdout + stderr. Throws on a non-zero exit.
    static func run(_ launchPath: String, _ args: [String], admin: Bool = false, input: String? = nil) throws -> String {
        if admin {
            return try runAdmin(launchPath, args)
        }
        return try exec(launchPath, args, input: input).combined
    }

    /// Runs a command and returns stdout only, so stderr noise cannot break parsing.
    static func output(_ launchPath: String, _ args: [String], env extra: [String: String] = [:]) throws -> String {
        try exec(launchPath, args, env: extra).stdout
    }

    static func exec(
        _ launchPath: String,
        _ args: [String],
        input: String? = nil,
        env extra: [String: String] = [:],
        allowFailure: Bool = false
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolve(launchPath))
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let path = (env["PATH"] ?? "")
        env["PATH"] = (extraPath + [path]).joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Drain both pipes at once. Reading one to EOF first deadlocks when the other fills.
        let box = ErrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let result = ShellResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: box.data, encoding: .utf8) ?? "",
            code: process.terminationStatus
        )
        if result.code != 0 && !allowFailure {
            throw ShellError.nonZero(
                command: ([launchPath] + args).joined(separator: " "),
                code: result.code,
                output: result.combined
            )
        }
        return result
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

    static func quotePOSIX(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"$`\\!*?[]{}();&|<>")) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private final class ErrBox: @unchecked Sendable {
        var data = Data()
    }
}
