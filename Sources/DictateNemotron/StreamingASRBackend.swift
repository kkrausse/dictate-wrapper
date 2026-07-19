import Foundation
import MLX
import NemotronStreamingASR
import Qwen3ASR

struct BatchASRTuning: Sendable {
    static let sampleRate = 16_000

    let emitsPartials: Bool
    let initialPartialIntervalSamples: Int
    let longPartialIntervalSamples: Int
    let longUtteranceThresholdSamples: Int
    let maximumSegmentSamples: Int
    let backpressureThresholdSamples: Int

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BatchASRTuning {
        BatchASRTuning(
            emitsPartials: environment["DICTATE_PARTIALS"] != "0",
            initialPartialIntervalSamples: samples(
                environment["DICTATE_PARTIAL_INTERVAL_SECONDS"], defaultSeconds: 2
            ),
            longPartialIntervalSamples: samples(
                environment["DICTATE_LONG_PARTIAL_INTERVAL_SECONDS"], defaultSeconds: 4
            ),
            longUtteranceThresholdSamples: samples(
                environment["DICTATE_LONG_UTTERANCE_SECONDS"], defaultSeconds: 10
            ),
            maximumSegmentSamples: samples(
                environment["DICTATE_MAX_SEGMENT_SECONDS"], defaultSeconds: 20
            ),
            backpressureThresholdSamples: samples(
                environment["DICTATE_BACKPRESSURE_SECONDS"], defaultSeconds: 1
            )
        )
    }

    private static func samples(_ value: String?, defaultSeconds: Double) -> Int {
        let seconds = value.flatMap(Double.init).flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? defaultSeconds
        return max(1, Int((seconds * Double(sampleRate)).rounded()))
    }
}

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
    let batchTuning: BatchASRTuning?
    let makeSession: () throws -> any StreamingASRSession

    init(
        name: String,
        explicitStopPostRollSamples: Int = 0,
        batchTuning: BatchASRTuning? = nil,
        makeSession: @escaping () throws -> any StreamingASRSession
    ) {
        self.name = name
        self.explicitStopPostRollSamples = explicitStopPostRollSamples
        self.batchTuning = batchTuning
        self.makeSession = makeSession
    }

    static func qwen3(
        model: Qwen3ASRModel,
        language: String?
    ) -> StreamingASRBackend {
        let tuning = BatchASRTuning.fromEnvironment()
        let clearsMLXCache = ProcessInfo.processInfo.environment["DICTATE_MLX_CLEAR_CACHE"] != "0"
        return StreamingASRBackend(
            name: "QWEN3-ASR",
            batchTuning: tuning
        ) {
            BatchRetranscriptionSession(tuning: tuning) { audio in
                let text = model.transcribe(
                    audio: audio,
                    sampleRate: 16_000,
                    language: language,
                    maxTokens: 448
                )
                if clearsMLXCache {
                    Memory.clearCache()
                }
                return text
            }
        }
    }

    static func nemotronEnglish(
        model: NemotronStreamingASRModel
    ) -> StreamingASRBackend {
        StreamingASRBackend(
            name: "NEMOTRON-STREAMING-EN",
            // Give the RNN-T one complete native chunk on an explicit
            // push-to-talk release so trailing tokens can leave its cache.
            explicitStopPostRollSamples: model.config.streaming.chunkMs
                * model.config.sampleRate / 1_000
        ) {
            NemotronEnglishStreamingSession(
                session: try model.createSession(language: "en-US")
            )
        }
    }
}

/// Thin app adapter around speech-swift's stateful, cache-aware RNN-T
/// session. Unlike `BatchRetranscriptionSession`, every push processes only
/// new audio while encoder caches and decoder state survive between pushes.
final class NemotronEnglishStreamingSession: StreamingASRSession {
    private let session: NemotronStreamingASR.StreamingSession

    init(session: NemotronStreamingASR.StreamingSession) {
        self.session = session
    }

    func pushAudio(
        _ samples: [Float],
        emitPartials: Bool
    ) throws -> [StreamingTranscript] {
        let partials = try session.pushAudio(samples)
        guard emitPartials else { return [] }
        return partials.map(Self.transcript)
    }

    func finalize() throws -> [StreamingTranscript] {
        try session.finalize().map(Self.transcript)
    }

    private static func transcript(
        _ partial: NemotronStreamingASRModel.PartialTranscript
    ) -> StreamingTranscript {
        StreamingTranscript(
            text: partial.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: partial.isFinal,
            segmentIndex: partial.segmentIndex,
            boundaryReason: .modelOutput
        )
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
    private let tuning: BatchASRTuning
    private let transcribeBatch: ([Float]) -> String
    private var audio: [Float] = []
    private var nextPartialSampleCount: Int
    private var latestText = ""

    init(
        tuning: BatchASRTuning = .fromEnvironment(),
        transcribeBatch: @escaping ([Float]) -> String
    ) {
        self.tuning = tuning
        self.transcribeBatch = transcribeBatch
        nextPartialSampleCount = tuning.initialPartialIntervalSamples
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
        sampleCount >= tuning.longUtteranceThresholdSamples
            ? tuning.longPartialIntervalSamples
            : tuning.initialPartialIntervalSamples
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
