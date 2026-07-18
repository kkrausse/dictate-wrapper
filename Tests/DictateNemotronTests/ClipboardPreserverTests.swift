import AppKit
import XCTest
@testable import DictateNemotron

@MainActor
final class ClipboardPreserverTests: XCTestCase {
    func testRestoresAllItemsAndRepresentationsAfterTemporaryText() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let customType = NSPasteboard.PasteboardType("com.example.dictate-test")
        let first = NSPasteboardItem()
        first.setString("original text", forType: .string)
        first.setData(Data([0, 1, 2, 3]), forType: customType)
        let second = NSPasteboardItem()
        second.setData(Data([9, 8, 7]), forType: .png)
        pasteboard.writeObjects([first, second])

        let preserver = ClipboardPreserver(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(1)
        )
        preserver.beginSession()
        XCTAssertTrue(preserver.writeTemporaryString("dictated"))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
        preserver.finishSession()

        try await Task.sleep(for: .milliseconds(20))
        let restored = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].string(forType: .string), "original text")
        XCTAssertEqual(restored[0].data(forType: customType), Data([0, 1, 2, 3]))
        XCTAssertEqual(restored[1].data(forType: .png), Data([9, 8, 7]))
    }

    func testRestoresAnInitiallyEmptyPasteboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let preserver = ClipboardPreserver(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(1)
        )

        preserver.beginSession()
        XCTAssertTrue(preserver.writeTemporaryString("dictated"))
        preserver.finishSession()

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }
}
