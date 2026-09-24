import Foundation

public struct BrewService: Identifiable, Hashable, Sendable, Decodable {
    public var id: String { name }
    public var name: String
    public var status: String
    public var user: String?
    public var file: String?
    public var exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case name, status, user, file
        case exitCode = "exit_code"
    }

    public init(name: String, status: String, user: String?, file: String?, exitCode: Int?) {
        self.name = name
        self.status = status
        self.user = user
        self.file = file
        self.exitCode = exitCode
    }

    public var isRunning: Bool { status == "started" || status == "scheduled" }
}

public enum BrewServices {
    public enum Action: String, Sendable {
        case start, stop, restart
    }

    public static var isAvailable: Bool { Shell.isInstalled("brew") }

    static let quiet = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    public static func list() throws -> [BrewService] {
        guard isAvailable else { return [] }
        return try parse(try Shell.output("brew", ["services", "list", "--json"], env: quiet))
    }

    static func parse(_ raw: String) throws -> [BrewService] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return try JSONDecoder().decode([BrewService].self, from: Data(trimmed.utf8))
    }

    public static func perform(_ action: Action, on service: BrewService) throws {
        _ = try Shell.exec("brew", ["services", action.rawValue, service.name], env: quiet)
    }
}
