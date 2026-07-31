import AVFoundation
import FCPSubtitleCore
import Foundation

/// Plays the audio range behind a single subtitle line for proofreading.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published var playingID: UUID?

    private var player: AVPlayer?
    private var boundaryObserver: Any?

    func toggle(url: URL, segment: SubtitleSegment) {
        if playingID == segment.id {
            stop()
            return
        }
        stop()

        let player = AVPlayer(url: url)
        self.player = player
        playingID = segment.id

        let start = CMTime(seconds: segment.start, preferredTimescale: 600)
        let end = CMTime(seconds: segment.end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)], queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    func stop() {
        if let observer = boundaryObserver {
            player?.removeTimeObserver(observer)
            boundaryObserver = nil
        }
        player?.pause()
        player = nil
        playingID = nil
    }
}
