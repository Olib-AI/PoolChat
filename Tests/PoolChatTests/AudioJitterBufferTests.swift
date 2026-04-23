import XCTest
@testable import PoolChat

final class AudioJitterBufferTests: XCTestCase {
    func testDrainSkipsMissingFrameWithoutDeadlocking() {
        let buffer = AudioJitterBuffer()
        buffer.targetDepth = 1

        let frame10 = Data([0x0A])
        let frame12 = Data([0x0C])

        buffer.insert(sequence: 10, data: frame10)
        buffer.insert(sequence: 12, data: frame12)

        XCTAssertEqual(buffer.drain(), frame10)
        XCTAssertEqual(buffer.drain(), frame12)
        XCTAssertEqual(buffer.targetDepth, 2)
    }
}
