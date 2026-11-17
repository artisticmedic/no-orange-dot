import XCTest
@testable import NoOrangeDot

final class ListenBackTests: XCTestCase {
    private func block(_ reader: inout ListenBackReader, ring: [Float], write: Int, frames: Int = 512) -> [Float] {
        var output = [Float](repeating: -1, count: frames)
        ring.withUnsafeBufferPointer { source in output.withUnsafeMutableBufferPointer { target in
            reader.copy(source.baseAddress!, size: ring.count, write: write, frames: frames, into: target.baseAddress!)
        } }
        return output
    }

    func testStalledProducerDoesNotReplayOldSpeech() {
        let ring = [Float](repeating: 0.25, count: 8192)
        var reader = ListenBackReader()
        XCTAssertEqual(block(&reader, ring: ring, write: 4096), [Float](repeating: 0.25, count: 512))
        for _ in 0..<10 { XCTAssertEqual(block(&reader, ring: ring, write: 4096), [Float](repeating: 0, count: 512)) }
        XCTAssertEqual(block(&reader, ring: ring, write: 4608), [Float](repeating: 0.25, count: 512))
    }

    func testNewSampleRateUsesItsOwnTenMillisecondGap() {
        let ring = (0..<8192).map(Float.init)
        var reader = ListenBackReader(sampleRate: 48000)
        XCTAssertEqual(block(&reader, ring: ring, write: 4096, frames: 256).first, Float(4096 - 256 - 480))
        reader = ListenBackReader(sampleRate: 96000)
        XCTAssertEqual(block(&reader, ring: ring, write: 4096, frames: 256).first, Float(4096 - 256 - 960))
    }

    func testInvalidRingAndOversizedCallbackProduceSilence() {
        var reader = ListenBackReader()
        XCTAssertEqual(block(&reader, ring: [Float](repeating: 1, count: 1000), write: 500), [Float](repeating: 0, count: 512))
        XCTAssertEqual(block(&reader, ring: [Float](repeating: 1, count: 8192), write: 500, frames: 4096), [Float](repeating: 0, count: 4096))
    }
}
