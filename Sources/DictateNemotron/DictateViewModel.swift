import AppKit
import Foundation
import ParakeetStreamingASR
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

/// Owns the mutable streaming state used by the off-main-thread audio pipeline.
final class ASRProcessor: @unchecked Sendable {
    let session: StreamingSession
    private let vad: SileroVADModel
    private let lock = NSLock()
    private let buffer = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    private let vadLeftover = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    private let pendingPartials = UnsafeMutablePointer<[ParakeetStreamingASRModel.PartialTranscript]>.allocate(capacity: 1)
    private let allAudio = UnsafeMutablePointer<[Float]>.allocate(capacity: 1)
    nonisolated(unsafe) var speechActive = false
    nonisolated(unsafe) var silenceCount = 0
    nonisolated(unsafe) var hasPendingUtterance = false
    nonisolated(unsafe) var lastRms: Float = 0

    // 30 VAD chunks at 512 samples and 16 kHz is about 960 ms of silence.
    private let forceFinalizeSilentChunks = 30

    init(session: StreamingSession, vad: SileroVADModel) {
        self.session = session
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

    func enqueuePartials(_ partials: [ParakeetStreamingASRModel.PartialTranscript]) {
        guard !partials.isEmpty else { return }
        lock.lock()
        pendingPartials.pointee.append(contentsOf: partials)
        lock.unlock()
    }

    func takePendingPartials() -> [ParakeetStreamingASRModel.PartialTranscript] {
        lock.lock()
        defer { lock.unlock() }
        let partials = pendingPartials.pointee
        pendingPartials.pointee.removeAll(keepingCapacity: true)
        return partials
    }

    func processBuffered() -> (
        partials: [ParakeetStreamingASRModel.PartialTranscript],
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
            var partials = try session.pushAudio(chunk)

            // Do not force-finalize an utterance that the model's EOU head has
            // already completed.
            if partials.contains(where: { $0.isFinal }) {
                hasPendingUtterance = false
            }

            // Room noise can keep the model EOU debounce alive. Silero's
            // sustained-silence signal provides a more reliable cutoff.
            if hasPendingUtterance
                && !speechActive
                && silenceCount >= forceFinalizeSilentChunks
            {
                if let forced = session.forceEndOfUtterance() {
                    dlog("FORCE-FINAL via VAD: '\(forced.text)'")
                    partials.append(forced)
                }
                hasPendingUtterance = false
            }

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

    func finalize() -> [ParakeetStreamingASRModel.PartialTranscript] {
        let (bufferedPartials, _) = processBuffered()
        do {
            // Advance delayed encoder emissions so stopping does not truncate
            // the final words instead of waiting for real microphone post-roll.
            let flushed = try session.pushAudio([Float](repeating: 0, count: 8_000))
            return bufferedPartials + flushed + (try session.finalize())
        } catch {
            return bufferedPartials
        }
    }
}

@MainActor
final class DictateViewModel: ObservableObject {
    @Published var sentences: [String] = []
    @Published var partialText = ""
    @Published var isRecording = false
    @Published var isLoading = false
    @Published var loadingStatus = ""
    @Published var errorMessage: String?
    @Published var isSpeechActive = false

    private var model: ParakeetStreamingASRModel?
    private var vad: SileroVADModel?
    private var processor: ASRProcessor?
    private var globalHotKey: GlobalHotKey?
    private let recorder = StreamingRecorder()
    private let processQueue = DispatchQueue(label: "dictate.asr", qos: .userInteractive)
    private var processTimer: DispatchSourceTimer?

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
        do {
            globalHotKey = try GlobalHotKey { [weak self] in
                Task { @MainActor [weak self] in
                    self?.toggleRecording()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await loadModels() }
    }

    func loadModels() async {
        guard model == nil else { return }
        isLoading = true
        loadingStatus = "Downloading ASR model..."

        do {
            let loaded = try await Task.detached {
                try await ParakeetStreamingASRModel.fromPretrained { [weak self] progress, status in
                    DispatchQueue.main.async {
                        let percent = Int(progress * 100)
                        self?.loadingStatus = status.isEmpty
                            ? "Downloading... \(percent)%"
                            : "\(status) (\(percent)%)"
                    }
                }
            }.value
            loadingStatus = "Warming up..."
            try loaded.warmUp()
            model = loaded

            loadingStatus = "Loading VAD..."
            vad = try await Task.detached {
                try await SileroVADModel.fromPretrained(engine: .coreml)
            }.value
            loadingStatus = ""
            dlog("Models loaded (ASR + VAD)")
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

    func startRecording() {
        dlog("startRecording called, model=\(model != nil), vad=\(vad != nil)")
        guard let model, let vad else {
            dlog("Models are not ready")
            return
        }
        guard requestAccessibilityPermission() else {
            errorMessage = "Enable DictateNemotron in System Settings > Privacy & Security > Accessibility, then press Cmd+Shift+D again."
            return
        }
        errorMessage = nil
        partialText = ""
        sentences.removeAll()

        do {
            let session = try model.createSession()
            let processor = ASRProcessor(session: session, vad: vad)
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
                        for partial in partials {
                            if partial.isFinal && !partial.text.isEmpty {
                                self.sentences.append(partial.text)
                                self.partialText = ""
                                self.pasteFinalizedText(partial.text)
                            } else if !partial.text.isEmpty {
                                self.partialText = partial.text
                            }
                        }
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
        processTimer?.cancel()
        processTimer = nil
        recorder.stop()
        isRecording = false
        isSpeechActive = false

        if let processor {
            // Wait behind any in-flight timer tick before draining and
            // finalizing the session so no captured audio is lost.
            let finalPartials = processQueue.sync {
                let partials = processor.takePendingPartials() + processor.finalize()
                processor.saveDebugAudio()
                return partials
            }
            self.processor = nil
            for partial in finalPartials where partial.isFinal && !partial.text.isEmpty {
                sentences.append(partial.text)
                pasteFinalizedText(partial.text)
            }
        }
        processor = nil
        partialText = ""
    }

    private func pasteFinalizedText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text + " ", forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
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
