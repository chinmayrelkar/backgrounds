import Darwin
import Foundation

public struct RunningItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var pid: Int
    public var extraPIDs: [Int]
    public var path: String
    public var command: String
    public var memoryBytes: UInt64
    public var kind: Kind

    public enum Kind: String, Sendable {
        case app
        case background
    }

    public init(
        id: String,
        name: String,
        pid: Int,
        extraPIDs: [Int],
        path: String,
        command: String,
        memoryBytes: UInt64,
        kind: Kind
    ) {
        self.id = id
        self.name = name
        self.pid = pid
        self.extraPIDs = extraPIDs
        self.path = path
        self.command = command
        self.memoryBytes = memoryBytes
        self.kind = kind
    }

    public var allPIDs: [Int] { [pid] + extraPIDs }

    public var memoryMB: Int { Int(memoryBytes / 1_048_576) }
}

public enum UserProcesses {
    public static func inventory() throws -> [RunningItem] {
        let raw = try Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,rss=,command="])
        let uid = Int(getuid())
        var rows: [Raw] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = Raw.parse(String(line)), parsed.uid == uid else { continue }
            if !isUserTriggered(parsed) { continue }
            rows.append(parsed)
        }
        return group(rows).sorted {
            if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func stop(_ item: RunningItem) throws {
        for pid in item.allPIDs {
            _ = kill(pid_t(pid), SIGTERM)
        }
    }

    public static func isUserTriggered(_ path: String, command: String) -> Bool {
        isUserTriggered(Raw(pid: 0, ppid: 0, uid: Int(getuid()), rssKB: 0, command: command, path: path))
    }

    private struct Raw {
        var pid: Int
        var ppid: Int
        var uid: Int
        var rssKB: UInt64
        var command: String
        var path: String

        var name: String { URL(fileURLWithPath: path).lastPathComponent }

        static func parse(_ line: String) -> Raw? {
            let parts = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 5,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let uid = Int(parts[2]),
                  let rss = UInt64(parts[3])
            else { return nil }
            let command = String(parts[4])
            let resolved = path(for: pid) ?? UserProcesses.executablePath(from: command)
            return Raw(pid: pid, ppid: ppid, uid: uid, rssKB: rss, command: command, path: resolved)
        }

        static func path(for pid: Int) -> String? {
            var buf = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
            guard n > 0 else { return nil }
            return String(cString: buf)
        }
    }

    private static func isUserTriggered(_ row: Raw) -> Bool {
        let path = row.path
        if path.hasSuffix("/Backgrounds") || path.contains("Backgrounds.app/") { return false }
        if path.hasPrefix("/System/") { return false }
        if path.hasPrefix("/usr/libexec/") { return false }
        if path.hasPrefix("/usr/sbin/") { return false }
        if path.hasPrefix("/sbin/") { return false }
        if path.hasPrefix("/Library/Apple/") { return false }
        if path.hasPrefix("/Library/SystemExtensions/") { return false }
        if path.hasPrefix("/System/Applications/") { return false }
        if path.contains(".appex/") { return false }

        // Interactive shells are the terminal, not a background thing you purge.
        let base = URL(fileURLWithPath: path).lastPathComponent
        if ["zsh", "bash", "sh", "fish", "nu", "login"].contains(base) { return false }

        if path.hasPrefix("/Applications/") { return true }
        if path.hasPrefix("/opt/") { return true }
        if path.hasPrefix("/usr/local/") { return true }
        if path.hasPrefix("/Users/") { return true }
        if path.hasPrefix(NSHomeDirectory()) { return true }

        // Interpreters only count when they're running user code.
        if isInterpreter(path) {
            return row.command.contains("/Users/")
                || row.command.contains("/opt/")
                || row.command.contains("/usr/local/")
                || row.command.contains(NSHomeDirectory())
        }
        return false
    }

    private static func isInterpreter(_ path: String) -> Bool {
        let base = URL(fileURLWithPath: path).lastPathComponent
        return base.hasPrefix("python")
            || base.hasPrefix("ruby")
            || base.hasPrefix("perl")
            || base.hasPrefix("node")
            || base.hasPrefix("osascript")
            || base == "java"
    }

    private static func executablePath(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: ".app") {
            return String(trimmed[..<range.upperBound])
        }
        if trimmed.hasPrefix("/") {
            return String(trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    private static func group(_ rows: [Raw]) -> [RunningItem] {
        var buckets: [String: [Raw]] = [:]
        for row in rows {
            buckets[groupKey(row), default: []].append(row)
        }
        return buckets.values.compactMap { members in
            let main = pickMain(members)
            let extras = members.filter { $0.pid != main.pid }.map(\.pid)
            let memory = members.reduce(UInt64(0)) { $0 + $1.rssKB * 1024 }
            return RunningItem(
                id: groupKey(main),
                name: displayName(main),
                pid: main.pid,
                extraPIDs: extras.sorted(),
                path: main.path,
                command: main.command,
                memoryBytes: memory,
                kind: main.path.contains(".app/") ? .app : .background
            )
        }
    }

    private static func groupKey(_ row: Raw) -> String {
        if let range = row.path.range(of: ".app") {
            return String(row.path[..<range.upperBound])
        }
        return row.path
    }

    private static func pickMain(_ members: [Raw]) -> Raw {
        members.min { lhs, rhs in
            let lHelper = isHelper(lhs)
            let rHelper = isHelper(rhs)
            if lHelper != rHelper { return !lHelper }
            return lhs.rssKB > rhs.rssKB
        } ?? members[0]
    }

    private static func isHelper(_ row: Raw) -> Bool {
        let name = row.name
        return name.contains("Helper")
            || row.path.contains("/Helpers/")
            || row.path.contains(".appex/")
    }

    private static func displayName(_ row: Raw) -> String {
        if let range = row.path.range(of: ".app") {
            let app = String(row.path[..<range.upperBound])
            return URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
        }
        return row.name
    }
}
