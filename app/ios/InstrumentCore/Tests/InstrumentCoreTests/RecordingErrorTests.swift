import XCTest
@testable import InstrumentCore

final class RecordingErrorTests: XCTestCase {
    func testSigned32BitRecordingCodesKeepTheirDisplayedSign() throws {
        let cases: [(UInt32,Int)]=[(0xfffffff4,-12),(0xfffffff3,-13),(1,1),(4,4),(7,7)]
        for (bits,expected) in cases {
            var p=Array(repeating:UInt8(0),count:72)
            p[0]=42;p[8]=7;p[9]=6;p[10]=3;p[11]=4
            p.replaceSubrange(12..<16,with:LE.bytes(bits))
            let failed=try RecordInfo(p)
            XCTAssertEqual(failed.error,expected)
            XCTAssertEqual(failed.summary,"错误\n记录 42，错误码 \(expected)")
            XCTAssertFalse(failed.downloadable(1))
        }
    }
    func testSignedFilesystemErrorAndPositiveRecorderErrorRemainDistinct() throws {
        var p=Array(repeating:UInt8(0),count:72)
        p[0]=42;p[8]=7;p[9]=6;p[10]=3;p[11]=4
        p.replaceSubrange(12..<16,with:LE.bytes(UInt32(bitPattern:Int32(-12))))
        let failed=try RecordInfo(p)
        XCTAssertEqual(failed.error,-12)
        XCTAssertEqual(failed.summary,"错误\n记录 42，错误码 -12")
        XCTAssertFalse(failed.downloadable(1));XCTAssertFalse(failed.downloadable(2))
        p[8]=6;p.replaceSubrange(12..<16,with:LE.bytes(UInt32(4)))
        let partial=try RecordInfo(p)
        XCTAssertEqual(partial.error,4);XCTAssertFalse(partial.downloadable(1))
    }
}
