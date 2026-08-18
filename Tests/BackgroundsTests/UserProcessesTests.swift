import XCTest
@testable import BackgroundsCore

final class UserProcessesTests: XCTestCase {
    func testDropsAppleSystemPaths() {
        XCTAssertFalse(UserProcesses.isUserTriggered("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", command: "Finder"))
        XCTAssertFalse(UserProcesses.isUserTriggered("/usr/libexec/trustd", command: "/usr/libexec/trustd --agent"))
        XCTAssertFalse(UserProcesses.isUserTriggered("/bin/zsh", command: "/bin/zsh"))
    }

    func testKeepsUserAppsAndHomebrew() {
        XCTAssertTrue(UserProcesses.isUserTriggered("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        XCTAssertTrue(UserProcesses.isUserTriggered("/opt/homebrew/opt/redis/bin/redis-server", command: "/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379"))
    }

    func testInterpreterOnlyIfUserCode() {
        XCTAssertFalse(UserProcesses.isUserTriggered("/usr/bin/python3", command: "/usr/bin/python3"))
        XCTAssertTrue(UserProcesses.isUserTriggered(
            "/usr/bin/python3",
            command: "/usr/bin/python3 /Users/chinmayrelkar/tools/claude/claude-drift-check"
        ))
    }

    func testInventoryIsOnlyUserTriggered() throws {
        let items = try UserProcesses.inventory()
        for item in items {
            XCTAssertFalse(item.path.hasPrefix("/System/"), item.path)
            XCTAssertFalse(item.path.hasPrefix("/usr/libexec/"), item.path)
            XCTAssertNotEqual(item.name, "Finder")
        }
    }
}
