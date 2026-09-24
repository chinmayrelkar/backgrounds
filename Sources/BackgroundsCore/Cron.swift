import Foundation

public struct CronEntry: Identifiable, Hashable, Sendable {
    /// Line number in the crontab; stable until the crontab is edited.
    public var id: Int { line }
    public var line: Int
    public var schedule: String
    public var command: String
    public var enabled: Bool
    public var raw: String
}

public enum Cron {
    public static func list() throws -> [CronEntry] {
        parse(try readRaw())
    }

    /// `crontab -l` exits 1 when there is no crontab. That is an empty list, not an error.
    static func readRaw() throws -> String {
        let result = try Shell.exec("/usr/bin/crontab", ["-l"], allowFailure: true)
        if result.code == 0 { return result.stdout }
        if result.stderr.contains("no crontab") { return "" }
        throw ShellError.nonZero(command: "crontab -l", code: result.code, output: result.combined)
    }

    static func parse(_ raw: String) -> [CronEntry] {
        var entries: [CronEntry] = []
        for (index, text) in raw.components(separatedBy: "\n").enumerated() {
            var body = text.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            var enabled = true
            if body.hasPrefix("#") {
                // Only treat comments that look like a disabled job as entries.
                let uncommented = body.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard looksLikeJob(uncommented) else { continue }
                body = uncommented
                enabled = false
            }
            if isEnvLine(body) { continue }
            guard let (schedule, command) = split(body) else { continue }
            entries.append(CronEntry(line: index, schedule: schedule, command: command, enabled: enabled, raw: text))
        }
        return entries
    }

    public static func remove(_ entry: CronEntry) throws {
        try rewrite { lines in lines.remove(at: entry.line) }
    }

    public static func setEnabled(_ entry: CronEntry, _ enabled: Bool) throws {
        try rewrite { lines in
            let body = entry.schedule + " " + entry.command
            lines[entry.line] = enabled ? body : "# " + body
        }
    }

    static func rewrite(_ change: (inout [String]) -> Void) throws {
        var lines = try readRaw().components(separatedBy: "\n")
        change(&lines)
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        _ = try Shell.run("/usr/bin/crontab", ["-"], input: text)
    }

    static func split(_ body: String) -> (String, String)? {
        let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        if first.hasPrefix("@") {
            guard parts.count >= 2 else { return nil }
            return (first, parts.dropFirst().joined(separator: " "))
        }
        guard parts.count >= 6 else { return nil }
        return (parts.prefix(5).joined(separator: " "), parts.dropFirst(5).joined(separator: " "))
    }

    static func looksLikeJob(_ body: String) -> Bool {
        guard let (schedule, _) = split(body) else { return false }
        if schedule.hasPrefix("@") { return true }
        // Minute and hour fields are numeric in a real job; prose comments fail here.
        let numeric = CharacterSet(charactersIn: "0123456789*/,-")
        let named = numeric.union(.letters)
        let fields = schedule.split(separator: " ")
        return fields.enumerated().allSatisfy { index, field in
            field.unicodeScalars.allSatisfy((index < 2 ? numeric : named).contains)
        }
    }

    private static func isEnvLine(_ body: String) -> Bool {
        guard let eq = body.firstIndex(of: "=") else { return false }
        return !body[..<eq].contains(" ")
    }
}
