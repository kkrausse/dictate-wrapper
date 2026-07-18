import Foundation
import Qwen3ASR

enum BoundaryReason: String, Sendable {
    case modelOutput = "model-output"
    case vadFinalization = "vad-finalization"
    case maximumDurationFinalization = "maximum-duration-finalization"
    case explicitStopFinalization = "explicit-stop-finalization"
}

struct StreamingTranscript: Sendable {
    var text: String
    var isFinal: Bool
    var segmentIndex: Int
    var boundaryReason: BoundaryReason?
}

protocol StreamingASRSession: AnyObject {
    func pushAudio(_ samples: [Float], emitPartials: Bool) throws -> [StreamingTranscript]
    func finalize() throws -> [StreamingTranscript]
}

extension StreamingASRSession {
    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript] {
        try pushAudio(samples, emitPartials: true)
    }
}

struct StreamingASRBackend {
    let name: String
    let explicitStopPostRollSamples: Int
    let makeSession: () throws -> any StreamingASRSession

    init(
        name: String,
        explicitStopPostRollSamples: Int = 0,
        makeSession: @escaping () throws -> any StreamingASRSession
    ) {
        self.name = name
        self.explicitStopPostRollSamples = explicitStopPostRollSamples
        self.makeSession = makeSession
    }

    static func qwen3(
        model: Qwen3ASRModel,
        language: String?
    ) -> StreamingASRBackend {
        return StreamingASRBackend(
            name: "QWEN3-ASR"
        ) {
            BatchRetranscriptionSession { audio in
                model.transcribe(
                    audio: audio,
                    sampleRate: 16_000,
                    language: language,
                    maxTokens: 448
                )
            }
        }
    }
}

struct StreamingSessionBoundaryResult {
    var segmentIndex: Int?
    var transcripts: [StreamingTranscript] = []
    var finalizationError: Error?
    var recreationError: Error?
}

/// Owns the replaceable engine session and assigns app-level segment IDs.
final class StreamingSessionManager {
    let backendName: String

    private let makeSession: () throws -> any StreamingASRSession
    private let explicitStopPostRollSamples: Int
    private var session: (any StreamingASRSession)?
    private var pushedSamples = 0
    private var latestText = ""
    private(set) var segmentIndex = 0

    init(backend: StreamingASRBackend) throws {
        backendName = backend.name
        makeSession = backend.makeSession
        explicitStopPostRollSamples = backend.explicitStopPostRollSamples
        session = try backend.makeSession()
    }

    func pushAudio(
        _ samples: [Float],
        emitPartials: Bool = true
    ) throws -> [StreamingTranscript] {
        guard let session else { throw StreamingSessionManagerError.noActiveSession }
        let transcripts = try session.pushAudio(samples, emitPartials: emitPartials)
        pushedSamples += samples.count
        if let text = transcripts.last?.text {
            latestText = text
        }
        return transcripts.map {
            transcript($0, segmentIndex: segmentIndex, boundaryReason: $0.boundaryReason)
        }
    }

