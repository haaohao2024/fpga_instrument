import XCTest
@testable import InstrumentCore

final class MonoRecordingTests: XCTestCase {
    func payload(pairs: UInt64,bytes: UInt64,phase: UInt8=5,error: Int32=0) -> [UInt8] {
        var p=Array(repeating:UInt8(0),count:72)
        p[0]=42;p[8]=phase;p[9]=phase==1 ? 2 : 4;p[10]=1;p[11]=phase==5 ? 1 : phase==7 ? 4 : 0
        p.replaceSubrange(12..<16,with:LE.bytes(UInt32(bitPattern:error)))
        p.replaceSubrange(16..<24,with:LE.bytes(pairs))
        p.replaceSubrange(32..<40,with:LE.bytes(bytes));return p
    }
    func testBoardMonoCaptureCanAdvanceToVerifiedSaved() throws {
        // Counts from the real App recording after rollback, 2026-10-26.
        var state=try RecordInfo(payload(pairs:462286,bytes:925084,phase:1))
        XCTAssertEqual(state.phase,1);XCTAssertFalse(state.downloadable(1))
        state=try RecordInfo(payload(pairs:462286,bytes:925084))
        XCTAssertEqual(state.phase,5);XCTAssertEqual(state.error,0)
        XCTAssertEqual(state.pcmChannels,1);XCTAssertTrue(state.downloadable(1))
        XCTAssertTrue(state.summary.contains("已验证保存"));XCTAssertTrue(state.summary.contains("单声道"))
    }
    func testLegacyStereoAndEmptyHeaderRemainCompatible() throws {
        let stereo=try RecordInfo(payload(pairs:462286,bytes:1849656))
        XCTAssertEqual(stereo.pcmChannels,2);XCTAssertTrue(stereo.downloadable(1))
        let empty=try RecordInfo(payload(pairs:0,bytes:512))
        XCTAssertNil(empty.pcmChannels);XCTAssertTrue(empty.downloadable(1))
    }
    func testBadLengthsOverflowAndUnverifiedFilesStayRejected() throws {
        for size: UInt64 in [925083,925085,1849655] {
            XCTAssertThrowsError(try RecordInfo(payload(pairs:462286,bytes:size)))
        }
        XCTAssertThrowsError(try RecordInfo(payload(pairs:.max,bytes:512)))
        let failed=try RecordInfo(payload(pairs:0,bytes:0,phase:7,error:-12))
        XCTAssertEqual(failed.error,-12);XCTAssertFalse(failed.downloadable(1))
    }
    func testMonoAndStereoDownloadsKeepActualWavBytes() throws {
        for channels in [1,2] {
            let frameBytes=2*channels,frames=4
            var wav=Array(repeating:UInt8(0),count:512+frames*frameBytes)
            func put(_ at: Int,_ bytes: [UInt8]) { wav.replaceSubrange(at..<at+bytes.count,with:bytes) }
            put(0,Array("RIFF".utf8));put(4,LE.bytes(UInt32(wav.count-8)))
            put(8,Array("WAVEfmt ".utf8));put(16,LE.bytes(UInt32(16)))
            put(20,LE.bytes(UInt16(1)));put(22,LE.bytes(UInt16(channels)))
            put(24,LE.bytes(UInt32(48000)));put(28,LE.bytes(UInt32(48000*frameBytes)))
            put(32,LE.bytes(UInt16(frameBytes)));put(34,LE.bytes(UInt16(16)))
            put(36,Array("JUNK".utf8));put(40,LE.bytes(UInt32(460)))
            put(504,Array("data".utf8));put(508,LE.bytes(UInt32(frames*frameBytes)))
            for i in 512..<wav.count { wav[i]=UInt8(truncatingIfNeeded:i*37) }
            var p=payload(pairs:UInt64(frames),bytes:UInt64(wav.count))
            p.replaceSubrange(48..<52,with:LE.bytes(Wire.crc(wav)))
            let d=try RecordingDownload(record:RecordInfo(p),kind:1)
            while d.offset<d.total {
                let at=d.offset,n=Int(d.nextLength),part=Array(wav[Int(at)..<Int(at)+n])
                d.awaitingData=true;d.awaitingResult=true
                var block: [UInt8]=LE.bytes(d.id)
                block += LE.bytes(at);block += LE.bytes(d.total)
                block += LE.bytes(Wire.crc(part));block += [1,0,0,0];block += part
                try d.accept(block);XCTAssertFalse(d.finished)
                d.awaitingResult=false
            }
            let url=try d.publish();defer{try? FileManager.default.removeItem(at:url)}
            let saved=Array(try Data(contentsOf:url))
            XCTAssertEqual(saved,wav);XCTAssertEqual(try LE.u16(saved,22),UInt16(channels))
            XCTAssertEqual(try LE.u32(saved,24),48000)
        }
    }
}
