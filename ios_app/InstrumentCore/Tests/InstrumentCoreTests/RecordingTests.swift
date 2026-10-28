import XCTest
@testable import InstrumentCore

final class RecordingTests: XCTestCase {
    func info(_ content: [UInt8],crc override: UInt32?=nil) throws -> RecordInfo {
        var b=Array(repeating:UInt8(0),count:72)
        b.replaceSubrange(0..<8,with:LE.bytes(UInt64(0xf123456789abcdef)))
        b[8]=5;b[10]=2;b[11]=2
        b.replaceSubrange(40..<48,with:LE.bytes(UInt64(content.count)))
        b.replaceSubrange(52..<56,with:LE.bytes(override ?? Wire.crc(content)))
        return try RecordInfo(b)
    }
    func block(_ d: RecordingDownload,_ p: [UInt8],pos: UInt64=0,id: UInt64?=nil) -> [UInt8] {
        LE.bytes(id ?? d.id)+LE.bytes(pos)+LE.bytes(d.total)+LE.bytes(Wire.crc(p))+[2,0,0,0]+p
    }
    func testPublishRequiresBothExecutionAckAndFullFileCRC() throws {
        let data=Array("independent capture".utf8),d=try RecordingDownload(record:info(data),kind:2)
        d.awaitingResult=true;d.awaitingData=true;try d.accept(block(d,data))
        XCTAssertFalse(d.finished);XCTAssertThrowsError(try d.publish())
        d.awaitingResult=false;XCTAssertTrue(d.finished)
        let url=try d.publish();defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertEqual(try Data(contentsOf:url),Data(data))
    }
    func testWrongIdentityCRCOffsetAndChangedDuplicateCannotBePublished() throws {
        let data=Array(repeating:UInt8(12),count:500),d=try RecordingDownload(record:info(data),kind:2)
        d.awaitingData=true;let first=Array(data.prefix(480))
        XCTAssertThrowsError(try d.accept(block(d,first,id:1)))
        XCTAssertThrowsError(try d.accept(block(d,first,pos:1)))
        var corrupt=block(d,first);corrupt[32]^=1;XCTAssertThrowsError(try d.accept(corrupt))
        try d.accept(block(d,first));try d.accept(block(d,first));XCTAssertEqual(d.offset,480)
        XCTAssertThrowsError(try d.accept(block(d,Array(repeating:13,count:480))))
        XCTAssertThrowsError(try d.publish())
        d.awaitingData=true;try d.accept(block(d,Array(data.suffix(20)),pos:480))
        let url=try d.publish();defer{try? FileManager.default.removeItem(at:url)};XCTAssertEqual(try Data(contentsOf:url),Data(data))
    }
    func testWholeFileMismatchRejectsEvenWhenEveryChunkCRCIsValid() throws {
        let data=Array("file bytes".utf8),d=try RecordingDownload(record:info(data,crc:0),kind:2)
        d.awaitingData=true;try d.accept(block(d,data));XCTAssertThrowsError(try d.publish())
    }
}
