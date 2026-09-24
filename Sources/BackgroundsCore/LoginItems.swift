import Foundation

/// "Open at Login" items from System Settings > General > Login Items.
public struct LoginItem: Identifiable, Hashable, Sendable, Decodable {
    public var id: String { name + "|" + path }
    public var name: String
    public var path: String
    public var hidden: Bool

    public init(name: String, path: String, hidden: Bool) {
        self.name = name
        self.path = path
        self.hidden = hidden
    }
}

public enum LoginItems {
    // JXA returns JSON, so names and paths with commas survive intact.
    static let listScript = """
    JSON.stringify(Application("System Events").loginItems().map(function (i) {
      return { name: i.name(), path: i.path() || "", hidden: i.hidden() === true };
    }))
    """

    /// Asks System Events. The first call triggers macOS's Automation prompt.
    public static func list() throws -> [LoginItem] {
        let raw = try Shell.output("/usr/bin/osascript", ["-l", "JavaScript", "-e", listScript])
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> [LoginItem] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return try JSONDecoder().decode([LoginItem].self, from: Data(trimmed.utf8))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func remove(_ item: LoginItem) throws {
        let name = item.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        _ = try Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(name)\""])
    }
}
