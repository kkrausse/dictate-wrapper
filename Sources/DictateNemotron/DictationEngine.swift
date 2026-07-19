import Foundation

enum DictationEngine: String, CaseIterable, Sendable {
    case fluidNemotron560 = "fluid-nemotron-560"
    case speechSwiftNemotron = "speech-swift-nemotron"
    case qwen3

    var displayName: String {
        switch self {
        case .fluidNemotron560:
            return "FluidAudio Nemotron 0.6B (560 ms)"
        case .speechSwiftNemotron:
            return "Speech Swift Nemotron"
        case .qwen3:
            return "Qwen3-ASR"
        }
    }

    static func selected(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DictationEngine {
        guard let rawValue = environment["DICTATE_ASR_BACKEND"] else {
            return .fluidNemotron560
        }
        guard let engine = DictationEngine(rawValue: rawValue.lowercased()) else {
            throw DictationEngineSelectionError.unsupported(rawValue)
        }
        return engine
    }
}

enum DictationEngineSelectionError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let value):
            let supported = DictationEngine.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unsupported DICTATE_ASR_BACKEND '\(value)'. Supported values: \(supported)."
        }
    }
}
