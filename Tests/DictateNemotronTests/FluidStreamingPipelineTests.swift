import XCTest
@testable import DictateNemotron

final class FluidStreamingPipelineTests: XCTestCase {
    func testAudioCannotStartBeforeModelsLoad() async {
        let pipeline = makePipeline()

        do {
            _ = try await pipeline.startUtterance()
            XCTFail("Expected start to require model loading")
        } catch let error as FluidStreamingPipelineError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadIsIdempotent() async throws {
        let engine = FakeFluidEngine()
        let pipeline = makePipeline(engine: engine)

        _ = try await pipeline.load()
        _ = try await pipeline.load()

        let loadCount = await engine.loadCount
        XCTAssertEqual(loadCount, 1)
    }

    func testExplicitStopDrainsQueuedAudioBeforeFinishingExactlyOnce() async throws {
        let engine = FakeFluidEngine()
        let pipeline = makePipeline(engine: engine)

        _ = try await pipeline.load()
        _ = try await pipeline.startUtterance()
        await pipeline.enqueueAudio([Float](repeating: 0, count: 4096))
        try await pipeline.finishUtterance()
        try await pipeline.finishUtterance()

        let appendCount = await engine.appendCount
        let processCount = await engine.processCount
        let finishCount = await engine.finishCount
        XCTAssertEqual(appendCount, 1)
        XCTAssertEqual(processCount, 1)
        XCTAssertEqual(finishCount, 1)
    }

    func testAudioDoesNotFinalizeUntilExplicitStop() async throws {
        let engine = FakeFluidEngine()
        let pipeline = makePipeline(engine: engine)

        _ = try await pipeline.load()
        _ = try await pipeline.startUtterance()
        await pipeline.enqueueAudio([Float](repeating: 0, count: 4096))
        try await pipeline.finishUtterance()

        let finishCount = await engine.finishCount
        let resetCount = await engine.resetCount
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(resetCount, 2)
    }

    private func makePipeline(engine: FakeFluidEngine = FakeFluidEngine()) -> FluidStreamingPipeline {
        FluidStreamingPipeline(engine: engine) { _ in }
    }
}

private actor FakeFluidEngine: FluidStreamingEngine {
    var displayName = "Fake Fluid Engine"
    private(set) var loadCount = 0
    private(set) var resetCount = 0
    private(set) var appendCount = 0
    private(set) var processCount = 0
    private(set) var finishCount = 0
    private var callback: (@Sendable (String) -> Void)?

    func load() async throws {
        loadCount += 1
    }

    func reset() async throws {
        resetCount += 1
    }

    func appendAudio(_ samples: [Float]) async throws {
        appendCount += 1
    }

    func processBufferedAudio() async throws {
        processCount += 1
    }

    func finish() async throws -> String {
        finishCount += 1
        return ""
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.callback = callback
    }
}
