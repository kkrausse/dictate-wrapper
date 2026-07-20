import FluidAudio
import Foundation

protocol FluidStreamingEngine: Actor {
    var displayName: String { get }
    func load() async throws
    func reset() async throws
    func appendAudio(_ samples: [Float]) async throws
    func processBufferedAudio() async throws
    func finish() async throws -> String
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async
}

actor FluidAudioStreamingEngine: FluidStreamingEngine {
    static let defaultModelVariant: StreamingModelVariant = .parakeetUnified1120ms

    private let manager: any StreamingAsrManager
    private var partialCallback: (@Sendable (String) -> Void)?
    private var loadedDisplayName: String

    init(modelVariant: StreamingModelVariant = defaultModelVariant) {
        manager = modelVariant.createManager()
        loadedDisplayName = modelVariant.displayName
    }

    init(manager: any StreamingAsrManager) {
        self.manager = manager
        loadedDisplayName = Self.defaultModelVariant.displayName
    }

    static func legacyNemotron1120ms() -> FluidAudioStreamingEngine {
        FluidAudioStreamingEngine(modelVariant: .nemotron1120ms)
    }

    var displayName: String {
        loadedDisplayName
    }

    func load() async throws {
        try await manager.loadModels()
        loadedDisplayName = await manager.displayName
    }

    func reset() async throws {
        try await manager.reset()
    }

    func appendAudio(_ samples: [Float]) async throws {
        try await manager.appendAudio(AudioBufferBridge.make16KMonoBuffer(samples: samples))
    }

    func processBufferedAudio() async throws {
        try await manager.processBufferedAudio()
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        partialCallback = callback
        await manager.setPartialTranscriptCallback { [weak self] text in
            Task { await self?.forwardPartial(text) }
        }
    }

    private func forwardPartial(_ text: String) {
        partialCallback?(text)
    }
}

enum FluidStreamingPipelineEvent: Sendable {
    case transcript(sessionID: Int, update: CursorUpdate)
    case failure(sessionID: Int, description: String)
}

enum FluidStreamingPipelineError: Equatable, LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "FluidAudio models have not loaded."
        }
    }
}

/// Serializes FluidAudio ASR work while preserving the manager's actor isolation.
actor FluidStreamingPipeline {
    private let engine: any FluidStreamingEngine
    private let eventSink: @MainActor @Sendable (FluidStreamingPipelineEvent) -> Void
    private var cursor = AppendOnlyTranscriptCursor()
    private var drainTask: Task<Void, Never>?
    private var isLoaded = false
    private var isAcceptingAudio = false
    private var isFinishing = false
    private var sessionIsOpen = false
    private var sessionID = 0

    // Callers on the real-time audio thread cannot `await` into the actor
    // synchronously, so the tap appends captured chunks to this lock-guarded
    // buffer before any Task hop. That fixes chunk order at capture time
    // (unstructured Tasks carry no FIFO guarantee) and lets `finishUtterance`
    // drain everything captured before stop without awaiting per-chunk Tasks.
    private let handoffLock = NSLock()
    nonisolated(unsafe) private var handoffAudio: [[Float]] = []

    init(
        engine: any FluidStreamingEngine = FluidAudioStreamingEngine(),
        eventSink: @escaping @MainActor @Sendable (FluidStreamingPipelineEvent) -> Void
    ) {
        self.engine = engine
        self.eventSink = eventSink
    }

    func load() async throws -> String {
        guard !isLoaded else { return await engine.displayName }
        try await engine.load()
        isLoaded = true
        return await engine.displayName
    }

    func startUtterance() async throws -> Int {
        guard isLoaded else { throw FluidStreamingPipelineError.notLoaded }
        clearHandoffAudio()
        isAcceptingAudio = true
        isFinishing = false
        try await beginSession()
        return sessionID
    }

    func enqueueAudio(_ samples: [Float]) {
        guard isLoaded, isAcceptingAudio, !isFinishing, !samples.isEmpty else { return }
        appendHandoffAudio(samples)
        scheduleDrain()
    }

    /// Synchronous entry point for the audio tap callback, which runs on the
    /// real-time audio thread and cannot `await` directly into the actor.
    /// The chunk lands in the handoff buffer before this returns; the Task
    /// only wakes the drain loop.
    nonisolated func enqueueAudioAsync(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        appendHandoffAudio(samples)
        Task { await self.scheduleDrain() }
    }

    nonisolated private func appendHandoffAudio(_ samples: [Float]) {
        handoffLock.lock()
        defer { handoffLock.unlock() }
        handoffAudio.append(samples)
    }

    nonisolated private func takeHandoffAudio() -> [[Float]] {
        handoffLock.lock()
        defer { handoffLock.unlock() }
        let chunks = handoffAudio
        handoffAudio.removeAll(keepingCapacity: true)
        return chunks
    }

    nonisolated private func clearHandoffAudio() {
        handoffLock.lock()
        defer { handoffLock.unlock() }
        handoffAudio.removeAll()
    }

    func finishUtterance() async throws {
        guard !isFinishing else { return }
        isFinishing = true
        isAcceptingAudio = false

        if let drainTask {
            await drainTask.value
        }
        // The tap appended synchronously, so every chunk captured before stop
        // is in the handoff buffer even if its wake-up Task never ran.
        let chunks = takeHandoffAudio()
        guard sessionIsOpen else { return }
        await processChunks(chunks)
        try await finishCurrentSession()
    }

    private func scheduleDrain() {
        guard isLoaded, isAcceptingAudio, !isFinishing else { return }
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainPendingAudio()
        }
    }

    private func drainPendingAudio() async {
        while !isFinishing {
            let chunks = takeHandoffAudio()
            guard !chunks.isEmpty else { break }
            await processChunks(chunks)
        }
        drainTask = nil
    }

    private func processChunks(_ chunks: [[Float]]) async {
        for samples in chunks {
            do {
                try await process(samples)
            } catch {
                await emit(.failure(sessionID: sessionID, description: error.localizedDescription))
            }
        }
    }

    private func process(_ samples: [Float]) async throws {
        guard isLoaded else { throw FluidStreamingPipelineError.notLoaded }
        if !sessionIsOpen {
            try await beginSession()
        }

        try await engine.appendAudio(samples)
        try await engine.processBufferedAudio()
    }

    private func beginSession() async throws {
        sessionID += 1
        cursor.reset()
        try await engine.reset()
        let callbackSessionID = sessionID
        await engine.setPartialCallback { [weak self] text in
            Task { await self?.receivePartial(text, sessionID: callbackSessionID) }
        }
        sessionIsOpen = true
    }

    private func receivePartial(_ text: String, sessionID: Int) async {
        guard sessionID == self.sessionID, sessionIsOpen else { return }
        let update = cursor.observe(text, isFinal: false)
        guard update.kind != .ignored else { return }
        await emit(.transcript(sessionID: sessionID, update: update))
    }

    private func finishCurrentSession() async throws {
        guard sessionIsOpen else { return }
        // Mark closed before awaiting finalization so an old callback cannot
        // paste text into the next decoder session.
        sessionIsOpen = false
        let finalText = try await engine.finish()
        let update = cursor.observe(finalText, isFinal: true)
        if update.kind != .ignored {
            await emit(.transcript(sessionID: sessionID, update: update))
        }
        try await engine.reset()
    }

    private func emit(_ event: FluidStreamingPipelineEvent) async {
        await eventSink(event)
    }
}
