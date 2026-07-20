import AppKit
import Testing
@testable import DictateNemotron

@MainActor
struct ClipboardPreserverTests {
    @Test func restoresAllItemsAndRepresentationsAfterTemporaryText() async throws {
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
        #expect(preserver.writeTemporaryString("dictated"))
        #expect(pasteboard.string(forType: .string) == "dictated")
        preserver.finishSession()

        try await Task.sleep(for: .milliseconds(20))
        let restored = try #require(pasteboard.pasteboardItems)
        #expect(restored.count == 2)
        #expect(restored[0].string(forType: .string) == "original text")
        #expect(restored[0].data(forType: customType) == Data([0, 1, 2, 3]))
        #expect(restored[1].data(forType: .png) == Data([9, 8, 7]))
    }

    @Test func restoresAnInitiallyEmptyPasteboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let preserver = ClipboardPreserver(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(1)
        )

        preserver.beginSession()
        #expect(preserver.writeTemporaryString("dictated"))
        preserver.finishSession()

        try await Task.sleep(for: .milliseconds(20))
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }
}
