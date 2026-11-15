import SwiftUI

/// The big red Mute button at the top of the sidebar: a raised key on a darker base. Pressing it
/// sinks the face onto the base, and it stays sunk, with a shadow inside its top edge, while muted.
struct MuteButtonStyle: ButtonStyle {
    var muted: Bool
    /// Draws the held-down state without a pointer, for the render mode.
    var showPressed = false

    private static let red = Color(red: 0.92, green: 0.20, blue: 0.18)
    private static let light = Color(red: 1.0, green: 0.38, blue: 0.33)
    private static let deep = Color(red: 0.74, green: 0.12, blue: 0.12)
    private static let base = Color(red: 0.52, green: 0.07, blue: 0.08)
    private static let travel: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || showPressed
        let down = pressed || muted
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let face = LinearGradient(colors: down ? [Self.deep, Self.red] : [Self.light, Self.red], startPoint: .top, endPoint: .bottom)
        return configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(down ? 0.92 : 1))
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(shape.fill(face.shadow(.inner(color: .black.opacity(down ? 0.55 : 0), radius: down ? 5 : 0, y: down ? 4 : 0))))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(down ? 0 : 0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
            .brightness(pressed ? -0.05 : 0)
            .offset(y: down ? Self.travel : 0)
            .padding(.bottom, Self.travel)
            .background(shape.fill(Self.base).padding(.top, Self.travel))
            .contentShape(Rectangle())
            // Down fast, back up with a small bounce, like a key with a spring under it.
            .animation(down ? .easeOut(duration: 0.07) : .spring(response: 0.26, dampingFraction: 0.52), value: down)
    }
}

struct MuteButton: View {
    var muted: Bool
    var showPressed = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) { Label(muted ? "Muted" : "Mute", systemImage: muted ? "mic.slash.fill" : "mic.fill") }
            .buttonStyle(MuteButtonStyle(muted: muted, showPressed: showPressed))
            .help(muted ? "Unmute the microphone" : "Mute the microphone")
            .accessibilityLabel(muted ? "Unmute" : "Mute")
    }
}

/// The button's three states side by side, for the render mode.
struct MuteButtonSheet: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(["up", "held down", "muted"], id: \.self) { state in
                VStack(alignment: .leading, spacing: 10) {
                    Text(state).font(.system(size: 13, weight: .medium))
                    MuteButton(muted: state == "muted", showPressed: state == "held down").frame(width: 200)
                }
            }
        }
        .padding(28)
    }
}
