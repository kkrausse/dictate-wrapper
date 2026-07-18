import AppKit
import Foundation
import NemotronStreamingASR
import SpeechVAD

let logPath = "/tmp/dictate.log"
let logLock = NSLock()

func dlog(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }

    guard let data = "\(message)\n".data(using: .utf8) else { return }
    if let file = FileHandle(forWritingAtPath: logPath) {
        file.seekToEndOfFile()
        file.write(data)
        file.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

private func logTimestamp() -> String {
    String(format: "%.3f", Date().timeIntervalSince1970)
}

/// Owns the mutable streaming state used by the off-main-thread audio pipeline.
final class ASRProcessor: @unchecked Sendable {
    private let sessions: StreamingSessionManager
    private let vad: SileroVADModel
    private let lock = NSLock()
    private let buffer = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    private let vadLeftover = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    private let pendingPartials = UnsafeMutablePointer<[StreamingTranscript]>.allocate(capacity: 1)
    private let allAudio = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    nonisolated(unsafe) var speechActive = false
    nonisolated(unsafe) var silenceCount = 0
    nonisolated(unsafe) var hasPendingUtterance = false
    nonisolated(unsafe) var lastRms: Float = 0

    // 30 VAD chunks at 512 samples and 16 kHz is about 960 ms of silence.
    private let forceFinalizeSilentChunks = 30

    init(backend: StreamingASRBackend, vad: SileroVADModel) throws {
        sessions = try StreamingSessionManager(backend: backend)
        self.vad = vad
        buffer.initialize(to: [])
        vadLeftover.initialize(to: [])
        pendingPartials.initialize(to: [])
        allAudio.initialize(to: [])
        vad.resetState()
    }

    deinit {
        buffer.deinitialize(count: 1)
        buffer.deallocate()
        vadLeftover.deinitialize(count: 1)
        vadLeftover.deallocate()
        pendingPartials.deinitialize(count: 1)
        pendingPartials.deallocate()
        allAudio.deinitialize(count: 1)
        allAudio.deallocate()
    }

    func appendAudio(_ samples: [Float]) {
        lock.lock()
        buffer.pointee.append(contentsOf: samples)
        lock.unlock()
    }

    private func appendDebugAudio(_ samples: [Float]) {
        lock.lock()
        allAudio.pointee.append(contentsOf: samples)
        lock.unlock()
    }

    func saveDebugAudio() {
        lock.lock()
        let audio = allAudio.pointee
        lock.unlock()
        guard !audio.isEmpty else { return }

        let path = "/tmp/dictate-debug.wav"
        var header = Data()
        let dataSize = UInt32(audio.count * MemoryLayout<Float>.size)
        let fileSize = UInt32(36 + dataSize)
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(3).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(64000).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(32).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var fileData = header
        audio.withUnsafeBufferPointer { samples in
            guard let address = samples.baseAddress else { return }
            let bytes = UnsafeRawPointer(address).assumingMemoryBound(to: UInt8.self)
            fileData.append(UnsafeBufferPointer(start: bytes, count: samples.count * MemoryLayout<Float>.size))
        }
        try? fileData.write(to: URL(fileURLWithPath: path))
        dlog("Saved \(audio.count) samples (\(String(format: "%.1f", Float(audio.count) / 16000))s) to \(path)")
    }

    var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.pointee.count
    }

    func enqueuePartials(_ partials: [StreamingTranscript]) {
        guard !partials.isEmpty else { return }
        lock.lock()
        pendingPartials.pointee.append(contentsOf: partials)
        lock.unlock()
    }

    func takePendingPartials() -> [StreamingTranscript] {
        lock.lock()
        defer { lock.unlock() }
        let partials = pendingPartials.pointee
        pendingPartials.pointee.removeAll(keepingCapacity: true)
        return partials
    }

    func processBuffered() -> (
        partials: [StreamingTranscript],
        speaking: Bool
    ) {
        lock.lock()
        let chunk = buffer.pointee
        buffer.pointee.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !chunk.isEmpty else { return ([], speechActive) }

        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))

        // Carry leftovers across calls so Silero sees a continuous sequence of
        // its required 512-sample chunks.
        lock.lock()
        var vadInput = vadLeftover.pointee
        vadInput.append(contentsOf: chunk)
        lock.unlock()
        var offset = 0
        while offset + 512 <= vadInput.count {
            let probability = vad.processChunk(Array(vadInput[offset..<offset + 512]))
            if probability >= 0.5 {
                speechActive = true
                silenceCount = 0
                hasPendingUtterance = true
            } else {
                silenceCount += 1
                if silenceCount >= 15 { speechActive = false }
            }
            offset += 512
        }
        let leftover = Array(vadInput[offset...])
        lock.lock()
        vadLeftover.pointee = leftover
        lock.unlock()

        lastRms = rms
        do {
            appendDebugAudio(chunk)
            var partials = try sessions.pushAudio(chunk)

            // A future backend may provide native final callbacks.
            if partials.contains(where: { $0.isFinal }) {
                hasPendingUtterance = false
            }

            // Nemotron has no EOU head, so sustained VAD silence is the
            // automatic utterance boundary.
            if hasPendingUtterance
                && !speechActive
                && silenceCount >= forceFinalizeSilentChunks
            {
                let boundary = sessions.finalize(
                    reason: .vadFinalization,
                    recreateSession: true
                )
                partials.append(contentsOf: boundary.transcripts)
                logBoundaryResult(boundary, reason: .vadFinalization)
                hasPendingUtterance = false
            }

            logRawPartials(partials, source: "stream")

            dlog("asr: rms=\(String(format: "%.4f", rms)) vad=\(speechActive) partials=\(partials.count)")
            if !partials.isEmpty {
                dlog("ASR: \(partials.count) partials - '\(partials.map(\.text).joined(separator: ", "))'")
            }
            return (partials, speechActive)
        } catch {
            dlog("ASR error: \(error)")
            return ([], speechActive)
        }
    }

    func finalize() -> [StreamingTranscript] {
        dlog(
            "[\(logTimestamp())] \(sessions.backendName) explicit-finalize begin "
                + "buffered=\(bufferedCount) pending-callbacks=\(pendingPartialCount)"
        )
        let (bufferedPartials, _) = processBuffered()
        let boundary = sessions.finalize(
            reason: .explicitStopFinalization,
            recreateSession: false
        )
        logBoundaryResult(boundary, reason: .explicitStopFinalization)
        logRawPartials(boundary.transcripts, source: "explicit-finalize")
        return bufferedPartials + boundary.transcripts
    }

    private var pendingPartialCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingPartials.pointee.count
    }

    private func logRawPartials(
        _ partials: [StreamingTranscript],
        source: String
    ) {
        for partial in partials {
            dlog(
                "[\(logTimestamp())] \(sessions.backendName) raw source=\(source) segment=\(partial.segmentIndex) "
                    + "final=\(partial.isFinal) boundary=\(partial.boundaryReason?.rawValue ?? "none") "
                    + "text=\(String(reflecting: partial.text))"
            )
        }
    }

    private func logBoundaryResult(
        _ result: StreamingSessionBoundaryResult,
        reason: BoundaryReason
    ) {
        let segment = result.segmentIndex ?? sessions.segmentIndex
        dlog("[\(logTimestamp())] \(sessions.backendName) boundary reason=\(reason.rawValue) segment=\(segment)")
        if reason == .vadFinalization, result.recreationError == nil {
            dlog("[\(logTimestamp())] \(sessions.backendName) session-recreated next-segment=\(sessions.segmentIndex)")
        }
        if let error = result.finalizationError {
            dlog("[\(logTimestamp())] \(sessions.backendName) finalize-error reason=\(reason.rawValue) error=\(String(reflecting: String(describing: error)))")
        }
        if let error = result.recreationError {
            dlog("[\(logTimestamp())] \(sessions.backendName) recreation-error error=\(String(reflecting: String(describing: error)))")
        }
    }
}

