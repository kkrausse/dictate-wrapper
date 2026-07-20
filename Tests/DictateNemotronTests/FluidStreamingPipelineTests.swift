import Testing
@testable import DictateNemotron

struct FluidStreamingPipelineTests {
    @Test func defaultEngineUsesParakeetUnified1120ms() {
        #expect(FluidAudioStreamingEngine.defaultModelVariant == .parakeetUnified1120ms)
    }

    @Test func audioCannotStartBeforeModelsLoad() async {
        let pipeline = makePipeline()

        await #expect(throws: FluidStreamingPipelineError.notLoaded) {
            _ = try await pipeline.startUtterance()
        }
    }

    @Test func loadIsIdempotent() async throws {
        let engine = FakeFluidEngine()
        let pipeline = makePipeline(engine: engine)

        _ = try await pipeline.load()
        _ = try await pipeline.load()

        let loadCount = await engine.loadCount
        #expect(loadCount == 1)
    }

    @Test func explicitStopDrainsQueuedAudioBeforeFinishingExactlyOnce() async throws {
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
        #expect(appendCount == 1)
        #expect(processCount == 1)
        #expect(finishCount == 1)
    }

    @Test func audioDoesNotFinalizeUntilExplicitStop() async throws {
        let engine = FakeFluidEngine()
        let pipeline = makePipeline(engine: engine)

        _ = try await pipeline.load()
        _ = try await pipeline.startUtterance()
        await pipeline.enqueueAudio([Float](repeating: 0, count: 4096))
        try await pipeline.finishUtterance()

        let finishCount = await engine.finishCount
        let resetCount = await engine.resetCount
        #expect(finishCount == 1)
        #expect(resetCount == 2)
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
