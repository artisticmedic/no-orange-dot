import SwiftUI

/// The colours of a key: a lit top edge, the face, the face pushed in, and the darker base it travels into.
struct KeyPalette {
    let light, face, deep, base: Color
    var text: Color = .white
    /// How bright the lit top edge is.
    var rim = 0.45

    static let red = KeyPalette(light: Color(red: 1.0, green: 0.38, blue: 0.33), face: Color(red: 0.92, green: 0.20, blue: 0.18),
                                deep: Color(red: 0.74, green: 0.12, blue: 0.12), base: Color(red: 0.52, green: 0.07, blue: 0.08))
    static let blue = KeyPalette(light: Color(red: 0.36, green: 0.62, blue: 1.0), face: Color(red: 0.16, green: 0.46, blue: 0.94),
                                 deep: Color(red: 0.10, green: 0.34, blue: 0.78), base: Color(red: 0.05, green: 0.18, blue: 0.46))
    static func graphite(_ scheme: ColorScheme) -> KeyPalette {
        scheme == .dark
            ? KeyPalette(light: Color(white: 0.37), face: Color(white: 0.31), deep: Color(white: 0.26), base: Color(white: 0.19),
                         text: Color(white: 0.9), rim: 0.16)
            : KeyPalette(light: Color(white: 1.0), face: Color(white: 0.93), deep: Color(white: 0.85), base: Color(white: 0.68), text: Color(white: 0.12))
    }
}

/// The sidebar's keys: a raised face on a darker base, which latches like a push switch.
struct KeyButtonStyle: ButtonStyle {
    var palette: KeyPalette
    var latched = false
    var height: CGFloat = 44
    /// Draws the held-down state without a pointer, for the render mode.
    var showPressed = false

    private static let travel: CGFloat = 7, latchDepth: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || showPressed
        let depth = pressed ? Self.travel : latched ? Self.latchDepth : 0
        let sunk = depth / Self.travel
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let face = LinearGradient(colors: depth > 0 ? [palette.deep, palette.face] : [palette.light, palette.face], startPoint: .top, endPoint: .bottom)
        return configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(palette.text.opacity(depth > 0 ? 0.92 : 1))
            .frame(maxWidth: .infinity).frame(height: height)
            .background(shape.fill(face.shadow(.inner(color: .black.opacity(0.6 * sunk), radius: 6 * sunk, y: 5 * sunk))))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(depth > 0 ? 0 : palette.rim), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
            .brightness(pressed ? -0.06 : 0)
            // The face and its label are drawn as one picture, so the label cannot move apart from the face.
            .drawingGroup()
            .offset(y: depth)
            .padding(.bottom, Self.travel)
            .background(shape.fill(palette.base).padding(.top, Self.travel))
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
            .buttonStyle(KeyButtonStyle(palette: .red, latched: muted, showPressed: showPressed))
            .help(muted ? "Unmute the microphone" : "Mute the microphone")
            .accessibilityLabel(muted ? "Unmute" : "Mute")
    }
}

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