@MainActor
final class DictateViewModel: ObservableObject {
    /// Recognition latency is part of the compiled CoreML encoder bundle.
    /// Add another case only when a Speech Swift-compatible bundle for that
    /// native streaming geometry is available; changing caller chunk sizes
    /// does not retune the encoder's lookahead.
    private enum RecognitionMode {
        case balanced320ms

        var modelID: String {
            switch self {
            case .balanced320ms:
                NemotronStreamingASRModel.defaultModelId
            }
        }
    }

    @Published var sentences: [String] = []
    @Published var partialText = ""
    @Published var isRecording = false
    @Published var isLoading = false
    @Published var loadingStatus = ""
    @Published var errorMessage: String?
    @Published var isSpeechActive = false

    private var model: NemotronStreamingASRModel?
    private var vad: SileroVADModel?
    private var processor: ASRProcessor?
    private var globalHotKey: GlobalHotKey?
    private let recorder = StreamingRecorder()
    private let commitClock = ContinuousClock()
    private let processQueue = DispatchQueue(label: "dictate.asr", qos: .userInteractive)
    private var processTimer: DispatchSourceTimer?
    private var partialCommitTracker = PartialCommitTracker()
    private var isStopping = false
    // Change this to `.toggle` to restore press-on/press-off hotkey behavior.
    private let hotKeyActivationMode: GlobalHotKey.ActivationMode = .pushToTalk
    // Keep language policy at the app/backend boundary so it can become a
    // preference without changing the processor lifecycle.
    private let transcriptionLanguage: String? = "en-US"
    private let recognitionMode: RecognitionMode = .balanced320ms

