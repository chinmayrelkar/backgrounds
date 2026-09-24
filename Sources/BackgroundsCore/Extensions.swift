import Foundation

public struct SystemExtension: Identifiable, Hashable, Sendable {
    public var id: String { category + "|" + bundleID }
    public var category: String
    public var enabled: Bool
    public var active: Bool
    public var teamID: String
    public var bundleID: String
    public var version: String
    public var name: String
    public var state: String
}

/// Read-only. macOS only lets System Settings or the owning app remove these.
public enum Extensions {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    public static func list() throws -> [SystemExtension] {
        parse(try Shell.output("/usr/bin/systemextensionsctl", ["list"]))
    }

    /// Rows look like: `*\t*\tTEAMID\tbundle.id (1.0/1)\tName\t[activated enabled]`.
    static func parse(_ raw: String) -> [SystemExtension] {
        var result: [SystemExtension] = []
        var category = ""
        for line in raw.split(separator: "\n").map(String.init) {
            if line.hasPrefix("--- ") {
                let rest = line.dropFirst(4)
                let id = rest.split(separator: " ").first.map(String.init) ?? ""
                category = id.replacingOccurrences(of: "com.apple.system_extension.", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                continue
            }
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 6, cols[0] != "enabled" else { continue }
            let bundleCol = cols[3]
            var bundleID = bundleCol
            var version = ""
            if let open = bundleCol.firstIndex(of: "(") {
                bundleID = bundleCol[..<open].trimmingCharacters(in: .whitespaces)
                version = bundleCol[bundleCol.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            }
            result.append(SystemExtension(
                category: category,
                enabled: cols[0] == "*",
                active: cols[1] == "*",
                teamID: cols[2],
                bundleID: bundleID,
                version: version,
                name: cols[4],
                state: cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            ))
        }
        return result
    }
}
