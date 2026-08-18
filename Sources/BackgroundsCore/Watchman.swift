import Foundation

public enum Watchman {
    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Shell.resolve("watchman"))
    }

    public static func list() throws -> [WatchRoot] {
        guard isAvailable else { return [] }
        let raw = try Shell.run("watchman", ["watch-list"])
        let parsed = try JSONDecoder().decode(WatchList.self, from: Data(raw.utf8))
        return parsed.roots.map { WatchRoot(path: $0) }
    }

    public static func drop(_ root: WatchRoot) throws {
        _ = try Shell.run("watchman", ["watch-del", root.path])
    }

    public static func dropAll() throws {
        _ = try Shell.run("watchman", ["watch-del-all"])
    }

    private struct WatchList: Decodable {
        let roots: [String]
    }
}
