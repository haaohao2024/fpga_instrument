import XCTest
@testable import InstrumentCore

final class ProtocolTests: XCTestCase {
    let sid: [UInt8] = [0xef,0xcd,0xab,0x89,0x67,0x45,0x23,1,19,0,0,0,0,0,0,0]
    func hex(_ s: String) -> [UInt8] {
        let a=Array(s);return stride(from:0,to:a.count,by:2).map{UInt8(String(a[$0..<$0+2]),radix:16)!}
    }
    func fixture(_ name: String) throws -> [[String]] {
        let url=Bundle.module.url(forResource:name,withExtension:"tsv",subdirectory:"Fixtures")!
        return try String(contentsOf:url,encoding:.utf8).split(separator:"\n").dropFirst().map{String($0).trimmingCharacters(in:.newlines).components(separatedBy:"\t")}
    }
    func testGoldenBytesFromAndroidAndFirmware() throws {
        let rows=try fixture("golden_messages");XCTAssertEqual(rows.count,21)
        for r in rows {
            let m=Message(channel:Int(r[1])!,opcode:Int(r[2])!,session:sid,sequence:UInt32(r[0])!,payload:hex(r[3]))
            XCTAssertEqual(try Wire.encode(m),hex(r[4]),"vector \(r[0])")
            XCTAssertEqual(try Wire.decode(hex(r[4])),m)
        }
        XCTAssertEqual(Wire.crc(Array("123456789".utf8)),0xcbf43926)
    }
    func testAllExistingSemanticRanges() throws {
        let rows=try fixture("semantic_ranges");XCTAssertEqual(rows.count,1062)
        for (i,r) in rows.enumerated() {
            let m=try Wire.decode(hex(r[1]));XCTAssertEqual(RequestRules.error(m),Int(r[0])!,"vector \(i+1) op \(m.opcode)")
        }
    }
    func testBadCRCSessionAndTruncatedData() throws {
        let m=Message(channel:1,opcode:2,session:sid,sequence:1)
        var b=try Wire.encode(m);b[32]^=1;XCTAssertThrowsError(try Wire.decode(b))
        XCTAssertThrowsError(try Wire.decode(Array(b.dropLast())))
        XCTAssertThrowsError(try Wire.encode(Message(channel:1,opcode:2,session:Array(repeating:0,count:16),sequence:1)))
        XCTAssertThrowsError(try LE.u64([1,2,3],0))
    }
    func testAllNoticeTypesAtMinimumAndLargeWrites() throws {
        for (op,n) in [(128,36),(129,512),(130,72),(131,64),(132,64)] {
            for maxWrite in [20,244] {
                let m=Message(channel:3,opcode:op,session:sid,sequence:7,payload:(0..<n).map{UInt8(truncatingIfNeeded:$0)})
                let a=NotificationAssembler();var received: Message?
                for f in try Wire.fragments(m,maxWrite:maxWrite) { received=try a.push(f,now:1) }
                XCTAssertEqual(received,m)
            }
        }
    }
    func testGapDuplicateAndTimeout() throws {
        let m=Message(channel:3,opcode:131,session:sid,sequence:9,payload:Array(repeating:0,count:64))
        let f=try Wire.fragments(m,maxWrite:20),a=NotificationAssembler()
        XCTAssertNil(try a.push(f[0],now:0));XCTAssertNil(try a.push(f[0],now:1))
        XCTAssertThrowsError(try a.push(f[2],now:2))
        a.reset();_ = try a.push(f[0],now:0)
        XCTAssertThrowsError(try a.push(f[1],now:250))
        a.reset();var output: Message?
        for (i,p) in f.enumerated() { output=try a.push(p,now:UInt64(i)) };XCTAssertEqual(output,m)
    }
    func result(_ sent: Message, phase: Int=3, sid override: [UInt8]?=nil) -> Message {
        var p=LE.bytes(sent.sequence)+[UInt8(sent.channel),UInt8(phase),0,0]
        p += LE.bytes(UInt32(33));p += Array(repeating:0,count:20);p += LE.bytes(UInt32(phase==4 ? 1 : 0))
        return Message(channel:3,opcode:128,session:override ?? sid,sequence:90,payload:p)
    }
    func testRealExecutionFeedbackAndIdentityPreservation() throws {
        var sent: [Message]=[];var failure="";var time: UInt64=0
        let c=ClientSession(send:{sent.append($0);return true},terminate:{failure=$0},show:{_ in},clock:{time})
        try c.ready(sid);XCTAssertTrue(c.press(key:0,note:60,pressure:160));XCTAssertEqual(c.pendingCount,1)
        let on=sent[0];c.release(key:0);let off=sent[1]
        XCTAssertEqual(try LE.u64(on.payload,0),try LE.u64(off.payload,0));XCTAssertEqual(c.pendingCount,2)
        c.result(result(on,sid:Array(sid.reversed())));XCTAssertEqual(c.pendingCount,2)
        c.result(result(on));c.result(result(off));XCTAssertEqual(c.pendingCount,0)
        time=101;c.tick();XCTAssertEqual(sent.last?.opcode,2);XCTAssertEqual(failure,"")
        let id: UInt64=0xfedcba9876543210
        XCTAssertEqual(try LE.u64(Commands.event(id:id,kind:1,key:31,note:100,value:255),0),id)
    }
    func testPitchBarrierAndFrozenRetry() throws {
        var sent: [Message]=[];var time: UInt64=0
        let c=ClientSession(send:{sent.append($0);return true},terminate:{_ in},show:{_ in},clock:{time})
        try c.ready(sid);XCTAssertTrue(c.pitchParameter(opcode:32,value:5));XCTAssertFalse(c.pitchReady)
        XCTAssertFalse(c.press(key:1,note:61,pressure:200))
        let config=sent[0],barrier=sent[1];c.result(result(config));XCTAssertFalse(c.pitchReady)
        time=2001;c.tick();XCTAssertEqual(sent.filter{$0.opcode==40},[barrier,barrier])
        c.result(result(barrier));XCTAssertTrue(c.pitchReady)
        XCTAssertTrue(c.press(key:1,note:61,pressure:200))
    }
    func testSchedulerSerializesAndBoundsFiles() throws {
        let s=WriteScheduler(),file=Message(channel:2,opcode:65,session:sid,sequence:1,payload:Array(repeating:0,count:512))
        XCTAssertTrue(try s.enqueue(file,maxWrite:20));XCTAssertFalse(try s.enqueue(file,maxWrite:20))
        let note=Message(channel:0,opcode:16,session:sid,sequence:2,payload:try Commands.event(id:1,kind:1,key:0,note:60,value:100))
        XCTAssertTrue(try s.enqueue(note,maxWrite:20));let first=try XCTUnwrap(s.next(now:0));XCTAssertEqual(first.channel,0)
        XCTAssertEqual(try s.next(now:100)?.bytes,first.bytes)
        try s.acknowledged();XCTAssertNotNil(try s.next(now:100));XCTAssertThrowsError(try s.next(now:3100))
    }
    func testHardwareCountersAreNotSoftwareNoteCounts() throws {
        let b: [UInt8]=[1,32,12,9,11,16,32,0]+LE.bytes(UInt16(306))+LE.bytes(UInt16(512))+LE.bytes(UInt32.max)
        let m=try VoiceMetrics(b);XCTAssertEqual(m.allocated,12);XCTAssertEqual(m.gated,9);XCTAssertEqual(m.cycles,306);XCTAssertEqual(m.frame,UInt32.max)
        var bad=b;bad[1]=31;XCTAssertThrowsError(try VoiceMetrics(bad))
    }
    func testExpandedCapacityUsesHardwareDeclaration() throws {
        for capacity in [UInt8(32),48,64] {
            var b: [UInt8]=[1,capacity,capacity,capacity,capacity,capacity,capacity,0]
                + LE.bytes(UInt16(306)) + LE.bytes(UInt16(512)) + LE.bytes(UInt32(7))
            let m=try VoiceMetrics(b)
            XCTAssertEqual(m.capacity,Int(capacity));XCTAssertEqual(m.completed,Int(capacity))
            for index in 2...6 {
                var bad=b;bad[index]=capacity+1;XCTAssertThrowsError(try VoiceMetrics(bad))
            }
            b[1]=33;XCTAssertThrowsError(try VoiceMetrics(b))
        }
    }
    func testLoopBeginWaitsForAppliedTimbreAndDoesNotDoubleStart() throws {
        var sent:[Message]=[]
        let c=ClientSession(send:{sent.append($0);return true},terminate:{_ in},show:{_ in},clock:{0})
        try c.ready(sid)
        XCTAssertTrue(c.beginLoop(timbre:5));XCTAssertFalse(c.beginLoop(timbre:3))
        XCTAssertEqual(sent.map{$0.opcode},[32,40]);XCTAssertEqual(sent[0].payload,[5])
        c.result(result(sent[0]));XCTAssertFalse(sent.contains{$0.opcode==96})
        c.result(result(sent[1]));XCTAssertEqual(sent.last?.opcode,96);XCTAssertEqual(sent.last?.payload,[5])
        XCTAssertFalse(c.loopPreparing)
    }
    func testDisconnectedLoopPreparationNeverRecordsIntoNewSession() throws {
        var sent:[Message]=[]
        let c=ClientSession(send:{sent.append($0);return true},terminate:{_ in},show:{_ in},clock:{0})
        try c.ready(sid);XCTAssertTrue(c.beginLoop(timbre:3));let old=sent[1]
        c.disconnected();try c.ready(Array(sid.reversed()));c.result(result(old))
        XCTAssertFalse(sent.contains{$0.opcode==96});XCTAssertFalse(c.loopPreparing)
    }

}