    func finalize(
        reason: BoundaryReason,
        recreateSession: Bool
    ) -> StreamingSessionBoundaryResult {
        guard let finalizedSession = session else { return StreamingSessionBoundaryResult() }

        // Clear first so a finalized session can never receive more audio or
        // be finalized a second time, including when finalization throws.
        session = nil
        let finalizedSegmentIndex = segmentIndex
        var result = StreamingSessionBoundaryResult(segmentIndex: finalizedSegmentIndex)
        do {
            var postRollStartText: String?
            var postRollCallbackCount = 0
            var residualSamples = 0

            // Some streaming backends defer trailing emissions until another
            // native chunk; VAD boundaries already include ample real silence.
            if reason == .explicitStopFinalization,
               explicitStopPostRollSamples > 0
            {
                residualSamples = pushedSamples % explicitStopPostRollSamples
                postRollStartText = latestText
                let postRoll = try finalizedSession.pushAudio(
                    [Float](repeating: 0, count: explicitStopPostRollSamples)
                )
                postRollCallbackCount = postRoll.count
                if let text = postRoll.last?.text {
                    latestText = text
                }
            }

            let finalizedTranscripts = try finalizedSession.finalize()
            if let text = finalizedTranscripts.last?.text {
                latestText = text
            }
            if let postRollStartText {
                dlog(
                    "\(backendName) explicit-stop post-roll: real=\(pushedSamples) "
                        + "residual=\(residualSamples)/\(explicitStopPostRollSamples) "
                        + "silence=\(explicitStopPostRollSamples) callbacks=\(postRollCallbackCount) "
                        + "final-hypothesis-changed=\(latestText != postRollStartText)"
                )
            }

            result.transcripts = finalizedTranscripts.map {
                transcript(
                    $0,
                    segmentIndex: finalizedSegmentIndex,
                    boundaryReason: reason,
                    forceFinal: true
                )
            }
        } catch {
            result.finalizationError = error
        }

        if recreateSession {
            segmentIndex += 1
            pushedSamples = 0
            latestText = ""
            do {
                session = try makeSession()
            } catch {
                result.recreationError = error
            }
        }
        return result
    }

    private func transcript(
        _ transcript: StreamingTranscript,
        segmentIndex: Int,
        boundaryReason: BoundaryReason?,
        forceFinal: Bool = false
    ) -> StreamingTranscript {
        StreamingTranscript(
            text: transcript.text,
            isFinal: forceFinal || transcript.isFinal,
            segmentIndex: segmentIndex,
            boundaryReason: boundaryReason
        )
    }
}

enum StreamingSessionManagerError: Error {
    case noActiveSession
}

/// Adapts cumulative, batch-only ASR models to the app's streaming session
/// surface. Native streaming models should implement `StreamingASRSession`
/// directly so their encoder caches and decoder state remain intact.
final class BatchRetranscriptionSession: StreamingASRSession {
    private static let sampleRate = 16_000
    private static let initialPartialIntervalSamples = sampleRate * 2
    private static let longUtterancePartialIntervalSamples = sampleRate * 4
    private static let longUtteranceThresholdSamples = sampleRate * 10

    private let transcribeBatch: ([Float]) -> String
    private var audio: [Float] = []
    private var nextPartialSampleCount = initialPartialIntervalSamples
    private var latestText = ""

    init(transcribeBatch: @escaping ([Float]) -> String) {
        self.transcribeBatch = transcribeBatch
    }

    func pushAudio(
        _ samples: [Float],
        emitPartials: Bool
    ) throws -> [StreamingTranscript] {
        audio.append(contentsOf: samples)
        guard audio.count >= nextPartialSampleCount else { return [] }
        let interval = partialInterval(for: audio.count)
        nextPartialSampleCount = audio.count + interval
        guard emitPartials else { return [] }

        latestText = transcribe()
        guard !latestText.isEmpty else { return [] }
        return [transcript(text: latestText, isFinal: false)]
    }

    private func partialInterval(for sampleCount: Int) -> Int {
        sampleCount >= Self.longUtteranceThresholdSamples
            ? Self.longUtterancePartialIntervalSamples
            : Self.initialPartialIntervalSamples
    }

    func finalize() throws -> [StreamingTranscript] {
        guard !audio.isEmpty else { return [] }
        let finalText = transcribe()
        audio.removeAll(keepingCapacity: false)
        guard !finalText.isEmpty else { return [] }
        return [transcript(text: finalText, isFinal: true)]
    }

    private func transcribe() -> String {
        transcribeBatch(audio).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcript(text: String, isFinal: Bool) -> StreamingTranscript {
        StreamingTranscript(
            text: text,
            isFinal: isFinal,
            segmentIndex: 0,
            boundaryReason: .modelOutput
        )
    }
}