    var modelLoaded: Bool { model != nil && vad != nil }

    var wordCount: Int {
        let allText = sentences.joined(separator: " ")
            + (partialText.isEmpty ? "" : " " + partialText)
        return allText.split(separator: " ").count
    }

    var fullText: String {
        let committed = sentences.joined(separator: "\n")
        if committed.isEmpty { return partialText }
        if partialText.isEmpty { return committed }
        return committed + "\n" + partialText
    }

    init() {
        globalHotKey = GlobalHotKey { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.handleHotKey(phase)
            }
        }
        Task { await loadModels() }
    }

    func loadModels() async {
        guard model == nil else { return }
        isLoading = true
        loadingStatus = "Downloading ASR model..."
        let recognitionModelID = recognitionMode.modelID

        do {
            let loaded = try await Task.detached {
                let loaded = try await NemotronStreamingASRModel.fromPretrained(
                    modelId: recognitionModelID
                ) { [weak self] progress, status in
                    DispatchQueue.main.async {
                        let percent = Int(progress * 100)
                        self?.loadingStatus = status.isEmpty
                            ? "Downloading... \(percent)%"
                            : "\(status) (\(percent)%)"
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.loadingStatus = "Warming up..."
                }
                try loaded.warmUp()
                return loaded
            }.value
            model = loaded

            loadingStatus = "Loading VAD..."
            vad = try await Task.detached {
                try await SileroVADModel.fromPretrained(engine: .coreml)
            }.value
            loadingStatus = ""
            dlog(
                "Models loaded (Nemotron ASR chunk=\(loaded.config.streaming.chunkMs)ms "
                    + "language=\(transcriptionLanguage ?? "auto") + VAD)"
            )
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
            loadingStatus = ""
        }
        isLoading = false
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func handleHotKey(_ phase: GlobalHotKey.Phase) {
        switch (hotKeyActivationMode, phase) {
        case (.pushToTalk, .pressed):
            if !isRecording { startRecording() }
        case (.pushToTalk, .released):
            if isRecording { stopRecording() }
        case (.toggle, .pressed):
            toggleRecording()
        case (.toggle, .released):
            break
        }
    }

    func startRecording() {
        dlog("startRecording called, model=\(model != nil), vad=\(vad != nil)")
        guard !isStopping else {
            dlog("Recorder is still draining the previous stop")
            return
        }
        guard let model, let vad else {
            dlog("Models are not ready")
            return
        }
        guard requestAccessibilityPermission() else {
            errorMessage = "Enable DictateNemotron in System Settings > Privacy & Security > Accessibility, then hold Right Option again."
            return
        }
        errorMessage = nil
        partialText = ""
        sentences.removeAll()
        partialCommitTracker.reset()

        do {
            let backend = StreamingASRBackend.nemotron(
                model: model,
                language: transcriptionLanguage
            )
            let processor = try processQueue.sync {
                try ASRProcessor(backend: backend, vad: vad)
            }
            self.processor = processor

            recorder.start { [processor] chunk in
                processor.appendAudio(chunk)
            }

            let timer = DispatchSource.makeTimerSource(queue: processQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(300))
            timer.setEventHandler { [weak self, processor] in
                let (partials, speaking) = processor.processBuffered()
                processor.enqueuePartials(partials)

                // MenuBarExtra can run the main loop in modes that starve a
                // normal DispatchQueue.main update while its popover is open.
                let weakSelf = self
                RunLoop.main.perform(inModes: [.common, .default, .eventTracking, .modalPanel]) {
                    MainActor.assumeIsolated {
                        guard let self = weakSelf,
                              self.isRecording,
                              self.processor === processor else { return }
                        let partials = processor.takePendingPartials()
                        self.isSpeechActive = speaking
                        self.handlePartialTranscripts(partials)
                    }
                }
            }
            timer.resume()
            processTimer = timer
            isRecording = true
            dlog("Recording started")
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard !isStopping else { return }
        isStopping = true
        processTimer?.cancel()
        processTimer = nil
        isRecording = false
        isSpeechActive = false

        guard let processor else {
            recorder.stop { [weak self] in
                self?.isStopping = false
            }
            return
        }

        recorder.stop { [weak self, processor] in
            guard let self else { return }
            // Wait behind any in-flight timer tick before draining and
            // finalizing the session so no captured audio is lost.
            let finalPartials = processQueue.sync {
                let partials = processor.takePendingPartials() + processor.finalize()
                processor.saveDebugAudio()
                return partials
            }
            if self.processor === processor {
                self.processor = nil
            }
            handlePartialTranscripts(finalPartials)
            forceFinalizeCurrentUtterance(reason: "explicit-stop")
            partialText = ""
            isStopping = false
        }
    }

    private func handlePartialTranscripts(
        _ partials: [StreamingTranscript]
    ) {
        for (index, partial) in partials.enumerated() {
            let hasNewerCallbackForSegment = partials.dropFirst(index + 1).contains {
                $0.segmentIndex == partial.segmentIndex
            }
            handlePartialTranscript(
                partial,
                allowOrdinaryInsertion: !hasNewerCallbackForSegment
            )
        }
    }

    private func handlePartialTranscript(
        _ partial: StreamingTranscript,
        allowOrdinaryInsertion: Bool
    ) {
        let now = commitClock.now
        let observation = partialCommitTracker.observe(
            partial.text,
            at: now,
            forceFinalization: partial.isFinal
        )
        let ages = partialCommitTracker.stableTokenAges(at: now)
        dlog(
            "[\(logTimestamp())] PARTIAL segment=\(partial.segmentIndex) final=\(partial.isFinal) "
                + "boundary=\(partial.boundaryReason?.rawValue ?? "none") behavior=\(observation.callbackBehavior.rawValue) "
                + "alignment=\(observation.alignmentPoint) stable=[\(ages)] raw=\(String(reflecting: partial.text))"
        )
        if let divergence = observation.divergence {
            dlog("[\(logTimestamp())] PARTIAL committed-prefix-divergence \(divergence)")
        }

        var insertionSucceeded = true
        if let candidate = observation.candidate,
           partial.isFinal || allowOrdinaryInsertion
        {
            insertionSucceeded = insertCommittedText(
                candidate.renderedText,
                appendTrailingSpace: partial.isFinal
            )
            if insertionSucceeded {
                partialCommitTracker.didInsert(candidate)
                dlog(
                    "[\(logTimestamp())] PARTIAL committed delta=\(String(reflecting: candidate.renderedText)) "
                        + "words=\(candidate.tokenCount) final=\(partial.isFinal)"
                )
            } else {
                dlog("[\(logTimestamp())] PARTIAL insertion-failed delta=\(String(reflecting: candidate.renderedText))")
                errorMessage = "Could not insert dictated text into the active application."
            }
        } else if observation.candidate != nil {
            dlog("[\(logTimestamp())] PARTIAL deferred eligible delta to newer segment callback")
        }

        if partial.isFinal {
            if !partial.text.isEmpty {
                sentences.append(partial.text)
            }
            partialText = ""
            if insertionSucceeded {
                dlog("[\(logTimestamp())] PARTIAL utterance-reset segment=\(partial.segmentIndex)")
                partialCommitTracker.reset()
            }
        } else if !partial.text.isEmpty {
            partialText = partial.text
        }
    }

    private func forceFinalizeCurrentUtterance(reason: String) {
        guard !partialCommitTracker.state.latestPartial.isEmpty else {
            partialCommitTracker.reset()
            return
        }

        let now = commitClock.now
        let observation = partialCommitTracker.observe(
            partialCommitTracker.state.latestPartial,
            at: now,
            forceFinalization: true
        )
        guard let candidate = observation.candidate else {
            dlog("[\(logTimestamp())] PARTIAL force-finalize reason=\(reason) no-uncommitted-text")
            partialCommitTracker.reset()
            return
        }

        if insertCommittedText(candidate.renderedText, appendTrailingSpace: true) {
            partialCommitTracker.didInsert(candidate)
            dlog(
                "[\(logTimestamp())] PARTIAL force-finalize reason=\(reason) "
                    + "alignment=\(observation.alignmentPoint) delta=\(String(reflecting: candidate.renderedText))"
            )
            partialCommitTracker.reset()
        } else {
            dlog("[\(logTimestamp())] PARTIAL force-finalize insertion-failed reason=\(reason)")
            errorMessage = "Could not insert dictated text into the active application."
        }
    }

    private func insertCommittedText(_ text: String, appendTrailingSpace: Bool) -> Bool {
        guard !text.isEmpty else { return true }
        let payload: String
        if appendTrailingSpace, text.last.map({ !$0.isWhitespace }) == true {
            payload = text + " "
        } else {
            payload = text
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }

        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(payload, forType: .string) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func requestAccessibilityPermission() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
    }

    func clearText() {
        sentences.removeAll()
        partialText = ""
    }
}
