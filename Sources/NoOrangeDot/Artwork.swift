import AppKit
import SwiftUI

/// Small decorative drawings in the app icon's pixel style. They carry no meaning, so they are hidden from
/// accessibility and never take a status colour. Sources: assets/ui/*.svg.
enum Artwork: String {
    case idleSlot, emptyRecordings, emptyHistory, take, pixelRule

    var size: CGSize {
        switch self {
        case .idleSlot: return CGSize(width: 30, height: 30)
        case .emptyRecordings: return CGSize(width: 80, height: 56)
        case .emptyHistory: return CGSize(width: 64, height: 40)
        case .take: return CGSize(width: 24, height: 28)
        case .pixelRule: return CGSize(width: 96, height: 6)
        }
    }

    private var svg: String {
        switch self {
        case .idleSlot: return #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 30" width="30" height="30" fill="none" aria-hidden="true"><path d="M18.5 2H9a7 7 0 0 0-7 7v12a7 7 0 0 0 7 7h12a7 7 0 0 0 7-7v-8" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-dasharray="2 3"/><g fill="currentColor"><rect x="22" y="2" width="2" height="2" opacity=".75"/><rect x="26" y="6" width="2" height="2" opacity=".55"/><rect x="27" y="10" width="1.5" height="1.5" opacity=".35"/></g></svg>
"""#
        case .emptyRecordings: return #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 56" width="80" height="56" fill="none" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path d="M24 13h-5a4 4 0 0 0-4 4v25a4 4 0 0 0 4 4h21" opacity=".18"/><path d="M43 7H28a4 4 0 0 0-4 4v30a4 4 0 0 0 4 4h22a4 4 0 0 0 4-4V24" opacity=".55"/><path d="M31 27v4m4-9v14m4-18v22m4-17v12m4-8v4" opacity=".72"/></g><g fill="currentColor"><path d="M45 7h3v3h-3zM49 12h3v3h-3zM53 17h3v3h-3z" opacity=".58"/><path d="M54 7h2v2h-2zM58 12h2v2h-2zM61 18h2v2h-2z" opacity=".3"/><path d="M61 6h2v2h-2zM65 12h2v2h-2z" opacity=".15"/></g></svg>
"""#
        case .emptyHistory: return #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 40" width="64" height="40" fill="none" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round"><path d="M7 29h49" opacity=".13"/><path d="M7 25c10 0 9-15 20-15s13 10 23 10" opacity=".22"/><path d="M7 29c10 0 10-14 20-14s13 9 22 9" opacity=".58"/></g><g fill="currentColor"><rect x="51" y="22" width="2" height="2" opacity=".5"/><rect x="55" y="20" width="2" height="2" opacity=".3"/><rect x="59" y="17" width="2" height="2" opacity=".15"/></g></svg>
"""#
        case .take: return #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 28" width="24" height="28" fill="none" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a3 3 0 0 0-3 3v18a3 3 0 0 0 3 3h12a3 3 0 0 0 3-3V12" opacity=".6"/><path d="M7 14v4m3-7v10m3-12v14m3-10v6" opacity=".8"/></g><g fill="currentColor"><path d="M16 2h2v2h-2zM19 6h2v2h-2z" opacity=".6"/><path d="M21 2h1.5v1.5H21z" opacity=".28"/></g></svg>
"""#
        case .pixelRule: return #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 6" width="96" height="6" fill="none" aria-hidden="true"><path d="M0 3h66" fill="none" stroke="currentColor" stroke-width="1" opacity=".18"/><g fill="currentColor"><rect x="69" y="2" width="2" height="2" opacity=".25"/><rect x="74" y="2" width="2" height="2" opacity=".18"/><rect x="79" y="1" width="2" height="2" opacity=".12"/><rect x="84" y="3" width="2" height="2" opacity=".08"/><rect x="89" y="1" width="2" height="2" opacity=".05"/></g></svg>
"""#
        }
    }

    private static var cache: [Artwork: NSImage] = [:]

    /// A template image: the drawing's own alphas, tinted by the caller.
    @MainActor var image: NSImage? {
        if let hit = Self.cache[self] { return hit }
        guard let image = NSImage(data: Data(svg.replacingOccurrences(of: "currentColor", with: "#000").utf8)) else { return nil }
        image.size = size
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    /// The muted tint that goes with the chosen app icon.
    static func tint(_ appIcon: String) -> Color {
        func hex(_ v: Int) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        let (light, dark) = appIcon == "carbon" ? (hex(0x697174), hex(0xA3AAAC)) : (hex(0x6268A1), hex(0xA1A7D0))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

/// The app's ring without its tile, for the headers. Paint has a light and a dark drawing; Carbon takes the text colour.
struct HeaderLogo: View {
    let appIcon: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let carbon = appIcon == "carbon"
        let name = carbon ? "carbon-ring-template" : scheme == .dark ? "paint-ring-dark" : "paint-ring"
        if let image = Bundle.main.url(forResource: name, withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) {
            Group {
                if carbon { Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).foregroundStyle(.primary) }
                else { Image(nsImage: image).resizable().interpolation(.high) }
            }
            .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct ArtworkView: View {
    let art: Artwork
    var tint: Color = .secondary
    /// The surface behind the drawing, for the one hollow point in the history drawing.
    var surface: Color = Surface.card

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = art.image { Image(nsImage: image).renderingMode(.template).foregroundStyle(tint) }
            if art == .emptyHistory {
                Circle().fill(surface).overlay(Circle().strokeBorder(tint.opacity(0.8), lineWidth: 1.25))
                    .frame(width: 6.25, height: 6.25).offset(x: 27 - 3.125, y: 15 - 3.125)
            }
        }
        .frame(width: art.size.width, height: art.size.height)
        .accessibilityHidden(true)
    }
}
