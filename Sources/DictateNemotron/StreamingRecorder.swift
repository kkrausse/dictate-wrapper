import AVFoundation
import Observation

/// Captures mic audio and streams 16kHz Float32 chunks to a callback.
@Observable
final class StreamingRecorder {
    private struct StopRequest {
        let id: Int
        let completion: () -> Void
        let requestedAt: Date
        let minimumCallback: Int
        let sampleCount: Int
    }

    private(set) var isRecording = false

    private var audioEngine: AVAudioEngine?
    private var onChunk: (([Float]) -> Void)?
    private var totalSamples = 0
    private let callbackLock = NSLock()
    private var callbackCount = 0
    private var nextStopID = 0
    private var stopRequest: StopRequest?
    private var latestInputFrames: AVAudioFrameCount = 0
    private var latestOutputSamples = 0

    /// Start recording and call `onChunk` with 16kHz mono Float32 samples.
    func start(onChunk: @escaping ([Float]) -> Void) {
        callbackLock.lock()
        self.onChunk = onChunk
        stopRequest = nil
        callbackCount = 0
        totalSamples = 0
        callbackLock.unlock()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            self.callbackLock.lock()
            self.callbackCount += 1
            let callbackIndex = self.callbackCount
            self.callbackLock.unlock()

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }

            guard let channelData = convertedBuffer.floatChannelData else { return }
            let count = Int(convertedBuffer.frameLength)
            let data = Array(UnsafeBufferPointer(start: channelData[0], count: count))

            self.callbackLock.lock()
            self.onChunk?(data)
            self.totalSamples += data.count
            self.latestInputFrames = buffer.frameLength
            self.latestOutputSamples = data.count
            let completedStopID = self.stopRequest.flatMap {
                callbackIndex >= $0.minimumCallback ? $0.id : nil
            }
            self.callbackLock.unlock()

            if let completedStopID {
                DispatchQueue.main.async { [weak self] in
                    self?.finishStop(id: completedStopID, trigger: "audio-callback")
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    /// Accepts the next hardware callback before stopping so device-buffered
    /// audio reaches the ASR pipeline. Completion runs on the main queue.
    func stop(completion: @escaping () -> Void) {
        callbackLock.lock()
        guard audioEngine != nil else {
            callbackLock.unlock()
            completion()
            return
        }
        guard stopRequest == nil else {
            callbackLock.unlock()
            return
        }
        nextStopID += 1
        let stopID = nextStopID
        stopRequest = StopRequest(
            id: stopID,
            completion: completion,
            requestedAt: Date(),
            minimumCallback: callbackCount + 1,
            sampleCount: totalSamples
        )
        callbackLock.unlock()

        // Do not leave stop hung if the input device ceases callbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finishStop(id: stopID, trigger: "timeout")
        }
    }

    private func finishStop(id: Int, trigger: String) {
        callbackLock.lock()
        guard let request = stopRequest, request.id == id else {
            callbackLock.unlock()
            return
        }
        stopRequest = nil
        callbackLock.unlock()

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Wait for a callback already inside the tap before clearing its sink.
        callbackLock.lock()
        onChunk = nil
        let waited = Date().timeIntervalSince(request.requestedAt)
        let drainedSampleCount = totalSamples - request.sampleCount
        let inputFrames = latestInputFrames
        let outputSamples = latestOutputSamples
        let capturedSamples = totalSamples
        callbackLock.unlock()

        isRecording = false
        dlog(
            "Recorder stop drain: trigger=\(trigger) waited=\(String(format: "%.3f", waited))s "
                + "drained=\(drainedSampleCount) total=\(capturedSamples) "
                + "callback=\(inputFrames)->\(outputSamples)"
        )
        request.completion()
    }
}
