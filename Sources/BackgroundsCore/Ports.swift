import Foundation

public struct ListeningPort: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid)|\(proto)|\(address)" }
    public var pid: Int
    public var command: String
    public var user: String
    public var proto: String
    public var address: String

    public var port: Int? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return Int(address[address.index(after: colon)...])
    }

    /// Bound to every interface, so reachable from the network.
    public var isExposed: Bool {
        address.hasPrefix("*:") || address.hasPrefix("0.0.0.0:") || address.hasPrefix("[::]:")
    }
}

public enum Ports {
    /// TCP sockets in LISTEN. Without root, lsof only sees your own processes.
    public static func listening() throws -> [ListeningPort] {
        let result = try Shell.exec("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLPn"], allowFailure: true)
        // lsof exits 1 with no output when nothing matches. Only stderr means a real failure.
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.code != 0 && result.stdout.isEmpty && !stderr.isEmpty {
            throw ShellError.nonZero(command: "lsof", code: result.code, output: result.stderr)
        }
        return parse(result.stdout)
    }

    /// Parses `lsof -F pcLPn`: one field per line, keyed by its first character.
    static func parse(_ raw: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid = 0
        var command = ""
        var user = ""
        var proto = ""
        for line in raw.split(separator: "\n") {
            guard let key = line.first else { continue }
            let value = String(line.dropFirst())
            switch key {
            case "p": pid = Int(value) ?? 0; command = ""; user = ""
            case "c": command = value
            case "L": user = value
            case "P": proto = value
            case "n":
                let port = ListeningPort(pid: pid, command: command, user: user, proto: proto, address: value)
                if seen.insert(port.id).inserted { result.append(port) }
            default: break
            }
        }
        return result.sorted { ($0.port ?? 0, $0.pid) < ($1.port ?? 0, $1.pid) }
    }
}
