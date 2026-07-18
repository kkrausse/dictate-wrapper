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
    let makeSession: () throws -> any StreamingASRSession

    static func nemotron(
        model: NemotronStreamingASRModel,
        language: String?
    ) -> StreamingASRBackend {
        StreamingASRBackend(name: "NEMOTRON") {
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
    private var session: (any StreamingASRSession)?
    private(set) var segmentIndex = 0

    init(backend: StreamingASRBackend) throws {
        backendName = backend.name
        makeSession = backend.makeSession
        session = try backend.makeSession()
    }

    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript] {
        guard let session else { throw StreamingSessionManagerError.noActiveSession }
        return try session.pushAudio(samples).map {
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
            result.transcripts = try finalizedSession.finalize().map {
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
