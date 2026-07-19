import XCTest
@testable import DictateNemotron

final class AppendOnlyTranscriptCursorTests: XCTestCase {
    func testEmptyAndRepeatedCallbacksDoNotInsert() {
        var cursor = AppendOnlyTranscriptCursor()

        XCTAssertEqual(cursor.observe("", isFinal: false).kind, .ignored)
        XCTAssertEqual(cursor.observe("hello", isFinal: false).textToInsert, "hello")
        XCTAssertEqual(cursor.observe("hello", isFinal: false).kind, .ignored)
    }

    func testCumulativeExtensionsEmitOnlyTheNewSuffix() {
        var cursor = AppendOnlyTranscriptCursor()

        XCTAssertEqual(cursor.observe("hello", isFinal: false).textToInsert, "hello")
        XCTAssertEqual(cursor.observe("hello world", isFinal: false).textToInsert, " world")
        XCTAssertEqual(cursor.emittedCharacterCount, "hello world".count)
    }

    func testMultiPieceWordsPunctuationCapitalizationAndContractionsAreVerbatim() {
        var cursor = AppendOnlyTranscriptCursor()

        XCTAssertEqual(cursor.observe("I can", isFinal: false).textToInsert, "I can")
        XCTAssertEqual(cursor.observe("I can't", isFinal: false).textToInsert, "'t")
        XCTAssertEqual(cursor.observe("I can't believe", isFinal: false).textToInsert, " believe")
        XCTAssertEqual(cursor.observe("I can't believe NASA", isFinal: false).textToInsert, " NASA")
        XCTAssertEqual(cursor.observe("I can't believe NASA!", isFinal: false).textToInsert, "!")
    }

    func testFinalIdenticalPartialRequestsOnlyTrailingSpace() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("finished", isFinal: false)
        let update = cursor.observe("finished", isFinal: true)

        XCTAssertEqual(update.kind, .appended)
        XCTAssertEqual(update.textToInsert, "")
        XCTAssertTrue(update.appendTrailingSpace)
        XCTAssertTrue(update.isFinal)
    }

    func testFinalWithRemainingSuffixEmitsItAndRequestsTrailingSpace() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("hello", isFinal: false)
        let update = cursor.observe("hello world", isFinal: true)

        XCTAssertEqual(update.textToInsert, " world")
        XCTAssertTrue(update.appendTrailingSpace)
    }

    func testUnicodeStringIndexingEmitsWholeCharacters() {
        var cursor = AppendOnlyTranscriptCursor()
        let wave = "\u{1F44B}"
        let greeting = "hello " + wave

        _ = cursor.observe("hello ", isFinal: false)
        let update = cursor.observe(greeting, isFinal: false)

        XCTAssertEqual(update.textToInsert, wave)
        XCTAssertEqual(cursor.emittedCharacterCount, greeting.count)
    }

    func testPrefixDivergenceRefusesInsertionAndPreservesDiagnosticText() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("hello world", isFinal: false)
        let update = cursor.observe("hello there", isFinal: true)

        XCTAssertEqual(update.kind, .divergence)
        XCTAssertEqual(update.textToInsert, "")
        XCTAssertFalse(update.appendTrailingSpace)
        XCTAssertEqual(cursor.observedText, "hello world")
        XCTAssertEqual(cursor.lastDivergentText, "hello there")
    }

    func testResetStartsAnIndependentUtterance() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("repeat", isFinal: true)
        cursor.reset()
        let update = cursor.observe("repeat", isFinal: false)

        XCTAssertEqual(update.textToInsert, "repeat")
        XCTAssertEqual(cursor.emittedCharacterCount, "repeat".count)
    }
}
