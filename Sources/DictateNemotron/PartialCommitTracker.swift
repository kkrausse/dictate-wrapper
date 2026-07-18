import Foundation

struct StableToken {
    var normalizedText: String
    var renderedText: String
    var stableSince: ContinuousClock.Instant
}

struct PartialCommitState {
    var committedNormalizedTokens: [String]
    var committedRenderedText: String
    var stableTokens: [StableToken]
    var latestPartial: String

    static let empty = PartialCommitState(
        committedNormalizedTokens: [],
        committedRenderedText: "",
        stableTokens: [],
        latestPartial: ""
    )
}

struct PartialCommitCandidate {
    let normalizedTokens: [String]
    let renderedText: String
    let tokenCount: Int
}

struct PartialCommitObservation {
    enum CallbackBehavior: String {
        case initial
        case repeated
        case cumulativeExtension = "cumulative-extension"
        case cumulativeRetraction = "cumulative-retraction"
        case revisionOrDelta = "revision-or-delta"
    }

    let alignmentPoint: Int
    let callbackBehavior: CallbackBehavior
    let divergence: String?
    let candidate: PartialCommitCandidate?
}

struct PartialCommitTracker {
    // Keep cumulative Qwen hypotheses visible longer before pasting their
    // stable prefix. This makes late punctuation and capitalization revisions
    // observable while still allowing incremental insertion during long speech.
    static let stableDuration = Duration.seconds(2.1)
    static let trailingWordGuard = 3
    static let minimumWordCount = 2
    static let minimumCharacterCount = 10

    private(set) var state: PartialCommitState = .empty

    mutating func observe(
        _ partial: String,
        at now: ContinuousClock.Instant,
        forceFinalization: Bool = false
    ) -> PartialCommitObservation {
        let previousTokens = Self.tokenize(state.latestPartial).map(\.normalizedText)
        let hypothesisTokens = Self.tokenize(partial)
        let normalizedHypothesis = hypothesisTokens.map(\.normalizedText)
        let behavior = Self.callbackBehavior(previous: previousTokens, current: normalizedHypothesis)
        let alignment = Self.alignment(
            committed: state.committedNormalizedTokens,
            hypothesis: normalizedHypothesis
        )
        let uncommitted = Array(hypothesisTokens.dropFirst(alignment.point))

        var unchangedCount = 0
        while unchangedCount < min(state.stableTokens.count, uncommitted.count),
              state.stableTokens[unchangedCount].normalizedText == uncommitted[unchangedCount].normalizedText
        {
            unchangedCount += 1
        }

        var nextStableTokens: [StableToken] = []
        nextStableTokens.reserveCapacity(uncommitted.count)
        for index in uncommitted.indices {
            let token = uncommitted[index]
            let stableSince = index < unchangedCount
                ? state.stableTokens[index].stableSince
                : now
            nextStableTokens.append(StableToken(
                normalizedText: token.normalizedText,
                renderedText: token.renderedText,
                stableSince: stableSince
            ))
        }
        state.stableTokens = nextStableTokens
        state.latestPartial = partial

        let eligibleCount: Int
        if forceFinalization {
            eligibleCount = state.stableTokens.count
        } else {
            let stablePrefixCount = state.stableTokens.prefix {
                $0.stableSince.duration(to: now) >= Self.stableDuration
            }.count
            eligibleCount = max(0, stablePrefixCount - Self.trailingWordGuard)
        }

        var candidate: PartialCommitCandidate?
        if eligibleCount > 0 {
            let eligible = state.stableTokens.prefix(eligibleCount)
            let renderedText = eligible.map(\.renderedText).joined()
            let characterCount = renderedText.trimmingCharacters(in: .whitespacesAndNewlines).count
            if forceFinalization
                || eligibleCount >= Self.minimumWordCount
                || characterCount >= Self.minimumCharacterCount
            {
                candidate = PartialCommitCandidate(
                    normalizedTokens: eligible.map(\.normalizedText),
                    renderedText: renderedText,
                    tokenCount: eligibleCount
                )
            }
        }

        return PartialCommitObservation(
            alignmentPoint: alignment.point,
            callbackBehavior: behavior,
            divergence: alignment.divergence,
            candidate: candidate
        )
    }

