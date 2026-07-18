import XCTest
@testable import DictateNemotron

final class StreamingSessionManagerTests: XCTestCase {
    func testBatchAdapterBacksOffPartialCadenceForLongUtterances() throws {
        var transcribedSampleCounts: [Int] = []
        let session = BatchRetranscriptionSession(tuning: .fromEnvironment([:])) { audio in
            transcribedSampleCounts.append(audio.count)
            return "words"
        }

        for expectedSeconds in stride(from: 2, through: 10, by: 2) {
            let partials = try session.pushAudio([Float](repeating: 0, count: 32_000))
            XCTAssertEqual(partials.count, 1)
            XCTAssertEqual(transcribedSampleCounts.last, expectedSeconds * 16_000)
        }

        XCTAssertTrue(try session.pushAudio([Float](repeating: 0, count: 63_999)).isEmpty)
        XCTAssertEqual(try session.pushAudio([0]).count, 1)
        XCTAssertEqual(transcribedSampleCounts.last, 14 * 16_000)
    }

    func testBatchAdapterSkipsStalePartialAndAdvancesCadence() throws {
        var transcriptionCount = 0
        let session = BatchRetranscriptionSession(tuning: .fromEnvironment([:])) { _ in
            transcriptionCount += 1
            return "words"
        }

        XCTAssertTrue(try session.pushAudio(
            [Float](repeating: 0, count: 32_000),
            emitPartials: false
        ).isEmpty)
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertTrue(try session.pushAudio(
            [Float](repeating: 0, count: 31_999),
            emitPartials: true
        ).isEmpty)
        XCTAssertEqual(try session.pushAudio([0], emitPartials: true).count, 1)
        XCTAssertEqual(transcriptionCount, 1)
    }

    func testBatchTuningReadsEnvironmentAndFallsBackForInvalidValues() {
        let tuning = BatchASRTuning.fromEnvironment([
            "DICTATE_PARTIALS": "0",
            "DICTATE_PARTIAL_INTERVAL_SECONDS": "3.5",
            "DICTATE_LONG_PARTIAL_INTERVAL_SECONDS": "invalid",
            "DICTATE_LONG_UTTERANCE_SECONDS": "12",
            "DICTATE_MAX_SEGMENT_SECONDS": "25",
            "DICTATE_BACKPRESSURE_SECONDS": "1.5",
        ])

        XCTAssertFalse(tuning.emitsPartials)
        XCTAssertEqual(tuning.initialPartialIntervalSamples, 56_000)
        XCTAssertEqual(tuning.longPartialIntervalSamples, 64_000)
        XCTAssertEqual(tuning.longUtteranceThresholdSamples, 192_000)
        XCTAssertEqual(tuning.maximumSegmentSamples, 400_000)
        XCTAssertEqual(tuning.backpressureThresholdSamples, 24_000)
    }

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

    func pushAudio(
        _ samples: [Float],
        emitPartials: Bool
    ) throws -> [StreamingTranscript] {
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
