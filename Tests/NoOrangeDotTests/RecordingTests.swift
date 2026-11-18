import AVFoundation
import XCTest
@testable import NoOrangeDot

final class RecordingTests: XCTestCase {
    private var folder: URL!
    private let injectedError: OSStatus = -12345

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nod-recording-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private var url: URL { folder.appendingPathComponent("take.wav") }

    private func sendBlock(_ writer: RecordingWriter, muted: Bool = false, frames: Int = 1024) {
        var left = [Float](repeating: 0.25, count: frames), right = [Float](repeating: -0.5, count: frames)
        var rawLeft = left, rawRight = right, interleaved = [Float](repeating: 0, count: frames * 2)
        guard writer.beginBlock() else { XCTFail("The take should accept this block"); return }
        defer { writer.endBlock() }
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            rawLeft.withUnsafeMutableBufferPointer { rawL in rawRight.withUnsafeMutableBufferPointer { rawR in
                interleaved.withUnsafeMutableBufferPointer { i in
                    writer.write(l.baseAddress!, r.baseAddress!, rawLeft: rawL.baseAddress!, rawRight: rawR.baseAddress!, frames: frames, interleaved: i.baseAddress!, muted: muted)
                }
            } }
        } }
    }

    func testRawCreationFailureClosesTheProcessedFile() {
        var io = RecordingFileIO.system, creates = 0, disposals = 0
        io.create = { url, format, file in
            creates += 1
            return creates == 2 ? self.injectedError : RecordingFileIO.system.create(url, &format, &file)
        }
        io.dispose = { file in disposals += 1; return RecordingFileIO.system.dispose(file) }
        XCTAssertThrowsError(try RecordingTake(url: url, sampleRate: 48000, stereo: false, io: io)) { error in
            XCTAssertEqual(error as? RecordingFailure, RecordingFailure(step: .create, status: self.injectedError, raw: true))
        }
        XCTAssertEqual(disposals, 1)
    }

    func testRawFormatFailureClosesBothFiles() {
        var io = RecordingFileIO.system, formats = 0, disposals = 0
        io.configure = { file, format in
            formats += 1
            return formats == 2 ? self.injectedError : RecordingFileIO.system.configure(file, &format)
        }
        io.dispose = { file in disposals += 1; return RecordingFileIO.system.dispose(file) }
        XCTAssertThrowsError(try RecordingTake(url: url, sampleRate: 48000, stereo: true, io: io)) { error in
            XCTAssertEqual(error as? RecordingFailure, RecordingFailure(step: .configure, status: self.injectedError, raw: true))
        }
        XCTAssertEqual(disposals, 2)
    }

    func testAsyncPreparationFailureDoesNotStartATake() {
        var io = RecordingFileIO.system, disposals = 0
        io.write = { _, _, _ in self.injectedError }
        io.dispose = { file in disposals += 1; return RecordingFileIO.system.dispose(file) }
        XCTAssertThrowsError(try RecordingTake(url: url, sampleRate: 48000, stereo: false, io: io)) { error in
            XCTAssertEqual(error as? RecordingFailure, RecordingFailure(step: .prepare, status: self.injectedError, raw: false))
        }
        XCTAssertEqual(disposals, 1)
    }

    func testRawWriteFailureStopsFurtherBlocksAndCannotReportSaved() throws {
        var io = RecordingFileIO.system, writes = 0, disposals = 0
        io.write = { file, frames, buffer in
            if frames > 0 { writes += 1 }
            return frames > 0 && writes == 2 ? self.injectedError : RecordingFileIO.system.write(file, frames, buffer)
        }
        io.dispose = { file in disposals += 1; return RecordingFileIO.system.dispose(file) }
        let writer = RecordingWriter()
        writer.attach(try RecordingTake(url: url, sampleRate: 48000, stereo: false, io: io))
        sendBlock(writer)
        let failure = RecordingFailure(step: .write, status: injectedError, raw: true)
        XCTAssertEqual(writer.failure, failure)
        XCTAssertFalse(writer.beginBlock())
        let take = try XCTUnwrap(writer.detach())
        let finalizer = RecordingFinalizer()
        var outcome: Result<URL, RecordingFailure>?
        finalizer.close(take, delayed: false) { outcome = $0 }
        XCTAssertEqual(outcome, .failure(failure))
        XCTAssertEqual(disposals, 2)
        XCTAssertEqual(writes, 2)
    }

    func testCloseFailureCannotReportSavedAndStillClosesTheRawFile() throws {
        var io = RecordingFileIO.system, disposals = 0
        io.dispose = { file in
            disposals += 1
            let status = RecordingFileIO.system.dispose(file)
            return disposals == 1 ? self.injectedError : status
        }
        let take = try RecordingTake(url: url, sampleRate: 48000, stereo: false, io: io)
        var outcome: Result<URL, RecordingFailure>?
        RecordingFinalizer().close(take, delayed: false) { outcome = $0 }
        XCTAssertEqual(outcome, .failure(RecordingFailure(step: .close, status: injectedError, raw: false)))
        XCTAssertEqual(disposals, 2)
    }

    func testPauseAndMutedStereoTakeRetainSilenceInBothFiles() throws {
        let writer = RecordingWriter()
        writer.attach(try RecordingTake(url: url, sampleRate: 48000, stereo: true))
        writer.setPaused(true)
        XCTAssertFalse(writer.beginBlock())
        writer.setPaused(false)
        sendBlock(writer, muted: true)
        let take = try XCTUnwrap(writer.detach())
        XCTAssertNil(take.close())
        for url in [url, Recording.rawURL(for: url)] {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 1024)
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
            try file.read(into: buffer)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for ch in 0..<2 { for frame in 0..<1024 { XCTAssertEqual(channels[ch][frame], 0) } }
        }
    }

    func testDetachWaitsForTheCallbackToReleaseTheTake() throws {
        let writer = RecordingWriter()
        writer.attach(try RecordingTake(url: url, sampleRate: 48000, stereo: false))
        let callbackEntered = DispatchSemaphore(value: 0), releaseCallback = DispatchSemaphore(value: 0)
        let detached = expectation(description: "detach after callback")
        DispatchQueue.global().async {
            XCTAssertTrue(writer.beginBlock())
            callbackEntered.signal()
            releaseCallback.wait()
            writer.endBlock()
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            let take = writer.detach()
            XCTAssertNil(take?.close())
            detached.fulfill()
        }
        XCTAssertFalse(writer.beginBlock())
        releaseCallback.signal()
        wait(for: [detached], timeout: 2)
        XCTAssertFalse(writer.beginBlock())
    }

    func testQuitWaitsForAnAlreadyStoppedTakeToFinalizeBothWAVs() throws {
        let writer = RecordingWriter()
        writer.attach(try RecordingTake(url: url, sampleRate: 48000, stereo: false))
        sendBlock(writer, frames: 48000)
        let take = try XCTUnwrap(writer.detach())
        let scheduled = DispatchSemaphore(value: 0), allowClose = DispatchSemaphore(value: 0)
        let closed = expectation(description: "delayed close completed")
        let quitFinished = expectation(description: "quit waited for close")
        let finalizer = RecordingFinalizer { job in
            DispatchQueue.global().async { scheduled.signal(); allowClose.wait(); job() }
        }
        finalizer.close(take, delayed: true) { outcome in
            XCTAssertEqual(outcome, .success(self.url))
            closed.fulfill()
        }
        XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finalizer.wait(timeout: .now()), .timedOut)
        DispatchQueue.global().async { finalizer.wait(); quitFinished.fulfill() }
        allowClose.signal()
        wait(for: [closed, quitFinished], timeout: 3)
        for url in [url, Recording.rawURL(for: url)] {
            let reopened = try AVAudioFile(forReading: url)
            XCTAssertEqual(reopened.length, 48000)
        }
    }

    func testFileCreationRefusesToEraseAnExistingTake() throws {
        let first = try RecordingTake(url: url, sampleRate: 48000, stereo: false)
        XCTAssertNil(first.close())
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try RecordingTake(url: url, sampleRate: 48000, stereo: false))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSavingASelectionCopiesThatPartOfBothFiles() throws {
        let writer = RecordingWriter()
        writer.attach(try RecordingTake(url: url, sampleRate: 48000, stereo: false))
        for _ in 0..<94 { sendBlock(writer) }   // just over two seconds
        XCTAssertNil(try XCTUnwrap(writer.detach()).close())
        let clip = folder.appendingPathComponent("take clip.wav")
        try Engine.copy(0.5...1.5, from: url, to: clip)
        try Engine.copy(0.5...1.5, from: Recording.rawURL(for: url), to: Recording.rawURL(for: clip))
        for file in [clip, Recording.rawURL(for: clip)] {
            let f = try AVAudioFile(forReading: file)
            XCTAssertEqual(f.length, 48000, "one second at 48 kHz")
            XCTAssertEqual(f.fileFormat.sampleRate, 48000)
        }
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 94 * 1024, "the original is untouched")
        XCTAssertEqual(Recording.list(in: folder).first { $0.url.lastPathComponent == clip.lastPathComponent }?.raw?.lastPathComponent, ".take clip.raw.wav")
    }

    func testWaveformPeaksFollowTheLoudestSampleInEachSlice() {
        var samples = [Float](repeating: 0.1, count: 6000)
        samples[4500] = -0.9
        let peaks = samples.withUnsafeBufferPointer { AuditionPlayer.peaks($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(peaks.count, AuditionPlayer.peakCount)
        XCTAssertEqual(peaks.max(), 0.9)
        XCTAssertEqual(peaks.firstIndex(of: 0.9), 450)
        XCTAssertEqual(PlayerBar.time(65.25), "1:05.2")
    }
}

final class MicrophoneInputTests: XCTestCase {
    func testSplitMonoChannelsRetainTheRightChannelAndShortestFrameCount() {
        var first: [Float] = [0.1, 0.2, 0.3], second: [Float] = [-0.4, -0.5]
        var left = [Float](repeating: 0, count: 3), right = left
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocation.deallocate() }
        let list = allocation.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
        first.withUnsafeMutableBufferPointer { a in second.withUnsafeMutableBufferPointer { b in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: a.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: b.baseAddress)
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                XCTAssertEqual(MicrophoneInput.copy(list, left: l.baseAddress!, right: r.baseAddress!, maximumFrames: 3, stereo: true), 2)
            } }
        } }
        XCTAssertEqual(left, [0.1, 0.2, 0])
        XCTAssertEqual(right, [-0.4, -0.5, 0])
    }

    func testInterleavedStereoChannelsStaySeparateAndRespectCapacity() {
        var samples: [Float] = [0.1, -0.4, 0.2, -0.5, 0.3, -0.6]
        var left = [Float](repeating: 0, count: 3), right = left
        samples.withUnsafeMutableBufferPointer { data in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 24, mData: data.baseAddress))
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                XCTAssertEqual(MicrophoneInput.copy(&list, left: l.baseAddress!, right: r.baseAddress!, maximumFrames: 2, stereo: true), 2)
            } }
        }
        XCTAssertEqual(left, [0.1, 0.2, 0])
        XCTAssertEqual(right, [-0.4, -0.5, 0])
    }

}
