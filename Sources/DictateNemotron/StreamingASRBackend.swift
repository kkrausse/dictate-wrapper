import Foundation
import NemotronStreamingASR

enum BoundaryReason: String, Sendable {
    case modelOutput = "model-output"
    case vadFinalization = "vad-finalization"
    case explicitStopFinalization = "explicit-stop-finalization"
}

struct StreamingTranscript: Sendable {
    var text: String
    var isFinal: Bool
    var segmentIndex: Int
    var boundaryReason: BoundaryReason?
}

protocol StreamingASRSession: AnyObject {
    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript]
    func finalize() throws -> [StreamingTranscript]
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

    static func nemotron(
        model: NemotronStreamingASRModel,
        language: String?
    ) -> StreamingASRBackend {
        let samplesPerChunk = model.config.streaming.melFrames * model.config.hopLength
        return StreamingASRBackend(
            name: "NEMOTRON",
            explicitStopPostRollSamples: samplesPerChunk
        ) {
            let session = try model.createSession(language: language)
            return NemotronSessionAdapter(session: session)
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

    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript] {
        guard let session else { throw StreamingSessionManagerError.noActiveSession }
        let transcripts = try session.pushAudio(samples)
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

            // Nemotron can defer trailing emissions until another native
            // chunk; VAD boundaries already include ample real silence.
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

private final class NemotronSessionAdapter: StreamingASRSession {
    private let session: NemotronStreamingASR.StreamingSession

    init(session: NemotronStreamingASR.StreamingSession) {
        self.session = session
    }

    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript] {
        try session.pushAudio(samples).map(Self.transcript)
    }

    func finalize() throws -> [StreamingTranscript] {
        try session.finalize().map(Self.transcript)
    }

    private static func transcript(
        _ transcript: NemotronStreamingASRModel.PartialTranscript
    ) -> StreamingTranscript {
        StreamingTranscript(
            text: transcript.text,
            isFinal: transcript.isFinal,
            segmentIndex: transcript.segmentIndex,
            boundaryReason: .modelOutput
        )
    }
}
