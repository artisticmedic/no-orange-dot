import SwiftUI

/// The big red Mute button at the top of the sidebar: a raised key on a darker base, which latches
/// like a push switch. A press takes the face all the way down. Released, it rises part of the way and
/// stays there while muted. The next press takes it down the rest of the way, and it comes back to the top.
struct MuteButtonStyle: ButtonStyle {
    var muted: Bool
    /// Draws the held-down state without a pointer, for the render mode.
    var showPressed = false

    private static let red = Color(red: 0.92, green: 0.20, blue: 0.18)
    private static let light = Color(red: 1.0, green: 0.38, blue: 0.33)
    private static let deep = Color(red: 0.74, green: 0.12, blue: 0.12)
    private static let base = Color(red: 0.52, green: 0.07, blue: 0.08)
    private static let travel: CGFloat = 7, latched: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || showPressed
        let depth = pressed ? Self.travel : muted ? Self.latched : 0
        let sunk = depth / Self.travel   // 0 at the top, 1 at the bottom
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let face = LinearGradient(colors: depth > 0 ? [Self.deep, Self.red] : [Self.light, Self.red], startPoint: .top, endPoint: .bottom)
        return configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(depth > 0 ? 0.92 : 1))
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(shape.fill(face.shadow(.inner(color: .black.opacity(0.6 * sunk), radius: 6 * sunk, y: 5 * sunk))))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(depth > 0 ? 0 : 0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
            .brightness(pressed ? -0.06 : 0)
            // The face and its label are drawn as one picture, so the label cannot move apart from the face.
            .drawingGroup()
            .offset(y: depth)
            .padding(.bottom, Self.travel)
            .background(shape.fill(Self.base).padding(.top, Self.travel))
            .contentShape(Rectangle())
            // Down fast, back up on a short spring. A spring picks up from wherever the face is, so quick
            // repeated clicks carry on from the last one instead of restarting.
            .animation(pressed ? .easeOut(duration: 0.05) : .spring(response: 0.2, dampingFraction: 0.58), value: depth)
    }
}

struct MuteButton: View {
    var muted: Bool
    var showPressed = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            // The icon and the first letter never move. Both icons and both words are laid out at once and
            // only their opacity changes, so nothing is re-centred when the state flips.
            HStack(spacing: 7) {
                ZStack {
                    Image(systemName: "mic.fill").opacity(muted ? 0 : 1)
                    Image(systemName: "mic.slash.fill").opacity(muted ? 1 : 0)
                }
                .frame(width: 20)
                ZStack(alignment: .leading) {
                    Text("Mute").opacity(muted ? 0 : 1)
                    Text("Muted").opacity(muted ? 1 : 0)
                }
            }
            // Centred for the shorter word, which is the one on screen most of the time.
            .offset(x: 3)
            // The word and icon change at once, at the bottom of the press, instead of fading.
            .transaction { $0.animation = nil }
        }
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
