import AVFoundation

enum AudioBufferBridge {
    static func make16KMonoBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.floatChannelData
        else {
            throw AudioBufferBridgeError.couldNotAllocate
        }

        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

enum AudioBufferBridgeError: LocalizedError {
    case couldNotAllocate

    var errorDescription: String? {
        "Could not allocate a 16 kHz mono audio buffer."
    }
}
