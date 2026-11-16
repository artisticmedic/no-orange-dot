import SwiftUI

/// Values that change many times a second live apart from `Engine`, so that a moving meter
/// redraws only the meter and not every view that reads the engine.
final class Meters: ObservableObject {
    @Published var level: Float = 0
    @Published var voice = VoiceLevel.Reading(averageDB: -100, peakDB: -100)
    @Published var playbackVoice = VoiceLevel.Reading(averageDB: -100, peakDB: -100)
    @Published var reductionDB: Float = 0
    @Published var limiterDB: Float = 0
    @Published var auditionProgress = 0.0
}

/// The live picture of the voice. It only changes while the live view or a recording is playing.
final class Scope: ObservableObject {
    @Published var spectrumPost: [Float] = []   // dB per display band, after the EQ
    @Published var spectrumRaw: [Float] = []    // dB per display band, straight from the mic
    @Published var spectrogram: CGImage?

    func clear() { spectrumPost = []; spectrumRaw = []; spectrogram = nil }
}

/// Redraws its content whenever the source changes.
struct Live<Source: ObservableObject, Content: View>: View {
    @ObservedObject var source: Source
    @ViewBuilder var content: (Source) -> Content
    init(_ source: Source, @ViewBuilder content: @escaping (Source) -> Content) { self.source = source; self.content = content }
    var body: some View { content(source) }
}
