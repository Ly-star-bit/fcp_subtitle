import AVFoundation
import Foundation

/// Decodes any audio/video file AVFoundation can read (wav/m4a/mp3/aac/mp4/mov...)
/// into 16kHz mono Float32 samples — the input format sherpa-onnx expects.
/// Replaces the Python version's ffmpeg dependency.
public enum AudioDecoder {
    public static let sampleRate = 16000

    /// `onProgress` receives 0...1 based on decoded presentation time vs asset duration.
    /// `shouldCancel` is polled per decoded buffer; returning true aborts with CancellationError.
    public static func decode(
        url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let totalSeconds = try await CMTimeGetSeconds(asset.load(.duration))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw NSError(
                domain: "FCPSubtitle", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "文件中没有音频轨道: \(url.lastPathComponent)"])
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error
                ?? NSError(
                    domain: "FCPSubtitle", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取音频: \(url.lastPathComponent)"])
        }

        var samples: [Float] = []
        var progress = ProgressThrottle(onProgress)
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if shouldCancel?() == true {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let count = length / MemoryLayout<Float>.size
            let oldEnd = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBufferPointer { buf in
                _ = CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: length, destination: buf.baseAddress! + oldEnd)
            }
            if totalSeconds.isFinite, totalSeconds > 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                progress.report(CMTimeGetSeconds(pts) / totalSeconds)
            }
        }

        if reader.status == .failed {
            throw reader.error
                ?? NSError(
                    domain: "FCPSubtitle", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "音频解码失败: \(url.lastPathComponent)"])
        }
        return samples
    }

    /// Downsample to `bins` max-abs peaks (0...1) for waveform display.
    public static func waveformPeaks(samples: [Float], bins: Int = 1200) -> [Float] {
        guard !samples.isEmpty, bins > 0 else { return [] }
        let binSize = max(samples.count / bins, 1)
        var peaks: [Float] = []
        peaks.reserveCapacity(bins)
        var index = 0
        while index < samples.count {
            let end = min(index + binSize, samples.count)
            var peak: Float = 0
            for i in index..<end {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
            peaks.append(min(peak, 1))
            index = end
        }
        return peaks
    }
}
