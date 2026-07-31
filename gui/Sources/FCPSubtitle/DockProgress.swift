import AppKit

/// Draws a progress bar over the app icon in the Dock while processing,
/// plus a badge with the number of queued files.
@MainActor
enum DockProgress {
    private static var progressView: DockProgressView?

    static func update(fraction: Double?, badge: String?) {
        let dockTile = NSApp.dockTile
        dockTile.badgeLabel = badge

        if let fraction {
            if progressView == nil {
                let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
                dockTile.contentView = view
                progressView = view
            }
            progressView?.fraction = fraction
        } else if progressView != nil {
            dockTile.contentView = nil
            progressView = nil
        }
        dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)

        let barRect = NSRect(
            x: bounds.width * 0.14, y: bounds.height * 0.09,
            width: bounds.width * 0.72, height: bounds.height * 0.10)
        let track = NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2)
        NSColor.white.withAlphaComponent(0.9).setFill()
        track.fill()

        var fillRect = barRect.insetBy(dx: 1.5, dy: 1.5)
        fillRect.size.width *= CGFloat(max(0, min(fraction, 1)))
        let fill = NSBezierPath(
            roundedRect: fillRect, xRadius: fillRect.height / 2, yRadius: fillRect.height / 2)
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
