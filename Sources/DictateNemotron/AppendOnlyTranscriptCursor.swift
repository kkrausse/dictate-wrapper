import Foundation

struct CursorUpdate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ignored
        case appended
        case divergence
    }

    let kind: Kind
    let textToInsert: String
    let cumulativeText: String
    let isFinal: Bool
    let appendTrailingSpace: Bool
    let diagnostic: String?

    static func ignored(cumulativeText: String, isFinal: Bool) -> CursorUpdate {
        CursorUpdate(
            kind: .ignored,
            textToInsert: "",
            cumulativeText: cumulativeText,
            isFinal: isFinal,
            appendTrailingSpace: false,
            diagnostic: nil
        )
    }
}

/// Converts FluidAudio's append-only cumulative callback into paste-safe deltas.
struct AppendOnlyTranscriptCursor: Sendable {
    private(set) var observedText = ""
    private(set) var emittedCharacterCount = 0
    private(set) var lastDivergentText: String?

    mutating func observe(_ cumulative: String, isFinal: Bool) -> CursorUpdate {
        guard !cumulative.isEmpty else {
            return .ignored(cumulativeText: cumulative, isFinal: isFinal)
        }

        guard cumulative.hasPrefix(observedText) else {
            lastDivergentText = cumulative
            return CursorUpdate(
                kind: .divergence,
                textToInsert: "",
                cumulativeText: cumulative,
                isFinal: isFinal,
                appendTrailingSpace: false,
                diagnostic: "append-only prefix violation: expected \(String(reflecting: observedText)), received \(String(reflecting: cumulative))"
            )
        }

        let suffixStart = cumulative.index(
            cumulative.startIndex,
            offsetBy: observedText.count
        )
        let suffix = String(cumulative[suffixStart...])
        observedText = cumulative
        emittedCharacterCount += suffix.count

        if suffix.isEmpty, !isFinal {
            return .ignored(cumulativeText: cumulative, isFinal: false)
        }

        return CursorUpdate(
            kind: .appended,
            textToInsert: suffix,
            cumulativeText: cumulative,
            isFinal: isFinal,
            appendTrailingSpace: isFinal,
            diagnostic: nil
        )
    }

    mutating func reset() {
        observedText = ""
        emittedCharacterCount = 0
        lastDivergentText = nil
    }
}
