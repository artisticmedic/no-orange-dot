import AVFoundation
import Foundation

/// One player for every recording, shared by the Sound and Recordings pages, the menus and the CLI.
extension Engine {
    /// The recording the player shows: the one chosen, or the newest.
    var playerRecording: Recording? { recordings.first { $0.url == playerTake } ?? recordings.first }

    /// Where the playhead is, in seconds. Read inside `Live(meters)` so it moves while playing.
    var playheadSeconds: Double { auditioning != nil ? meters.auditionProgress * player.duration : cueSeconds }

    /// Plays from the start of the selection, or from where the playhead was left.
    @MainActor func play(_ r: Recording, from second: Double? = nil) {
        guard !recording else { note("Stop recording to play a take."); return }
        ReferenceVoice.shared.stop()
        if playerTake != r.url, auditioning != r.url { selection = nil; cueSeconds = 0 }
        playerTake = r.url
        let start = second ?? selection?.lowerBound ?? (cueSeconds < r.seconds - 0.05 ? cueSeconds : 0)
        stopAudition()
        player.loop = auditionLoop
        // A raw take plays through the current sound; one saved without it plays as saved.
        guard player.start(r.raw ?? r.url, processing: r.raw != nil, from: start) else { error = "Couldn't play that recording."; return }
        player.setRange(selection)
        playerPaused = false
        auditioning = r.url
        pushDSP()
    }

    @MainActor func togglePlay() {
        guard let r = playerRecording else { return }
        if auditioning == r.url { playerPaused.toggle() } else { play(r) }
    }

    /// Unloads the player. The chosen recording, the selection and the playhead stay.
    @MainActor func stopPlaying() {
        if auditioning != nil { cueSeconds = player.seconds }
        stopAudition()
    }

    func seek(to second: Double) {
        guard let r = playerRecording else { return }
        let s = min(max(second, 0), max(r.seconds - 0.01, 0))
        if auditioning == r.url { player.seek(to: s); meters.auditionProgress = player.progress } else { cueSeconds = s }
    }

    func choosePlayerTake(_ r: Recording) {
        guard playerTake != r.url else { return }
        let wasPlaying = auditioning != nil && !playerPaused
        stopAudition()
        playerTake = r.url
        selection = nil
        cueSeconds = 0
        if wasPlaying { MainActor.assumeIsolated { play(r) } }
    }

    /// A selection shorter than 50 ms is treated as a click, not a range.
    func setSelection(_ range: ClosedRange<Double>?) {
        selection = range.flatMap { $0.upperBound - $0.lowerBound >= 0.05 ? $0 : nil }
        if auditioning != nil { player.setRange(selection) }
    }

    func stopAudition() {
        guard auditioning != nil else { return }
        player.stop()
        auditioning = nil
        playerPaused = false
        meters.auditionProgress = 0
        if !monitoring { scope.clear(); historyColumn = 0 }
    }

    /// Reached the end without looping: park the playhead where the next play starts.
    func playerFinished() {
        cueSeconds = selection?.lowerBound ?? 0
        stopAudition()
    }

    /// Saves the selected part of the recording as a new one, with its raw take when it has one. The original stays.
    func saveSelection() {
        guard let take = playerRecording, let range = selection else { return }
        let base = take.url.deletingPathExtension().lastPathComponent
        let dir = take.url.deletingLastPathComponent()
        var dest = dir.appendingPathComponent("\(base) clip.\(take.url.pathExtension)"), n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) clip \(n).\(take.url.pathExtension)"); n += 1
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Self.copy(range, from: take.url, to: dest)
                if let raw = take.raw { try Self.copy(range, from: raw, to: Recording.rawURL(for: dest)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.withRecordings { list in
                        guard let clip = list.first(where: { $0.url.lastPathComponent == dest.lastPathComponent }) else { return }
                        self.justSaved = clip
                        self.choosePlayerTake(clip)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                DispatchQueue.main.async { self?.error = "Couldn't save the selection: \(error.localizedDescription)" }
            }
        }
    }

    static func copy(_ range: ClosedRange<Double>, from source: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let rate = input.fileFormat.sampleRate
        let start = AVAudioFramePosition(range.lowerBound * rate)
        let end = min(input.length, AVAudioFramePosition(range.upperBound * rate))
        guard end > start, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        input.framePosition = start
        try input.read(into: buffer, frameCount: AVAudioFrameCount(end - start))
        let output = try AVAudioFile(forWriting: dest, settings: input.fileFormat.settings,
                                     commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
        try output.write(from: buffer)
    }
}
