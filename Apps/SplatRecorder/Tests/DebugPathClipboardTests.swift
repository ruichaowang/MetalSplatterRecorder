import AppKit
import XCTest
@testable import SplatRecorder

final class DebugPathClipboardTests: XCTestCase {
    func testCopyPathWritesStringToPasteboard() throws {
        let name = NSPasteboard.Name("splatrecorder-debug-path-\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(NSPasteboard(name: name))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(DebugPathClipboard.copy("/tmp/splatrecorder-debug-bundle", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "/tmp/splatrecorder-debug-bundle")
    }
}
