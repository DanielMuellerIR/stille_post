import AVFAudio
import Foundation
import StillePostClientCore

actor LocalPCMDecoder {
    func decode(_ recording: Recording) throws -> [Float] {
        guard recording.url.isFileURL else { throw ClientFailure.noAudio }
        let attributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else { throw ClientFailure.noAudio }
        guard size.intValue <= BridgeClient.maxAudioBytes else { throw ClientFailure.recordingTooLarge }
        do {
            let file = try AVAudioFile(forReading: recording.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.channelCount == 1,
                  file.processingFormat.sampleRate == Double(OfflineSpeech.sampleRate),
                  file.length > 0 else { throw ClientFailure.noAudio }
            guard file.length <= OfflineSpeech.maxSamples else { throw ClientFailure.recordingTooLarge }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000) else {
                throw ClientFailure.noAudio
            }
            var samples: [Float] = []; samples.reserveCapacity(Int(file.length))
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(file.length - file.framePosition)))
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw ClientFailure.noAudio }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                guard samples.count <= OfflineSpeech.maxSamples else { throw ClientFailure.recordingTooLarge }
            }
            return samples
        } catch is CancellationError { throw CancellationError() }
        catch let failure as ClientFailure { throw failure }
        catch { throw ClientFailure.noAudio }
    }
}
