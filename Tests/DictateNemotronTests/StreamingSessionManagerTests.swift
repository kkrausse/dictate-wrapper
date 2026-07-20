import Testing
@testable import DictateNemotron

struct StreamingSessionManagerTests {
    @Test func batchAdapterBacksOffPartialCadenceForLongUtterances() throws {
        var transcribedSampleCounts: [Int] = []
        let session = BatchRetranscriptionSession(tuning: .fromEnvironment([:])) { audio in
            transcribedSampleCounts.append(audio.count)
            return "words"
        }

        for expectedSeconds in stride(from: 2, through: 10, by: 2) {
            let partials = try session.pushAudio([Float](repeating: 0, count: 32_000))
            #expect(partials.count == 1)
            #expect(transcribedSampleCounts.last == expectedSeconds * 16_000)
        }

        #expect(try session.pushAudio([Float](repeating: 0, count: 63_999)).isEmpty)
        #expect(try session.pushAudio([0]).count == 1)
        #expect(transcribedSampleCounts.last == 14 * 16_000)
    }

    @Test func batchAdapterSkipsStalePartialAndAdvancesCadence() throws {
        var transcriptionCount = 0
        let session = BatchRetranscriptionSession(tuning: .fromEnvironment([:])) { _ in
            transcriptionCount += 1
            return "words"
        }

        #expect(try session.pushAudio(
            [Float](repeating: 0, count: 32_000),
            emitPartials: false
        ).isEmpty)
        #expect(transcriptionCount == 0)
        #expect(try session.pushAudio(
            [Float](repeating: 0, count: 31_999),
            emitPartials: true
        ).isEmpty)
        #expect(try session.pushAudio([0], emitPartials: true).count == 1)
        #expect(transcriptionCount == 1)
    }

    @Test func batchTuningReadsEnvironmentAndFallsBackForInvalidValues() {
        let tuning = BatchASRTuning.fromEnvironment([
            "DICTATE_PARTIALS": "0",
            "DICTATE_PARTIAL_INTERVAL_SECONDS": "3.5",
            "DICTATE_LONG_PARTIAL_INTERVAL_SECONDS": "invalid",
            "DICTATE_LONG_UTTERANCE_SECONDS": "12",
            "DICTATE_MAX_SEGMENT_SECONDS": "25",
            "DICTATE_BACKPRESSURE_SECONDS": "1.5",
        ])

        #expect(!tuning.emitsPartials)
        #expect(tuning.initialPartialIntervalSamples == 56_000)
        #expect(tuning.longPartialIntervalSamples == 64_000)
        #expect(tuning.longUtteranceThresholdSamples == 192_000)
        #expect(tuning.maximumSegmentSamples == 400_000)
        #expect(tuning.backpressureThresholdSamples == 24_000)
    }

    @Test func vadBoundaryFinalizesOnceAndRecreatesSession() throws {
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
        #expect(first.finalizeCount == 1)
        #expect(first.pushedAudio.isEmpty, "VAD silence is already post-roll")
        #expect(boundary.transcripts.map(\.text) == ["first"])
        #expect(boundary.segmentIndex == 0)
        #expect(boundary.transcripts.first?.segmentIndex == 0)
        #expect(boundary.transcripts.first?.boundaryReason == .vadFinalization)

        _ = try manager.pushAudio([1])
        #expect(first.pushCount == 0)
        #expect(second.pushCount == 1)

        let nextBoundary = manager.finalize(reason: .vadFinalization, recreateSession: false)
        #expect(first.finalizeCount == 1)
        #expect(second.finalizeCount == 1)
        #expect(nextBoundary.transcripts.first?.segmentIndex == 1)
    }

    @Test func explicitStopFinalizesActiveSessionOnceWithoutRecreation() throws {
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

        #expect(session.finalizeCount == 1)
        #expect(session.pushedAudio == [[1, 2, 3], [0, 0, 0, 0]])
        #expect(creationCount == 1)
        #expect(first.transcripts.first?.boundaryReason == .explicitStopFinalization)
        #expect(second.transcripts.isEmpty)
        #expect(throws: (any Error).self) {
            try manager.pushAudio([1])
        }
    }

    @Test func everyRecreatedSessionUsesConfiguredFactoryValue() throws {
        let configuredLanguage = "en-US"
        var receivedLanguages: [String] = []
        let manager = try StreamingSessionManager(backend: StreamingASRBackend(name: "FAKE") {
            receivedLanguages.append(configuredLanguage)
            return FakeStreamingSession(finalText: "")
        })

        _ = manager.finalize(reason: .vadFinalization, recreateSession: true)
        _ = manager.finalize(reason: .vadFinalization, recreateSession: true)

        #expect(receivedLanguages == ["en-US", "en-US", "en-US"])
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
