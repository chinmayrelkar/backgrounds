import Foundation

public struct Container: Identifiable, Hashable, Sendable {
    public var id: String { engine + "|" + containerID }
    public var engine: String
    public var containerID: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var ports: String
    public var project: String?

    public var isRunning: Bool { state == "running" }
}

/// Docker-compatible engines: Docker Desktop, OrbStack and Colima all answer to `docker`.
public enum Containers {
    public enum Action: String, Sendable {
        case start, stop, restart
        case remove = "rm"
    }

    public static let engines = ["docker", "podman"]

    public static var available: [String] { engines.filter(Shell.isInstalled) }

    /// All containers from every engine that answers. A stopped daemon is skipped, not fatal.
    public static func list() -> (items: [Container], errors: [String]) {
        var items: [Container] = []
        var errors: [String] = []
        for engine in available {
            do {
                let raw = try Shell.output(engine, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"])
                items += parse(raw, engine: engine)
            } catch {
                errors.append("\(engine): \(error.localizedDescription)")
            }
        }
        return (items.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }, errors)
    }

    static func parse(_ raw: String, engine: String) -> [Container] {
        raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            func str(_ key: String) -> String {
                if let value = obj[key] as? String { return value }
                if let list = obj[key] as? [String] { return list.joined(separator: ", ") }
                return ""
            }
            let labels = str("Labels")
            let project = labels.split(separator: ",")
                .first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return Container(
                engine: engine,
                containerID: str("ID").isEmpty ? str("Id") : str("ID"),
                name: str("Names"),
                image: str("Image"),
                state: str("State").lowercased(),
                status: str("Status"),
                ports: str("Ports"),
                project: project
            )
        }
    }

    public static func perform(_ action: Action, on container: Container) throws {
        _ = try Shell.run(container.engine, [action.rawValue, container.containerID])
    }
}
