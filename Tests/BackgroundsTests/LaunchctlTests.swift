import XCTest
@testable import BackgroundsCore

final class LaunchctlTests: XCTestCase {
    func testParseKeepAliveAndCalendar() throws {
        let url = try writePlist("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.example.drift</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/python3</string>
                <string>/tmp/check</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Day</key>
                <integer>1</integer>
                <key>Hour</key>
                <integer>10</integer>
                <key>Minute</key>
                <integer>17</integer>
            </dict>
        </dict>
        </plist>
        """)
        let item = try Launchctl.parsePlist(url, scope: .user)
        XCTAssertEqual(item.label, "com.example.drift")
        XCTAssertEqual(item.program, "/usr/bin/python3")
        XCTAssertTrue(item.keepAlive)
        XCTAssertTrue(item.runAtLoad)
        XCTAssertEqual(item.calendarHint, "day 1 @ 10:17")
        XCTAssertFalse(item.isEmptyPlist)
        XCTAssertEqual(item.state, .notLoaded)
        XCTAssertTrue(item.serviceTarget.hasPrefix("gui/"))
        XCTAssertTrue(item.serviceTarget.hasSuffix("/com.example.drift"))
    }

    func testEmptyPlistIsStub() throws {
        let url = try writePlist("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """)
        let item = try Launchctl.parsePlist(url, scope: .systemAgent)
        XCTAssertTrue(item.isEmptyPlist)
        XCTAssertEqual(item.state, .emptyPlist)
        XCTAssertFalse(item.canStop)
        XCTAssertTrue(item.scope.needsAdmin)
        XCTAssertEqual(item.label, url.deletingPathExtension().lastPathComponent)
    }

    func testKeepAliveMapCountsAsEnabled() throws {
        let url = try writePlist("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.example.watch</string>
            <key>Program</key>
            <string>/opt/homebrew/bin/watchman</string>
            <key>KeepAlive</key>
            <dict>
                <key>Crashed</key>
                <true/>
            </dict>
        </dict>
        </plist>
        """)
        let item = try Launchctl.parsePlist(url, scope: .user)
        XCTAssertTrue(item.keepAlive)
        XCTAssertEqual(item.program, "/opt/homebrew/bin/watchman")
    }

    func testInventorySeesUserPlists() throws {
        let items = try Launchctl.inventory()
        XCTAssertFalse(items.filter { $0.scope == .user }.isEmpty)
        let redis = items.first { $0.label == "homebrew.mxcl.redis" }
        XCTAssertNotNil(redis)
        XCTAssertEqual(redis?.program?.contains("redis-server"), true)
    }

    private func writePlist(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-test-\(UUID().uuidString).plist")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
