import Foundation

public enum Launchctl {
    public static func inventory() throws -> [LaunchItem] {
        let status = try listStatus()
        var items: [LaunchItem] = []
        var seen = Set<String>()
        for scope in AgentScope.allCases {
            for url in plistURLs(in: scope) {
                var item = try parsePlist(url, scope: scope)
                if let runtime = status[item.label] {
                    item.pid = runtime.pid
                    item.lastExit = runtime.lastExit
                    item.listed = runtime.listed
                }
                items.append(item)
                seen.insert(item.label)
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
        _ = try Shell.run("/bin/launchctl", ["bootout", item.serviceTarget], admin: item.scope.needsAdmin)
    }

    public static func start(_ item: LaunchItem) throws {
        _ = try Shell.run(
            "/bin/launchctl",
            ["bootstrap", item.scope.domainPrefix, item.plistPath],
            admin: item.scope.needsAdmin
        )
    }

    public static func purge(_ item: LaunchItem) throws {
        if item.listed {
            do { try stop(item) } catch {
                // Missing/already unloaded is fine; we still want the plist gone.
                let text = error.localizedDescription.lowercased()
                if !text.contains("no such") && !text.contains("not found") && !text.contains("could not find") {
                    throw error
                }
            }
        }
        if item.scope.needsAdmin {
            _ = try Shell.run("/bin/rm", ["-f", item.plistPath], admin: true)
        } else {
            try FileManager.default.removeItem(atPath: item.plistPath)
        }
    }

    public static func listStatus() throws -> [String: RuntimeStatus] {
        let raw = try Shell.run("/bin/launchctl", ["list"])
        var result: [String: RuntimeStatus] = [:]
        for line in raw.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            let label = cols[2]
            let pid = Int(cols[0])
            let exit = Int(cols[1])
            result[label] = RuntimeStatus(pid: pid, lastExit: exit, listed: true)
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

        return LaunchItem(
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

    private static func rank(_ state: AgentState) -> Int {
        switch state {
        case .failed: 0
        case .running: 1
        case .loaded: 2
        case .emptyPlist: 3
        case .notLoaded: 4
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
