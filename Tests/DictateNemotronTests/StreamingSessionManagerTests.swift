import XCTest
@testable import DictateNemotron

final class StreamingSessionManagerTests: XCTestCase {
    func testVADBoundaryFinalizesOnceAndRecreatesSession() throws {
        let first = FakeStreamingSession(finalText: "first")
        let second = FakeStreamingSession(finalText: "second")
        var sessions = [first, second]
        let manager = try StreamingSessionManager(backend: StreamingASRBackend(
            name: "FAKE",
            explicitStopPostRollSamples: 4
        ) {
            sessions.removeFirst()
        })

        let boundary = manager.finalize(reason: .vadFinalization, recreateSession: true)
        XCTAssertEqual(first.finalizeCount, 1)
        XCTAssertTrue(first.pushedAudio.isEmpty, "VAD silence is already post-roll")
        XCTAssertEqual(boundary.transcripts.map(\.text), ["first"])
        XCTAssertEqual(boundary.segmentIndex, 0)
        XCTAssertEqual(boundary.transcripts.first?.segmentIndex, 0)
        XCTAssertEqual(boundary.transcripts.first?.boundaryReason, .vadFinalization)

        _ = try manager.pushAudio([1])
        XCTAssertEqual(first.pushCount, 0)
        XCTAssertEqual(second.pushCount, 1)

        let nextBoundary = manager.finalize(reason: .vadFinalization, recreateSession: false)
        XCTAssertEqual(first.finalizeCount, 1)
        XCTAssertEqual(second.finalizeCount, 1)
        XCTAssertEqual(nextBoundary.transcripts.first?.segmentIndex, 1)
    }

    func testExplicitStopFinalizesActiveSessionOnceWithoutRecreation() throws {
        let session = FakeStreamingSession(finalText: "done")
        var creationCount = 0
        let manager = try StreamingSessionManager(backend: StreamingASRBackend(
            name: "FAKE",
            explicitStopPostRollSamples: 4
        ) {
            creationCount += 1
            return session
        })

        _ = try manager.pushAudio([1, 2, 3])

        let first = manager.finalize(reason: .explicitStopFinalization, recreateSession: false)
        let second = manager.finalize(reason: .explicitStopFinalization, recreateSession: false)

        XCTAssertEqual(session.finalizeCount, 1)
        XCTAssertEqual(session.pushedAudio, [[1, 2, 3], [0, 0, 0, 0]])
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(first.transcripts.first?.boundaryReason, .explicitStopFinalization)
        XCTAssertTrue(second.transcripts.isEmpty)
        XCTAssertThrowsError(try manager.pushAudio([1]))
    }

    func testEveryRecreatedSessionUsesConfiguredFactoryValue() throws {
        let configuredLanguage = "en-US"
        var receivedLanguages: [String] = []
        let manager = try StreamingSessionManager(backend: StreamingASRBackend(name: "FAKE") {
            receivedLanguages.append(configuredLanguage)
            return FakeStreamingSession(finalText: "")
        })

        _ = manager.finalize(reason: .vadFinalization, recreateSession: true)
        _ = manager.finalize(reason: .vadFinalization, recreateSession: true)

        XCTAssertEqual(receivedLanguages, ["en-US", "en-US", "en-US"])
    }
}

private final class FakeStreamingSession: StreamingASRSession {
    let finalText: String
    private(set) var pushedAudio: [[Float]] = []
    private(set) var finalizeCount = 0

    var pushCount: Int { pushedAudio.count }

    init(finalText: String) {
        self.finalText = finalText
    }

    func pushAudio(_ samples: [Float]) throws -> [StreamingTranscript] {
        pushedAudio.append(samples)
        return []
    }

    func finalize() throws -> [StreamingTranscript] {
        finalizeCount += 1
        guard !finalText.isEmpty else { return [] }
        return [StreamingTranscript(
            text: finalText,
            isFinal: true,
            segmentIndex: 0,
            boundaryReason: .modelOutput
        )]
    }
}
