import AVFoundation
import Foundation

/// Display size and frame rate of a video file's first video track, so the
/// exported FCPXML timeline can match the footage instead of a manual setting.
public struct VideoFormat: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double

    public init(width: Int, height: Int, frameRate: Double) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// nil for audio-only files or when the video track can't be read.
    public static func probe(url: URL) async -> VideoFormat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let properties = try? await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate)
        else { return nil }
        let (size, transform, rate) = properties
        // Phones store portrait video as landscape pixels plus a 90° rotation.
        let display = size.applying(transform)
        let width = Int(abs(display.width).rounded())
        let height = Int(abs(display.height).rounded())
        guard width > 0, height > 0, rate > 0 else { return nil }
        return VideoFormat(width: width, height: height, frameRate: Double(rate))
    }
}