    mutating func didInsert(_ candidate: PartialCommitCandidate) {
        guard candidate.tokenCount <= state.stableTokens.count else { return }
        state.committedNormalizedTokens.append(contentsOf: candidate.normalizedTokens)
        state.committedRenderedText += candidate.renderedText
        state.stableTokens.removeFirst(candidate.tokenCount)
    }

    mutating func reset() {
        state = .empty
    }

    func stableTokenAges(at now: ContinuousClock.Instant) -> String {
        state.stableTokens.map { token in
            let duration = token.stableSince.duration(to: now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
            return "\(String(reflecting: token.normalizedText)):\(String(format: "%.2fs", seconds))"
        }.joined(separator: ", ")
    }

    private struct HypothesisToken {
        let normalizedText: String
        let renderedText: String
    }

    private static func tokenize(_ text: String) -> [HypothesisToken] {
        guard !text.isEmpty else { return [] }

        var wordRanges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            wordRanges.append(range)
        }

        return wordRanges.enumerated().compactMap { index, wordRange in
            let normalized = normalize(String(text[wordRange]))
            guard !normalized.isEmpty else { return nil }
            let renderedStart = index == 0 ? text.startIndex : wordRange.lowerBound
            let renderedEnd = index + 1 < wordRanges.count
                ? wordRanges[index + 1].lowerBound
                : text.endIndex
            return HypothesisToken(
                normalizedText: normalized,
                renderedText: String(text[renderedStart..<renderedEnd])
            )
        }
    }

    private static func normalize(_ token: String) -> String {
        var scalars = Array(token.lowercased().unicodeScalars)
        while let last = scalars.last, CharacterSet.punctuationCharacters.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func callbackBehavior(
        previous: [String],
        current: [String]
    ) -> PartialCommitObservation.CallbackBehavior {
        guard !previous.isEmpty else { return .initial }
        if previous == current { return .repeated }
        if current.starts(with: previous) { return .cumulativeExtension }
        if previous.starts(with: current) { return .cumulativeRetraction }
        return .revisionOrDelta
    }

    private static func alignment(
        committed: [String],
        hypothesis: [String]
    ) -> (point: Int, divergence: String?) {
        guard !committed.isEmpty else { return (0, nil) }

        let commonPrefixCount = zip(committed, hypothesis).prefix { $0 == $1 }.count
        if commonPrefixCount == committed.count {
            return (committed.count, nil)
        }

        // Find the hypothesis prefix that best aligns with the immutable
        // committed prefix. This tolerates substitutions, insertions, and
        // removals behind the low-water mark without replaying committed text.
        var previousRow = Array(0...hypothesis.count)
        for committedIndex in committed.indices {
            var currentRow = [committedIndex + 1]
            currentRow.reserveCapacity(hypothesis.count + 1)
            for hypothesisIndex in hypothesis.indices {
                let substitution = previousRow[hypothesisIndex]
                    + (committed[committedIndex] == hypothesis[hypothesisIndex] ? 0 : 1)
                let deletion = previousRow[hypothesisIndex + 1] + 1
                let insertion = currentRow[hypothesisIndex] + 1
                currentRow.append(min(substitution, deletion, insertion))
            }
            previousRow = currentRow
        }

        let bestPoint = previousRow.indices.min { left, right in
            if previousRow[left] != previousRow[right] {
                return previousRow[left] < previousRow[right]
            }
            let leftDistance = abs(left - committed.count)
            let rightDistance = abs(right - committed.count)
            return leftDistance == rightDistance ? left > right : leftDistance < rightDistance
        } ?? min(committed.count, hypothesis.count)
        let divergence = "matchedPrefix=\(commonPrefixCount)/\(committed.count) alignment=\(bestPoint) edits=\(previousRow[bestPoint])"
        return (bestPoint, divergence)
    }
}
