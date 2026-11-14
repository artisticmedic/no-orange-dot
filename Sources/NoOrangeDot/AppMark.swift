import AppKit

/// The menu bar icon. Template images on an 18 pt canvas with 1.5 pt strokes and round caps, to sit
/// with SF Symbols at menu bar size. Each style draws four states.
enum AppMark {
    enum Style: String, CaseIterable { case eclipse, ring, halo, capsule, nodot, symbol }
    enum State: String, CaseIterable { case idle, live, muted, recording }

    static func image(_ style: Style, _ state: State, scale: CGFloat = 1) -> NSImage {
        if style == .symbol {
            let name = state == .muted ? "mic.slash.fill" : state == .recording ? "record.circle.fill" : state == .live ? "mic.fill" : "mic"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 14 * scale, weight: .regular))!
            img.isTemplate = true
            return img
        }
        let img = NSImage(size: NSSize(width: 18 * scale, height: 18 * scale), flipped: false) { _ in
            let t = NSAffineTransform(); t.scale(by: scale); t.concat()
            NSColor.black.set()
            draw(style, state)
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func stroke(_ p: NSBezierPath, _ w: CGFloat = 1.5) {
        p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    }
    private static func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    private static func line(_ a: NSPoint, _ b: NSPoint) -> NSBezierPath {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); return p
    }
    /// A slash with a clear gap either side, so it reads over whatever is beneath it.
    private static func slash() {
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        stroke(line(NSPoint(x: 3.2, y: 14.8), NSPoint(x: 14.8, y: 3.2)), 4)
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        stroke(line(NSPoint(x: 3.2, y: 14.8), NSPoint(x: 14.8, y: 3.2)))
    }
    /// A microphone: capsule, cradle, stem and foot. `cx` is its centre line.
    private static func mic(cx: CGFloat, filled: Bool, size: CGFloat = 1, cy: CGFloat = 9) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: cx + x * size, y: cy + y * size) }
        let capsule = NSBezierPath(roundedRect: NSRect(x: cx - 2.4 * size, y: cy - 0.8 * size, width: 4.8 * size, height: 7.6 * size), xRadius: 2.4 * size, yRadius: 2.4 * size)
        if filled { capsule.fill() }
        stroke(capsule, 1.5 * min(size, 1))
        let cradle = NSBezierPath()
        cradle.appendArc(withCenter: pt(0, 1.6), radius: 4.6 * size, startAngle: 180, endAngle: 360)
        stroke(cradle, 1.5 * min(size, 1))
        stroke(line(pt(0, -3), pt(0, -5.6)), 1.5 * min(size, 1))
        stroke(line(pt(-2.6, -5.6), pt(2.6, -5.6)), 1.5 * min(size, 1))
    }

    private static func draw(_ style: Style, _ state: State) {
        let c = NSPoint(x: 9, y: 9)
        switch style {
        case .eclipse: // the app icon's ring: breaking into pixels while the mic is closed, whole while it is open
            func broken() {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: 6, startAngle: 90, endAngle: 360)
                stroke(arc)
                NSBezierPath(rect: NSRect(x: 12, y: 14, width: 1.5, height: 1.5)).fill()
                NSBezierPath(rect: NSRect(x: 14.5, y: 11.5, width: 1.5, height: 1.5)).fill()
            }
            switch state {
            case .idle: broken()
            case .live: circle(c, 5.75).fill()
            case .muted: broken(); slash()
            case .recording: stroke(circle(c, 6.75)); circle(c, 3.1).fill()
            }
        case .ring: // the dot itself: empty while the mic is closed, solid while it is open
            switch state {
            case .idle: stroke(circle(c, 5.25))
            case .live: circle(c, 6).fill()
            case .muted: stroke(circle(c, 5.25)); slash()
            case .recording: circle(c, 3.4).fill(); stroke(circle(c, 7))
            }
        case .halo: // a microphone with the dot beside it
            let dot = NSPoint(x: 14.6, y: 14.2)
            switch state {
            case .idle: mic(cx: 7.4, filled: false); stroke(circle(dot, 2.1), 1.2)
            case .live: mic(cx: 7.4, filled: false); circle(dot, 2.7).fill()
            case .muted: mic(cx: 7.4, filled: false); slash()
            case .recording: mic(cx: 7.4, filled: true); circle(dot, 2.7).fill()
            }
        case .capsule: // a microphone inside the dot
            switch state {
            case .idle: stroke(circle(c, 8)); mic(cx: 9, filled: false, size: 0.62, cy: 9.6)
            case .muted: stroke(circle(c, 8)); mic(cx: 9, filled: false, size: 0.62, cy: 9.6); slash()
            case .live, .recording:
                circle(c, 8.6).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                mic(cx: 9, filled: state == .recording, size: 0.62, cy: 9.6)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
        case .nodot: // a struck-out dot that loses its strike while the mic is open
            switch state {
            case .idle: circle(c, 4.4).fill(); slash()
            case .live: circle(c, 5.4).fill()
            case .muted: mic(cx: 9, filled: false); slash()
            case .recording: circle(c, 3.4).fill(); stroke(circle(c, 7))
            }
        case .symbol: break
        }
    }
}
