import Testing
@testable import DictateNemotron

struct AppendOnlyTranscriptCursorTests {
    @Test func emptyAndRepeatedCallbacksDoNotInsert() {
        var cursor = AppendOnlyTranscriptCursor()

        #expect(cursor.observe("", isFinal: false).kind == .ignored)
        #expect(cursor.observe("hello", isFinal: false).textToInsert == "hello")
        #expect(cursor.observe("hello", isFinal: false).kind == .ignored)
    }

    @Test func cumulativeExtensionsEmitOnlyTheNewSuffix() {
        var cursor = AppendOnlyTranscriptCursor()

        #expect(cursor.observe("hello", isFinal: false).textToInsert == "hello")
        #expect(cursor.observe("hello world", isFinal: false).textToInsert == " world")
        #expect(cursor.emittedCharacterCount == "hello world".count)
    }

    @Test func multiPieceWordsPunctuationCapitalizationAndContractionsAreVerbatim() {
        var cursor = AppendOnlyTranscriptCursor()

        #expect(cursor.observe("I can", isFinal: false).textToInsert == "I can")
        #expect(cursor.observe("I can't", isFinal: false).textToInsert == "'t")
        #expect(cursor.observe("I can't believe", isFinal: false).textToInsert == " believe")
        #expect(cursor.observe("I can't believe NASA", isFinal: false).textToInsert == " NASA")
        #expect(cursor.observe("I can't believe NASA!", isFinal: false).textToInsert == "!")
    }

    @Test func finalIdenticalPartialRequestsOnlyTrailingSpace() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("finished", isFinal: false)
        let update = cursor.observe("finished", isFinal: true)

        #expect(update.kind == .appended)
        #expect(update.textToInsert == "")
        #expect(update.appendTrailingSpace)
        #expect(update.isFinal)
    }

    @Test func finalWithRemainingSuffixEmitsItAndRequestsTrailingSpace() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("hello", isFinal: false)
        let update = cursor.observe("hello world", isFinal: true)

        #expect(update.textToInsert == " world")
        #expect(update.appendTrailingSpace)
    }

    @Test func unicodeStringIndexingEmitsWholeCharacters() {
        var cursor = AppendOnlyTranscriptCursor()
        let wave = "\u{1F44B}"
        let greeting = "hello " + wave

        _ = cursor.observe("hello ", isFinal: false)
        let update = cursor.observe(greeting, isFinal: false)

        #expect(update.textToInsert == wave)
        #expect(cursor.emittedCharacterCount == greeting.count)
    }

    @Test func prefixDivergenceRefusesInsertionAndPreservesDiagnosticText() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("hello world", isFinal: false)
        let update = cursor.observe("hello there", isFinal: true)

        #expect(update.kind == .divergence)
        #expect(update.textToInsert == "")
        #expect(!update.appendTrailingSpace)
        #expect(cursor.observedText == "hello world")
        #expect(cursor.lastDivergentText == "hello there")
    }

    @Test func resetStartsAnIndependentUtterance() {
        var cursor = AppendOnlyTranscriptCursor()

        _ = cursor.observe("repeat", isFinal: true)
        cursor.reset()
        let update = cursor.observe("repeat", isFinal: false)

        #expect(update.textToInsert == "repeat")
        #expect(cursor.emittedCharacterCount == "repeat".count)
    }
}
