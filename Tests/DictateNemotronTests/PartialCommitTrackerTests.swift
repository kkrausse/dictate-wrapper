import XCTest
@testable import DictateNemotron

final class PartialCommitTrackerTests: XCTestCase {
    private let clock = ContinuousClock()

    func testCommitsStablePrefixAfterExactDurationAndKeepsTrailingGuard() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"

        XCTAssertNil(tracker.observe(text, at: start).candidate)
        XCTAssertNil(tracker.observe(
            text,
            at: start.advanced(by: .milliseconds(1_699))
        ).candidate)

        let candidate = tracker.observe(
            text,
            at: start.advanced(by: .milliseconds(1_700))
        ).candidate
        XCTAssertEqual(candidate?.normalizedTokens, ["one", "two", "three"])
        XCTAssertEqual(candidate?.renderedText, "one two three ")
    }

    func testChangeResetsStabilityFromChangedPositionOnward() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        _ = tracker.observe("one two three four five six", at: start)
        _ = tracker.observe(
            "one two changed four five six",
            at: start.advanced(by: .seconds(1))
        )

        let tooEarly = tracker.observe(
            "one two changed four five six",
            at: start.advanced(by: .seconds(2))
        )
        XCTAssertNil(tooEarly.candidate)

        let stableAgain = tracker.observe(
            "one two changed four five six",
            at: start.advanced(by: .seconds(2.7))
        )
        XCTAssertEqual(stableAgain.candidate?.normalizedTokens, ["one", "two", "changed"])
    }

    func testInsertionResetsInsertedPositionAndFollowingTokens() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        _ = tracker.observe("one two three four five six", at: start)
        _ = tracker.observe(
            "one two inserted three four five six",
            at: start.advanced(by: .seconds(1))
        )

        let observation = tracker.observe(
            "one two inserted three four five six",
            at: start.advanced(by: .seconds(2))
        )
        XCTAssertNil(observation.candidate)
    }

    func testCapitalizationAndTrailingPunctuationPreserveStability() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        _ = tracker.observe("Hello, WORLD! four five six", at: start)

        let observation = tracker.observe(
            "hello world? four five six",
            at: start.advanced(by: .seconds(1.7))
        )
        XCTAssertEqual(observation.candidate?.normalizedTokens, ["hello", "world"])
        XCTAssertEqual(observation.candidate?.renderedText, "hello world? ")
    }

    func testOrdinaryCommitRequiresTwoWordsOrTenCharacters() {
        var shortTracker = PartialCommitTracker()
        let start = clock.now
        _ = shortTracker.observe("a b c d", at: start)
        XCTAssertNil(shortTracker.observe(
            "a b c d",
            at: start.advanced(by: .seconds(1.7))
        ).candidate)

        var longTracker = PartialCommitTracker()
        _ = longTracker.observe("extraordinary b c d", at: start)
        XCTAssertEqual(
            longTracker.observe(
                "extraordinary b c d",
                at: start.advanced(by: .seconds(1.7))
            ).candidate?.normalizedTokens,
            ["extraordinary"]
        )
    }

    func testStabilityEvidenceHasNoShortHistoryExpiry() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"
        _ = tracker.observe(text, at: start)

        let observation = tracker.observe(
            text,
            at: start.advanced(by: .seconds(60))
        )
        XCTAssertEqual(observation.candidate?.normalizedTokens, ["one", "two", "three"])
    }

    func testFinalizationCommitsAllRemainingTextAndResetsExplicitly() {
        var tracker = PartialCommitTracker()
        let now = clock.now
        let observation = tracker.observe(
            "one two three",
            at: now,
            forceFinalization: true
        )

        XCTAssertEqual(observation.candidate?.renderedText, "one two three")
        tracker.didInsert(try! XCTUnwrap(observation.candidate))
        XCTAssertEqual(tracker.state.committedNormalizedTokens, ["one", "two", "three"])
        tracker.reset()
        XCTAssertTrue(tracker.state.committedNormalizedTokens.isEmpty)
        XCTAssertTrue(tracker.state.stableTokens.isEmpty)
    }

    func testFailedFinalInsertionDoesNotAdvanceOrResetState() {
        var tracker = PartialCommitTracker()
        let observation = tracker.observe(
            "keep this text",
            at: clock.now,
            forceFinalization: true
        )

        XCTAssertNotNil(observation.candidate)
        // The caller only invokes didInsert and reset after destination
        // insertion succeeds.
        XCTAssertEqual(tracker.state.latestPartial, "keep this text")
        XCTAssertEqual(tracker.state.stableTokens.count, 3)
        XCTAssertTrue(tracker.state.committedNormalizedTokens.isEmpty)
    }

    func testCumulativeFinalCommitsOnlySuffixAfterPartialCommit() throws {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"
        _ = tracker.observe(text, at: start)
        let partial = tracker.observe(
            text,
            at: start.advanced(by: .seconds(1.7))
        )
        tracker.didInsert(try XCTUnwrap(partial.candidate))

        let final = tracker.observe(
            text,
            at: start.advanced(by: .seconds(2)),
            forceFinalization: true
        )

        XCTAssertEqual(final.candidate?.renderedText, "four five six")
        XCTAssertEqual(final.candidate?.normalizedTokens, ["four", "five", "six"])
    }

    func testIdenticalWordsInConsecutiveUtterancesAreEachCommittedOnce() throws {
        var tracker = PartialCommitTracker()
        let text = "repeat these words"

        let first = tracker.observe(text, at: clock.now, forceFinalization: true)
        XCTAssertEqual(first.candidate?.renderedText, text)
        tracker.didInsert(try XCTUnwrap(first.candidate))
        tracker.reset()

        let second = tracker.observe(text, at: clock.now, forceFinalization: true)
        XCTAssertEqual(second.candidate?.renderedText, text)
    }

    func testDivergentCommittedPrefixAlignsWithoutReplayingCommittedWords() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let initial = "one two three four five six"
        _ = tracker.observe(initial, at: start)
        let ordinary = tracker.observe(
            initial,
            at: start.advanced(by: .seconds(1.7))
        )
        tracker.didInsert(try! XCTUnwrap(ordinary.candidate))

        let final = tracker.observe(
            "one changed three four five six seven",
            at: start.advanced(by: .seconds(2)),
            forceFinalization: true
        )
        XCTAssertNotNil(final.divergence)
        XCTAssertEqual(final.alignmentPoint, 3)
        XCTAssertEqual(final.candidate?.normalizedTokens, ["four", "five", "six", "seven"])
        XCTAssertEqual(final.candidate?.renderedText, "four five six seven")
    }
}
