import Foundation

/// Forwards progress only once it has advanced by `step`, plus the final 1.0.
///
/// The pipeline produces a progress value per 32 ms VAD window — 18,677 per
/// 10 minutes of audio — and the GUI turned each into a main-thread hop that
/// re-rendered the queue and redrew the Dock tile. At the default step a file
/// of any length reports about 200 updates.
struct ProgressThrottle {
    private let callback: (@Sendable (Double) -> Void)?
    private let step: Double
    private var last = -Double.infinity

    init(_ callback: (@Sendable (Double) -> Void)?, step: Double = 0.005) {
        self.callback = callback
        self.step = step
    }

    mutating func report(_ fraction: Double) {
        guard let callback else { return }
        let value = min(max(fraction, 0), 1)
        guard value - last >= step || (value == 1 && last < 1) else { return }
        last = value
        callback(value)
    }
}
