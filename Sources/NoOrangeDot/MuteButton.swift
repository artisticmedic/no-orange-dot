import SwiftUI

/// The big red Mute button at the top of the sidebar. It stays down while the mic is muted.
struct MuteButtonStyle: ButtonStyle {
    enum Variant: String, CaseIterable { case keycap, dome, slab }
    var variant: Variant = Variant(rawValue: ProcessInfo.processInfo.environment["NOD_MUTE_VARIANT"] ?? "") ?? .keycap
    var muted: Bool

    private static let red = Color(red: 0.92, green: 0.20, blue: 0.18)
    private static let light = Color(red: 1.0, green: 0.38, blue: 0.33)
    private static let dark = Color(red: 0.58, green: 0.08, blue: 0.09)

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || muted
        let label = configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: Self.dark.opacity(0.8), radius: 0, y: 1)
            .frame(maxWidth: .infinity)
        switch variant {
        case .keycap:
            // A raised key: a bright face on a darker base, and the face sinks onto the base when pressed.
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            label.frame(height: 44)
                .background(shape.fill(LinearGradient(colors: down ? [Self.red, Self.dark.opacity(0.9)] : [Self.light, Self.red], startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(down ? 0.12 : 0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
                .offset(y: down ? 5 : 0)
                .padding(.bottom, 6)
                .background(shape.fill(Self.dark).padding(.top, 6))
                .shadow(color: .black.opacity(down ? 0.10 : 0.22), radius: down ? 1 : 4, y: down ? 1 : 3)
                .contentShape(Rectangle())
        case .dome:
            // A glossy arcade button: a shine across the top half and a soft red glow underneath.
            label.frame(height: 48)
                .background(Capsule().fill(LinearGradient(colors: down ? [Self.dark, Self.red] : [Self.light, Self.red, Self.dark], startPoint: .top, endPoint: .bottom)))
                .overlay(alignment: .top) {
                    Capsule().fill(LinearGradient(colors: [.white.opacity(down ? 0.10 : 0.50), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 22).padding(.horizontal, 7).padding(.top, 3)
                }
                .overlay(Capsule().strokeBorder(Self.dark.opacity(0.7), lineWidth: 1))
                .shadow(color: Self.red.opacity(down ? 0.15 : 0.50), radius: down ? 2 : 9, y: down ? 1 : 5)
                .scaleEffect(down ? 0.97 : 1)
                .contentShape(Capsule())
        case .slab:
            // Flat colour with a hard shadow, like a printed sticker. It shifts onto its shadow when pressed.
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            label.frame(height: 44)
                .background(shape.fill(down ? Self.dark : Self.red))
                .overlay(shape.strokeBorder(Color.black.opacity(0.85), lineWidth: 2))
                .offset(x: down ? 3 : 0, y: down ? 4 : 0)
                .background(shape.fill(Color.black.opacity(0.85)).offset(x: 3, y: 4))
                .padding(.trailing, 3).padding(.bottom, 4)
                .contentShape(Rectangle())
        }
    }
}

struct MuteButton: View {
    var muted: Bool
    var variant: MuteButtonStyle.Variant?
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) { Label(muted ? "Muted" : "Mute", systemImage: muted ? "mic.slash.fill" : "mic.fill") }
            .buttonStyle(variant.map { MuteButtonStyle(variant: $0, muted: muted) } ?? MuteButtonStyle(muted: muted))
            .help(muted ? "Unmute the microphone" : "Mute the microphone")
            .accessibilityLabel(muted ? "Unmute" : "Mute")
    }
}

/// Every variant in both states, for choosing between them.
struct MuteButtonSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(MuteButtonStyle.Variant.allCases, id: \.self) { v in
                HStack(spacing: 24) {
                    Text(v.rawValue).font(.system(size: 13, weight: .medium)).frame(width: 60, alignment: .leading)
                    MuteButton(muted: false, variant: v).frame(width: 200)
                    MuteButton(muted: true, variant: v).frame(width: 200)
                }
            }
        }
        .padding(28)
    }
}
