import AVFoundation
import XCTest
@testable import NoOrangeDot

final class VoiceLevelTests: XCTestCase {
    private let rate = 48000.0

    private func reading(left: [Float], right: [Float]? = nil) -> VoiceLevel.Reading {
        var level = VoiceLevel()
        let r = right ?? left
        left.withUnsafeBufferPointer { l in r.withUnsafeBufferPointer { r in
            level.consume(l.baseAddress!, r.baseAddress!, frames: left.count, stereo: right != nil, sampleRate: rate)
        } }
        return level.reading
    }

    func testSteadyAmplitudeAndPeakHaveDifferentMeanings() {
        let samples = (0..<192000).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / rate)) }
        let measured = reading(left: samples)
        XCTAssertEqual(measured.averageDB, -23.0103, accuracy: 0.01)
        XCTAssertEqual(measured.peakDB, -20, accuracy: 0.01)
    }

    func testRightChannelContributesPowerAndPeak() {
        let measured = reading(left: [Float](repeating: 0, count: 192000), right: [Float](repeating: 0.1, count: 192000))
        XCTAssertEqual(measured.averageDB, -23.0103, accuracy: 0.01)
        XCTAssertEqual(measured.peakDB, -20, accuracy: 0.01)
    }

    func testSilenceReleaseAndReset() {
        var level = VoiceLevel()
        XCTAssertEqual(level.reading, .silence)
        let loud = [Float](repeating: 0.5, count: 192000)
        let quiet = [Float](repeating: 0, count: 19200)
        loud.withUnsafeBufferPointer { p in level.consume(p.baseAddress!, p.baseAddress!, frames: loud.count, stereo: false, sampleRate: rate) }
        let before = level.reading
        quiet.withUnsafeBufferPointer { p in level.consume(p.baseAddress!, p.baseAddress!, frames: quiet.count, stereo: false, sampleRate: rate) }
        XCTAssertEqual(level.reading.averageDB, before.averageDB - 10 * log10(exp(1.0)), accuracy: 0.001)
        XCTAssertEqual(level.reading.peakDB, before.peakDB - 20 * log10(exp(1.0)), accuracy: 0.001)
        level.reset()
        XCTAssertEqual(level.reading, .silence)
    }

    func testInvalidSamplesDoNotPoisonTheMeter() {
        let measured = reading(left: [.nan, .infinity, -.infinity, 0])
        XCTAssertEqual(measured, .silence)
    }
}

final class ReferenceAudioTests: XCTestCase {
    private let rate = 48000.0

    func testNormalizationExcludesSilenceAndTargetsActiveAverage() throws {
        let speech = (0..<48000).map { Float(0.03 * sin(2 * .pi * 1000 * Double($0) / rate)) }
        let samples = [Float](repeating: 0, count: 48000) + speech + [Float](repeating: 0, count: 48000)
        let result = try XCTUnwrap(ReferenceAudio.normalized(samples, sampleRate: rate))
        let rms = try XCTUnwrap(ReferenceAudio.activeRMS(result, sampleRate: rate))
        XCTAssertEqual(20 * log10(rms), VoiceLevel.referenceDB, accuracy: 0.01)
        XCTAssertEqual(Array(result.prefix(48000)), [Float](repeating: 0, count: 48000))
    }

    func testNormalizationHonorsPeakCeilingForHighCrestAudio() throws {
        var samples = [Float](repeating: 0.01, count: 48000)
        samples[1000] = 1
        let result = try XCTUnwrap(ReferenceAudio.normalized(samples, sampleRate: rate))
        let peak = Double(try XCTUnwrap(result.map(abs).max()))
        XCTAssertEqual(20 * log10(peak), -3, accuracy: 0.001)
        XCTAssertLessThan(20 * log10(try XCTUnwrap(ReferenceAudio.activeRMS(result, sampleRate: rate))), VoiceLevel.referenceDB)
    }

    func testSilentOrInvalidReferenceIsRejected() {
        XCTAssertNil(ReferenceAudio.normalized([Float](repeating: 0, count: 1000), sampleRate: rate))
        XCTAssertNil(ReferenceAudio.normalized([.nan], sampleRate: rate))
        XCTAssertNil(ReferenceAudio.normalized([0.1], sampleRate: 0))
    }

    func testStereoSpeechBufferDownmixesBothChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<4 { channels[0][i] = 0.2; channels[1][i] = 0.6 }
        let mono = try XCTUnwrap(ReferenceAudio.monoSamples(buffer))
        XCTAssertEqual(mono.count, 4)
        for sample in mono { XCTAssertEqual(sample, 0.4, accuracy: 0.00001) }
    }

    func testWaveHeaderAndClampedPCMData() throws {
        let wave = try XCTUnwrap(ReferenceAudio.wave([0, 1, -1, 2], sampleRate: rate))
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wave[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(wave.count, 52)
        XCTAssertEqual(Array(wave.suffix(8)), [0, 0, 255, 127, 1, 128, 255, 127])
    }
}
