import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Recording

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    func startRecording() {
        guard driverInstalled, ioProc != nil else { return }
        let dir = recordingsURL
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { self.error = "Couldn't use the recordings folder at \(dir.path). Choose another one."; return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        var url = dir.appendingPathComponent("\(stamp).wav"), n = 2
        // Two takes started in the same second would otherwise share a name, and the second would erase the first.
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(stamp) \(n).wav"); n += 1 }
        guard let file = makeFile(url) else { error = "Couldn't create the recording file."; return }
        recordFile = file
        // The raw take, hidden beside it, so the recording can be replayed through a different EQ later.
        recordRawFile = makeFile(Recording.rawURL(for: url))
        recordedBefore = 0
        recordSegmentStart = Date()
        recordingPaused = false
        justSaved = nil
        recordFlag = true
        recording = true
        lastRecording = url
        evaluate()
    }

    /// Time recorded so far, not counting pauses.
    var recordingElapsed: TimeInterval { recordedBefore + (recordSegmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    /// Stops writing without ending the take. While paused the mic can close.
    func togglePause() {
        guard recording else { return }
        if recordingPaused {
            recordSegmentStart = Date()
            recordingPaused = false
            recordFlag = true
        } else {
            recordFlag = false
            recordedBefore = recordingElapsed
            recordSegmentStart = nil
            recordingPaused = true
        }
        evaluate()
    }

    func makeFile(_ url: URL) -> ExtAudioFileRef? {
        let channels: UInt32 = stereoFlag ? 2 : 1
        var fileFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 3 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 3 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        var clientFmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var file: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &fileFmt, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr, let file else { return nil }
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt)
        ExtAudioFileWriteAsync(file, 0, nil) // allocate the async buffers off the audio thread
        return file
    }

    func stopRecording() {
        guard recording else { return }
        recordFlag = false
        recording = false
        recordingPaused = false
        recordSegmentStart = nil
        evaluate()
        let file = recordFile, raw = recordRawFile, url = lastRecording
        recordFile = nil; recordRawFile = nil
        let close = {
            if let file { ExtAudioFileDispose(file) }
            if let raw { ExtAudioFileDispose(raw) }
        }
        // With the audio stopped nothing can still be writing, so close now: the app may be quitting.
        guard running else { close(); announceSaved(url); return }
        // Otherwise give the audio thread time to finish the block it may be writing.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            close()
            DispatchQueue.main.async { [weak self] in self?.announceSaved(url) }
        }
    }

    private func announceSaved(_ url: URL?) {
        withRecordings { [weak self] list in
            guard let self, let take = list.first(where: { $0.url == url }) else { return }
            self.justSaved = take
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                if self?.justSaved == take { self?.justSaved = nil }
            }
        }
    }

    /// Moves recordings to the Trash, where they can be put back.
    func trash(_ items: [Recording]) {
        for r in items {
            if auditioning == r.url { stopAudition() }
            try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
            if let raw = r.raw { try? FileManager.default.trashItem(at: raw, resultingItemURL: nil) }
        }
        refreshRecordings()
    }

    /// Plays a recording's raw take through the current EQ, gate and compressor.
    func startAudition(_ r: Recording) {
        guard let raw = r.raw else { return }
        stopAudition()
        player.loop = auditionLoop
        guard player.start(raw) else { error = "Couldn't play that recording."; return }
        auditioning = r.url
        pushDSP()
    }

    func stopAudition() {
        guard auditioning != nil else { return }
        player.stop()
        auditioning = nil
        meters.auditionProgress = 0
        if !monitoring { scope.clear(); historyColumn = 0 }
    }

    var recordingsURL: URL { var s = Settings(); s.recordingsFolder = recordingsFolder; return s.recordingsURL }

    func refreshRecordings() { withRecordings { _ in } }

    /// Reads the folder off the main thread, then hands over the fresh list.
    func withRecordings(_ then: @escaping ([Recording]) -> Void) {
        let folder = recordingsURL
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Recording.list(in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingsURL == folder else { return }
                self.recordings = list
                then(list)
            }
        }
    }
}
