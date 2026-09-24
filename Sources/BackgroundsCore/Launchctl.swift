import Foundation

public enum Launchctl {
    public static func inventory() throws -> [LaunchItem] {
        let guiStatus = try listStatus()
        let systemStatus = (try? systemStatus()) ?? [:]
        let guiDisabled = disabledLabels(domain: AgentScope.user.domainPrefix)
        let systemDisabled = disabledLabels(domain: AgentScope.daemon.domainPrefix)
        var items: [LaunchItem] = []
        for scope in AgentScope.allCases {
            let status = scope == .daemon ? systemStatus : guiStatus
            let disabled = scope == .daemon ? systemDisabled : guiDisabled
            for url in plistURLs(in: scope) {
                var item = try parsePlist(url, scope: scope)
                if let runtime = status[item.label] {
                    item.pid = runtime.pid
                    item.lastExit = runtime.lastExit
                    item.listed = runtime.listed
                }
                item.disabled = disabled.contains(item.label)
                items.append(item)
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return rank(lhs.state) < rank(rhs.state)
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    public static func stop(_ item: LaunchItem) throws {
        _ = try Shell.run("/bin/launchctl", ["bootout", item.serviceTarget], admin: item.scope.controlNeedsAdmin)
    }

    public static func start(_ item: LaunchItem) throws {
        _ = try Shell.run(
            "/bin/launchctl",
            ["bootstrap", item.scope.domainPrefix, item.plistPath],
            admin: item.scope.controlNeedsAdmin
        )
    }

    /// Unload now and keep it from loading at next login, without deleting the plist.
    public static func disable(_ item: LaunchItem) throws {
        _ = try Shell.run("/bin/launchctl", ["disable", item.serviceTarget], admin: item.scope.controlNeedsAdmin)
        if item.listed {
            do { try stop(item) } catch {
                if !isMissing(error) { throw error }
            }
        }
    }

    public static func enable(_ item: LaunchItem) throws {
        _ = try Shell.run("/bin/launchctl", ["enable", item.serviceTarget], admin: item.scope.controlNeedsAdmin)
    }

    public static func purge(_ item: LaunchItem) throws {
        if item.listed {
            do { try stop(item) } catch {
                // Missing/already unloaded is fine; we still want the plist gone.
                if !isMissing(error) { throw error }
            }
        }
        if item.scope.needsAdmin {
            _ = try Shell.run("/bin/rm", ["-f", item.plistPath], admin: true)
        } else {
            try FileManager.default.removeItem(atPath: item.plistPath)
        }
    }

    /// Status for the caller's gui domain (~/Library and /Library LaunchAgents).
    public static func listStatus() throws -> [String: RuntimeStatus] {
        parseList(try Shell.run("/bin/launchctl", ["list"]))
    }

    /// Status for the system domain (LaunchDaemons). `launchctl list` as a user never shows these.
    public static func systemStatus() throws -> [String: RuntimeStatus] {
        parseSystemPrint(try Shell.output("/bin/launchctl", ["print", "system"]))
    }

    static func parseList(_ raw: String) -> [String: RuntimeStatus] {
        var result: [String: RuntimeStatus] = [:]
        for line in raw.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            result[cols[2]] = RuntimeStatus(pid: Int(cols[0]), lastExit: Int(cols[1]), listed: true)
        }
        return result
    }

    /// Reads the `services = { ... }` block: "<pid> <status> <label>". pid 0 means not running.
    static func parseSystemPrint(_ raw: String) -> [String: RuntimeStatus] {
        var result: [String: RuntimeStatus] = [:]
        var inServices = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inServices {
                if trimmed == "services = {" { inServices = true }
                continue
            }
            if trimmed == "}" { break }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 3, let pid = Int(cols[0]) else { continue }
            let label = cols[2...].joined(separator: " ")
            result[label] = RuntimeStatus(pid: pid > 0 ? pid : nil, lastExit: Int(cols[1]), listed: true)
        }
        return result
    }

    static func disabledLabels(domain: String) -> Set<String> {
        guard let raw = try? Shell.output("/bin/launchctl", ["print-disabled", domain]) else { return [] }
        return parseDisabled(raw)
    }

    static func parseDisabled(_ raw: String) -> Set<String> {
        var result = Set<String>()
        for line in raw.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value == "disabled" || value == "true" { result.insert(label) }
        }
        return result
    }

    public static func parsePlist(_ url: URL, scope: AgentScope) throws -> LaunchItem {
        let data = try Data(contentsOf: url)
        let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = obj as? [String: Any] ?? [:]
        let isEmpty = dict.isEmpty
        let label = (dict["Label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = (label?.isEmpty == false)
            ? label!
            : url.deletingPathExtension().lastPathComponent

        let args = dict["ProgramArguments"] as? [String] ?? []
        let program = (dict["Program"] as? String) ?? args.first
        let keepAlive: Bool
        if let flag = dict["KeepAlive"] as? Bool {
            keepAlive = flag
        } else if let map = dict["KeepAlive"] as? [String: Any] {
            keepAlive = !map.isEmpty
        } else {
            keepAlive = false
        }

        var item = LaunchItem(
            label: resolvedLabel,
            scope: scope,
            plistPath: url.path,
            program: program,
            arguments: args,
            keepAlive: keepAlive,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            startInterval: dict["StartInterval"] as? Int,
            calendarHint: calendarHint(dict["StartCalendarInterval"]),
            pid: nil,
            lastExit: nil,
            listed: false,
            isEmptyPlist: isEmpty
        )
        item.stdoutPath = expand(dict["StandardOutPath"] as? String)
        item.stderrPath = expand(dict["StandardErrorPath"] as? String)
        return item
    }

    /// Last `maxBytes` of a log file, starting at a line boundary.
    public static func tail(_ path: String, maxBytes: Int = 32_768) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    static func plistURLs(in scope: AgentScope) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in scope.searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            urls.append(contentsOf: entries.filter { $0.pathExtension == "plist" })
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("no such") || text.contains("not found") || text.contains("could not find")
    }

    private static func expand(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    private static func rank(_ state: AgentState) -> Int {
        switch state {
        case .failed: 0
        case .running: 1
        case .loaded: 2
        case .emptyPlist: 3
        case .disabled: 4
        case .notLoaded: 5
        }
    }

    private static func calendarHint(_ value: Any?) -> String? {
        func format(_ dict: [String: Any]) -> String {
            let day = dict["Day"] as? Int
            let weekday = dict["Weekday"] as? Int
            let hour = dict["Hour"] as? Int ?? 0
            let minute = dict["Minute"] as? Int ?? 0
            let time = String(format: "%02d:%02d", hour, minute)
            if let day { return "day \(day) @ \(time)" }
            if let weekday { return "weekday \(weekday) @ \(time)" }
            return time
        }
        if let dict = value as? [String: Any] { return format(dict) }
        if let list = value as? [[String: Any]], let first = list.first {
            let extra = list.count > 1 ? " +\(list.count - 1)" : ""
            return format(first) + extra
        }
        return nil
    }
}
