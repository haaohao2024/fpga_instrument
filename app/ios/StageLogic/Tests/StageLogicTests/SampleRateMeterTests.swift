import XCTest
@testable import StageLogic

final class SampleRateMeterTests: XCTestCase {
    private let ns: UInt64 = 1_000_000_000
    private let start: UInt64 = 3_600 * 1_000_000_000

    /// Feeds one stats sample per second at 128 kHz and returns the last reading.
    @discardableResult
    private func feed(_ meter: inout SampleRateMeter, seconds: Int,
                      firstFrame: UInt32, firstTime: UInt64) -> SampleRateMeter.Reading? {
        var reading: SampleRateMeter.Reading?
        for second in 0...seconds {
            reading = meter.add(frame: firstFrame &+ UInt32(128_000 &* second),
                                timeNanos: firstTime &+ UInt64(second) &* ns)
        }
        return reading
    }

    func testSteady128kReads128k() throws {
        var meter = SampleRateMeter()
        let reading = try XCTUnwrap(feed(&meter, seconds: 6, firstFrame: 1_000, firstTime: start))
        XCTAssertEqual(reading.hertz, 128_000, accuracy: 1)
        XCTAssertEqual(reading.windowSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(reading.summary, "实测合成采样率：128.0 kHz（±1%，5 秒平均）")
    }

    func testFrameWrapKeepsCounting() throws {
        var meter = SampleRateMeter()
        // Start just below 2³² so the counter rolls over during the window.
        let reading = try XCTUnwrap(feed(&meter, seconds: 6,
                                         firstFrame: 0xFFFF_0000, firstTime: start))
        XCTAssertEqual(reading.hertz, 128_000, accuracy: 1)
        XCTAssertEqual(reading.windowSeconds, 5, accuracy: 0.001)
    }

    func testShortWindowGivesNoReading() {
        var meter = SampleRateMeter()
        // Five samples one second apart span only four seconds.
        let reading = feed(&meter, seconds: 4, firstFrame: 1_000, firstTime: start)
        XCTAssertNil(reading)
        XCTAssertNil(meter.reading)
    }

    func testFpgaRestartClearsHistory() throws {
        var meter = SampleRateMeter()
        XCTAssertNotNil(feed(&meter, seconds: 6, firstFrame: 1_000, firstTime: start))

        // The counter jumps back to a small value: the board restarted.
        XCTAssertNil(meter.add(frame: 16, timeNanos: start &+ 7 &* ns))
        XCTAssertNil(meter.reading)

        // Measuring continues from the restart without a stale window.
        let reading = try XCTUnwrap(feed(&meter, seconds: 6, firstFrame: 16,
                                         firstTime: start &+ 7 &* ns))
        XCTAssertEqual(reading.hertz, 128_000, accuracy: 1)
    }

    func testZeroOrNegativeTimeGapIsIgnored() throws {
        var meter = SampleRateMeter()
        XCTAssertNil(meter.add(frame: 1_000, timeNanos: start))
        XCTAssertNil(meter.add(frame: 129_000, timeNanos: start))          // same clock value
        XCTAssertNil(meter.add(frame: 257_000, timeNanos: start &- ns))    // clock ran backwards
        XCTAssertNil(meter.reading)

        // The history is intact: a normal run still measures.
        let reading = try XCTUnwrap(feed(&meter, seconds: 6, firstFrame: 129_000,
                                         firstTime: start &+ ns))
        XCTAssertEqual(reading.hertz, 128_000, accuracy: 1)
    }

    func testOutOfRangeRateResets() {
        var meter = SampleRateMeter()
        var reading: SampleRateMeter.Reading?
        // 100 Hz is far below any real synthesis rate, so it must not be shown.
        for second in 0...6 {
            reading = meter.add(frame: UInt32(1_000 &+ 100 * second),
                                timeNanos: start &+ UInt64(second) &* ns)
        }
        XCTAssertNil(reading)
        XCTAssertNil(meter.reading)
    }
}
