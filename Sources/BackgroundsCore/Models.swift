import Foundation

public enum AgentScope: String, Sendable, CaseIterable, Identifiable {
    case user
    case systemAgent
    case daemon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .user: "Your login jobs"
        case .systemAgent: "Machine login jobs"
        case .daemon: "Daemons"
        }
    }

    public var domainPrefix: String {
        switch self {
        case .user: "gui/\(getuid())"
        case .systemAgent, .daemon: "system"
        }
    }

    public var needsAdmin: Bool { self != .user }

    public var searchDirectories: [URL] {
        switch self {
        case .user:
            [URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/LaunchAgents")]
        case .systemAgent:
            [URL(fileURLWithPath: "/Library/LaunchAgents")]
        case .daemon:
            [URL(fileURLWithPath: "/Library/LaunchDaemons")]
        }
    }
}

public enum AgentState: String, Sendable {
    case running
    case loaded
    case failed
    case notLoaded
    case emptyPlist

    public var title: String {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .failed: "Failed"
        case .notLoaded: "Not loaded"
        case .emptyPlist: "Empty stub"
        }
    }
}

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(scope.rawValue)|\(label)|\(plistPath)" }

    public var label: String
    public var scope: AgentScope
    public var plistPath: String
    public var program: String?
    public var arguments: [String]
    public var keepAlive: Bool
    public var runAtLoad: Bool
    public var startInterval: Int?
    public var calendarHint: String?
    public var pid: Int?
    public var lastExit: Int?
    public var listed: Bool
    public var isEmptyPlist: Bool

    public init(
        label: String,
        scope: AgentScope,
        plistPath: String,
        program: String?,
        arguments: [String],
        keepAlive: Bool,
        runAtLoad: Bool,
        startInterval: Int?,
        calendarHint: String?,
        pid: Int?,
        lastExit: Int?,
        listed: Bool,
        isEmptyPlist: Bool
    ) {
        self.label = label
        self.scope = scope
        self.plistPath = plistPath
        self.program = program
        self.arguments = arguments
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.startInterval = startInterval
        self.calendarHint = calendarHint
        self.pid = pid
        self.lastExit = lastExit
        self.listed = listed
        self.isEmptyPlist = isEmptyPlist
    }

    public var isApple: Bool { label.hasPrefix("com.apple.") }

    public var state: AgentState {
        if isEmptyPlist { return .emptyPlist }
        if let pid, pid > 0 { return .running }
        if listed, let lastExit, lastExit != 0 { return .failed }
        if listed { return .loaded }
        return .notLoaded
    }

    public var serviceTarget: String { "\(scope.domainPrefix)/\(label)" }

    public var canStop: Bool { listed && !isEmptyPlist }
    public var canStart: Bool { !listed && !isEmptyPlist }
}

public struct WatchRoot: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String

    public init(path: String) { self.path = path }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

public struct RuntimeStatus: Sendable {
    public var pid: Int?
    public var lastExit: Int?
    public var listed: Bool

    public init(pid: Int?, lastExit: Int?, listed: Bool) {
        self.pid = pid
        self.lastExit = lastExit
        self.listed = listed
    }
}
