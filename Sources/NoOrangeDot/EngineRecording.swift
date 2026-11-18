import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import ServiceManagement
import SwiftUI

extension Engine {
    // MARK: Recording

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    func startRecording() {
        guard driverInstalled, ioProc != nil, !recording else { return }
        let dir = recordingsURL
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { self.error = "Couldn't use the recordings folder at \(dir.path). Choose another one."; return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        var url = dir.appendingPathComponent("\(stamp).wav"), n = 2
        while FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: Recording.rawURL(for: url).path) {
            url = dir.appendingPathComponent("\(stamp) \(n).wav"); n += 1
        }
        justSaved = nil
        do {
            let take = try RecordingTake(url: url, sampleRate: sampleRate, stereo: stereoFlag)
            recordingWriter.attach(take)
        } catch { self.error = error.localizedDescription; return }
        // A take is the mic alone: anything playing would also reach the speakers and the mic.
        let interrupted = MainActor.assumeIsolated { () -> Bool in
            let active = auditioning != nil || ReferenceVoice.shared.isActive
            stopPlaying()
            ReferenceVoice.shared.stop()
            return active
        }
        if interrupted { note("Stopped playback to record.") }
        recordedBefore = 0
        recordSegmentStart = Date()
        recordingPaused = false
        recording = true
        lastRecording = url
        evaluate()
        if !running {
            stopRecording(failure: RecordingFailure(step: .openMicrophone, status: kAudioHardwareUnspecifiedError, raw: false))
        }
    }

    /// Time recorded so far, not counting pauses.
    var recordingElapsed: TimeInterval { recordedBefore + (recordSegmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    /// Stops writing without ending the take. While paused the mic can close.
    func togglePause() {
        guard recording else { return }
        if recordingPaused {
            recordSegmentStart = Date()
            recordingPaused = false
            recordingWriter.setPaused(false)
        } else {
            recordingWriter.setPaused(true)
            recordedBefore = recordingElapsed
            recordSegmentStart = nil
            recordingPaused = true
        }
        evaluate()
        if !recordingPaused, !running {
            stopRecording(failure: RecordingFailure(step: .openMicrophone, status: kAudioHardwareUnspecifiedError, raw: false))
        }
    }

    func stopRecording(failure: RecordingFailure? = nil) {
        guard recording else { return }
        let take = recordingWriter.detach()
        recording = false
        recordingPaused = false
        recordSegmentStart = nil
        evaluate()
        guard let take else { return }
        if let failure { take.noteFailure(failure) }
        if let failure = take.failure { error = failure.localizedDescription; justSaved = nil }
        pendingCloses.close(take, delayed: running) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url): self.announceSaved(url)
                case .failure(let failure): self.error = failure.localizedDescription; self.justSaved = nil; self.refreshRecordings()
                }
            }
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
            if playerTake == r.url { playerTake = nil; selection = nil; cueSeconds = 0 }
            try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
            if let raw = r.raw { try? FileManager.default.trashItem(at: raw, resultingItemURL: nil) }
        }
        refreshRecordings()
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

struct RecordingFailure: Error, Equatable, LocalizedError {
    enum Step: String {
        case create = "create", configure = "set the format for", prepare = "prepare", write = "write", close = "finish", openMicrophone = "open the microphone for"
    }
    var step: Step
    var status: OSStatus
    var raw: Bool
    var errorDescription: String? {
        "Recording stopped: Couldn't \(step.rawValue) the \(raw ? "raw take" : "recording") (error \(status)). Some audio may be missing."
    }
}

struct RecordingFileIO {
    var create: (URL, inout AudioStreamBasicDescription, inout ExtAudioFileRef?) -> OSStatus = { url, format, file in
        ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil, 0, &file)
    }
    var configure: (ExtAudioFileRef, inout AudioStreamBasicDescription) -> OSStatus = { file, format in
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format)
    }
    var write: (ExtAudioFileRef, UInt32, UnsafePointer<AudioBufferList>?) -> OSStatus = { ExtAudioFileWriteAsync($0, $1, $2) }
    var dispose: (ExtAudioFileRef) -> OSStatus = { ExtAudioFileDispose($0) }
    static let system = RecordingFileIO()
}

final class RecordingTake {
    let url: URL
    let stereo: Bool
    private let io: RecordingFileIO
    private var processed: ExtAudioFileRef?
    private var raw: ExtAudioFileRef?
    private(set) var failure: RecordingFailure?

    init(url: URL, sampleRate: Double, stereo: Bool, io: RecordingFileIO = .system) throws {
        self.url = url; self.stereo = stereo; self.io = io
        do {
            processed = try makeFile(url, sampleRate: sampleRate, raw: false)
            raw = try makeFile(Recording.rawURL(for: url), sampleRate: sampleRate, raw: true)
        } catch { _ = close(); throw error }
    }

