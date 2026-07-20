import Testing
@testable import DictateNemotron

struct PartialCommitTrackerTests {
    private let clock = ContinuousClock()

    @Test func commitsStablePrefixAfterExactDurationAndKeepsTrailingGuard() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"

        #expect(tracker.observe(text, at: start).candidate == nil)
        #expect(tracker.observe(
            text,
            at: start.advanced(by: PartialCommitTracker.stableDuration - .milliseconds(1))
        ).candidate == nil)

        let candidate = tracker.observe(
            text,
            at: start.advanced(by: PartialCommitTracker.stableDuration)
        ).candidate
        #expect(candidate?.normalizedTokens == ["one", "two", "three"])
        #expect(candidate?.renderedText == "one two three ")
    }

    @Test func changeResetsStabilityFromChangedPositionOnward() {
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
        #expect(tooEarly.candidate == nil)

        let stableAgain = tracker.observe(
            "one two changed four five six",
            at: start.advanced(by: .seconds(1) + PartialCommitTracker.stableDuration)
        )
        #expect(stableAgain.candidate?.normalizedTokens == ["one", "two", "changed"])
    }

    @Test func insertionResetsInsertedPositionAndFollowingTokens() {
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
        #expect(observation.candidate == nil)
    }

    @Test func capitalizationAndTrailingPunctuationPreserveStability() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        _ = tracker.observe("Hello, WORLD! four five six", at: start)

        let observation = tracker.observe(
            "hello world? four five six",
            at: start.advanced(by: PartialCommitTracker.stableDuration)
        )
        #expect(observation.candidate?.normalizedTokens == ["hello", "world"])
        #expect(observation.candidate?.renderedText == "hello world? ")
    }

    @Test func ordinaryCommitRequiresTwoWordsOrTenCharacters() {
        var shortTracker = PartialCommitTracker()
        let start = clock.now
        _ = shortTracker.observe("a b c d", at: start)
        #expect(shortTracker.observe(
            "a b c d",
            at: start.advanced(by: PartialCommitTracker.stableDuration)
        ).candidate == nil)

        var longTracker = PartialCommitTracker()
        _ = longTracker.observe("extraordinary b c d", at: start)
        #expect(
            longTracker.observe(
                "extraordinary b c d",
                at: start.advanced(by: PartialCommitTracker.stableDuration)
            ).candidate?.normalizedTokens == ["extraordinary"]
        )
    }

    @Test func stabilityEvidenceHasNoShortHistoryExpiry() {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"
        _ = tracker.observe(text, at: start)

        let observation = tracker.observe(
            text,
            at: start.advanced(by: .seconds(60))
        )
        #expect(observation.candidate?.normalizedTokens == ["one", "two", "three"])
    }

    @Test func finalizationCommitsAllRemainingTextAndResetsExplicitly() throws {
        var tracker = PartialCommitTracker()
        let now = clock.now
        let observation = tracker.observe(
            "one two three",
            at: now,
            forceFinalization: true
        )

        #expect(observation.candidate?.renderedText == "one two three")
        tracker.didInsert(try #require(observation.candidate))
        #expect(tracker.state.committedNormalizedTokens == ["one", "two", "three"])
        tracker.reset()
        #expect(tracker.state.committedNormalizedTokens.isEmpty)
        #expect(tracker.state.stableTokens.isEmpty)
    }

    @Test func failedFinalInsertionDoesNotAdvanceOrResetState() {
        var tracker = PartialCommitTracker()
        let observation = tracker.observe(
            "keep this text",
            at: clock.now,
            forceFinalization: true
        )

        #expect(observation.candidate != nil)
        // The caller only invokes didInsert and reset after destination
        // insertion succeeds.
        #expect(tracker.state.latestPartial == "keep this text")
        #expect(tracker.state.stableTokens.count == 3)
        #expect(tracker.state.committedNormalizedTokens.isEmpty)
    }

    @Test func cumulativeFinalCommitsOnlySuffixAfterPartialCommit() throws {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let text = "one two three four five six"
        _ = tracker.observe(text, at: start)
        let partial = tracker.observe(
            text,
            at: start.advanced(by: PartialCommitTracker.stableDuration)
        )
        tracker.didInsert(try #require(partial.candidate))

        let final = tracker.observe(
            text,
            at: start.advanced(by: .seconds(2)),
            forceFinalization: true
        )

        #expect(final.candidate?.renderedText == "four five six")
        #expect(final.candidate?.normalizedTokens == ["four", "five", "six"])
    }

    @Test func identicalWordsInConsecutiveUtterancesAreEachCommittedOnce() throws {
        var tracker = PartialCommitTracker()
        let text = "repeat these words"

        let first = tracker.observe(text, at: clock.now, forceFinalization: true)
        #expect(first.candidate?.renderedText == text)
        tracker.didInsert(try #require(first.candidate))
        tracker.reset()

        let second = tracker.observe(text, at: clock.now, forceFinalization: true)
        #expect(second.candidate?.renderedText == text)
    }

    @Test func divergentCommittedPrefixAlignsWithoutReplayingCommittedWords() throws {
        var tracker = PartialCommitTracker()
        let start = clock.now
        let initial = "one two three four five six"
        _ = tracker.observe(initial, at: start)
        let ordinary = tracker.observe(
            initial,
            at: start.advanced(by: PartialCommitTracker.stableDuration)
        )
        tracker.didInsert(try #require(ordinary.candidate))

        let final = tracker.observe(
            "one changed three four five six seven",
            at: start.advanced(by: .seconds(2)),
            forceFinalization: true
        )
        #expect(final.divergence != nil)
        #expect(final.alignmentPoint == 3)
        #expect(final.candidate?.normalizedTokens == ["four", "five", "six", "seven"])
        #expect(final.candidate?.renderedText == "four five six seven")
    }
}
