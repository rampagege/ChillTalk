import AppKit
import SwiftUI

/// ChillTalk's mark: a circle with a gentle wave. Drawn in code as template images so the
/// menu bar tints it for light/dark mode automatically.
enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 18)
    private struct Key: Hashable {
        let state: RecordingState
        let updateWaiting: Bool
    }
    private static var cache: [Key: NSImage] = [:]

    /// `updateWaiting` adds a dot at the top right.
    static func image(for state: RecordingState, updateWaiting: Bool = false) -> NSImage {
        let key = Key(state: state, updateWaiting: updateWaiting)
        if let cached = cache[key] { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            if updateWaiting { drawDot() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ChillTalk \(state.displayName)"
            + (updateWaiting ? " · " + String(localized: "有新版本") : "")
        cache[key] = image
        return image
    }

    private static func drawDot() {
        let dot = NSRect(x: 12, y: 12, width: 6, height: 6)
        // Cut a gap around the dot so it reads as separate from the circle.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: dot).fill()
    }

    private static func draw(_ state: RecordingState) {
        let circleRect = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
        let circle = NSBezierPath(ovalIn: circleRect)
        circle.lineWidth = 1.5

        switch state {
        case .idle:
            circle.stroke()
            wave(in: circleRect).stroke()
        case .recording:
            // Solid disc with the wave cut out.
            circle.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            wave(in: circleRect).stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .processing:
            circle.stroke()
            for i in 0..<3 {
                let d: CGFloat = 1.9
                let x = circleRect.midX - (3 * d + 2 * 1.5) / 2 + CGFloat(i) * (d + 1.5)
                NSBezierPath(ovalIn: NSRect(x: x, y: circleRect.midY - d / 2, width: d, height: d)).fill()
            }
        case .error:
            circle.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: circleRect.midX - 0.85, y: 7.6, width: 1.7, height: 5.6),
                                   xRadius: 0.85, yRadius: 0.85)
            bar.fill()
            NSBezierPath(ovalIn: NSRect(x: circleRect.midX - 1, y: 4.3, width: 2, height: 2)).fill()
        }
    }

    private static func wave(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let left = rect.minX + rect.width * 0.18, right = rect.maxX - rect.width * 0.18
        let mid = rect.midX, y = rect.midY, amp = rect.height * 0.24
        path.move(to: NSPoint(x: left, y: y))
        path.curve(to: NSPoint(x: mid, y: y),
                   controlPoint1: NSPoint(x: left + (mid - left) * 0.3, y: y + amp),
                   controlPoint2: NSPoint(x: mid - (mid - left) * 0.3, y: y + amp))
        path.curve(to: NSPoint(x: right, y: y),
                   controlPoint1: NSPoint(x: mid + (right - mid) * 0.3, y: y - amp),
                   controlPoint2: NSPoint(x: right - (right - mid) * 0.3, y: y - amp))
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        return path
    }
}

/// The same wave as a SwiftUI shape, for the settings sidebar logo.
struct ChillWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX, right = rect.maxX, mid = rect.midX, y = rect.midY
        let amp = rect.height / 2
        path.move(to: CGPoint(x: left, y: y))
        path.addCurve(to: CGPoint(x: mid, y: y),
                      control1: CGPoint(x: left + (mid - left) * 0.3, y: y - amp),
                      control2: CGPoint(x: mid - (mid - left) * 0.3, y: y - amp))
        path.addCurve(to: CGPoint(x: right, y: y),
                      control1: CGPoint(x: mid + (right - mid) * 0.3, y: y + amp),
                      control2: CGPoint(x: right - (right - mid) * 0.3, y: y + amp))
        return path
    }
}