    private func makeFile(_ url: URL, sampleRate: Double, raw: Bool) throws -> ExtAudioFileRef {
        let channels: UInt32 = stereo ? 2 : 1
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 3 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 3 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        var client = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var file: ExtAudioFileRef?
        let created = io.create(url, &format, &file)
        guard created == noErr, let file else {
            if let file { _ = io.dispose(file) }
            throw RecordingFailure(step: .create, status: created == noErr ? kAudioFileUnspecifiedError : created, raw: raw)
        }
        let configured = io.configure(file, &client)
        guard configured == noErr else { _ = io.dispose(file); throw RecordingFailure(step: .configure, status: configured, raw: raw) }
        let prepared = io.write(file, 0, nil)
        guard prepared == noErr else { _ = io.dispose(file); throw RecordingFailure(step: .prepare, status: prepared, raw: raw) }
        return file
    }

    func noteFailure(_ failure: RecordingFailure) { if self.failure == nil { self.failure = failure } }

    func write(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, rawLeft: UnsafeMutablePointer<Float>, rawRight: UnsafeMutablePointer<Float>, frames: Int, interleaved: UnsafeMutablePointer<Float>, muted: Bool) {
        guard failure == nil, let processed, let raw else { return }
        if muted {
            memset(left, 0, frames * 4); memset(rawLeft, 0, frames * 4)
            if stereo { memset(right, 0, frames * 4); memset(rawRight, 0, frames * 4) }
        }
        let result = write(processed, left, right, frames: frames, interleaved: interleaved)
        if result != noErr { noteFailure(RecordingFailure(step: .write, status: result, raw: false)); return }
        let rawResult = write(raw, rawLeft, rawRight, frames: frames, interleaved: interleaved)
        if rawResult != noErr { noteFailure(RecordingFailure(step: .write, status: rawResult, raw: true)) }
    }

    private func write(_ file: ExtAudioFileRef, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, interleaved: UnsafeMutablePointer<Float>) -> OSStatus {
        if stereo {
            for n in 0..<frames { interleaved[n * 2] = left[n]; interleaved[n * 2 + 1] = right[n] }
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: interleaved))
            return io.write(file, UInt32(frames), &buffer)
        }
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left))
        return io.write(file, UInt32(frames), &buffer)
    }

    func close() -> RecordingFailure? {
        if let file = processed {
            processed = nil
            let status = io.dispose(file)
            if status != noErr { noteFailure(RecordingFailure(step: .close, status: status, raw: false)) }
        }
        if let file = raw {
            raw = nil
            let status = io.dispose(file)
            if status != noErr { noteFailure(RecordingFailure(step: .close, status: status, raw: true)) }
        }
        return failure
    }
}

/// A block owns the take until endBlock; detaching cannot dispose a file still in use.
final class RecordingWriter {
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var take: RecordingTake?
    private var paused = false

    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    func attach(_ take: RecordingTake) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        precondition(self.take == nil)
        self.take = take; paused = false
    }

    func setPaused(_ paused: Bool) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        self.paused = paused
    }

    func beginBlock() -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        guard let take, !paused, take.failure == nil else { os_unfair_lock_unlock(lock); return false }
        return true
    }

    func write(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, rawLeft: UnsafeMutablePointer<Float>, rawRight: UnsafeMutablePointer<Float>, frames: Int, interleaved: UnsafeMutablePointer<Float>, muted: Bool) {
        take?.write(left, right, rawLeft: rawLeft, rawRight: rawRight, frames: frames, interleaved: interleaved, muted: muted)
    }

    func endBlock() { os_unfair_lock_unlock(lock) }

    var failure: RecordingFailure? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return take?.failure
    }

    func detach() -> RecordingTake? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let detached = take
        take = nil; paused = false
        return detached
    }
}

final class RecordingFinalizer {
    private let pending = DispatchGroup()
    private let schedule: (@escaping () -> Void) -> Void

    init(schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: $0) }) {
        self.schedule = schedule
    }

    func close(_ take: RecordingTake, delayed: Bool, completion: @escaping (Result<URL, RecordingFailure>) -> Void) {
        pending.enter()
        let close = { [pending] in
            let failure = take.close()
            pending.leave()
            if let failure { completion(.failure(failure)) } else { completion(.success(take.url)) }
        }
        if delayed { schedule(close) } else { close() }
    }

    @discardableResult func wait(timeout: DispatchTime = .distantFuture) -> DispatchTimeoutResult { pending.wait(timeout: timeout) }
}

enum MicrophoneInput {
    static func copy(_ input: UnsafePointer<AudioBufferList>, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, maximumFrames: Int, stereo: Bool) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return 0 }
        let channels = Int(first.mNumberChannels)
        var frames = min(Int(first.mDataByteSize) / (4 * channels), maximumFrames)
        let source = data.assumingMemoryBound(to: Float.self)
        if stereo, channels == 1, buffers.count > 1, let rightData = buffers[1].mData, buffers[1].mNumberChannels > 0 {
            let rightChannels = Int(buffers[1].mNumberChannels)
            frames = min(frames, Int(buffers[1].mDataByteSize) / (4 * rightChannels))
            let r = rightData.assumingMemoryBound(to: Float.self)
            for n in 0..<frames { right[n] = r[n * rightChannels] }
        } else if stereo, channels >= 2 {
            for n in 0..<frames { right[n] = source[n * channels + 1] }
        } else if stereo { memset(right, 0, frames * 4) }
        for n in 0..<frames { left[n] = source[n * channels] }
        return frames
    }
}
