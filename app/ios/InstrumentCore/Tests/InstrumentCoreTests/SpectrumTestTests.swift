import XCTest
@testable import InstrumentCore

final class SpectrumTestTests: XCTestCase {
    let sid: [UInt8]=[1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0]
    func result(_ m: Message, _ phase: Int=3) -> Message {
        var p=LE.bytes(m.sequence)+[UInt8(m.channel),UInt8(phase),0,0]
        p += LE.bytes(UInt32(1))
        p += Array(repeating:0,count:20)
        p += LE.bytes(UInt32(phase==4 ? 1 : 0))
        return Message(channel:3,opcode:128,session:sid,sequence:1,payload:p)
    }
    func testNativeCommandsMatchField48FirmwareAndRejectUnsupportedCounts() throws {
        for n in SpectrumTest.sizes+[0] {
            let p=try SpectrumTest.nativeCommand(n)
            XCTAssertEqual(p,[n==0 ? 2 : 1,UInt8(n),0,0,0,0,0,0])
            XCTAssertEqual(RequestRules.error(Message(channel:1,opcode:86,session:sid,sequence:1,payload:p)),0)
        }
        for n in [-1,4,47,49,63,65] { XCTAssertThrowsError(try SpectrumTest.nativeCommand(n)) }
    }
    func testSustained32WaitsForConfigurationAndAllNoteAcknowledgments() throws {
        var sent: [Message]=[];var failure=""
        let c=ClientSession(send:{sent.append($0);return true},terminate:{failure=$0},show:{_ in},clock:{0})
        try c.ready(sid)
        let t=SpectrumTest(client:c)
        XCTAssertTrue(t.start(32));XCTAssertFalse(t.start(8))
        XCTAssertEqual(sent.map{$0.opcode},[35]);XCTAssertEqual(t.state,.preparing(32))
        c.result(result(sent[0],4))
        XCTAssertEqual(sent.last?.opcode,16);XCTAssertEqual(sent.last?.payload[8],4)
        c.result(result(sent[1]))
        XCTAssertEqual(sent.suffix(2).map{$0.opcode},[32,40])
        c.result(result(sent[2]));XCTAssertEqual(c.heldKeys.count,0)
        c.result(result(sent[3]))
        var cursor=4
        while cursor<sent.count { let m=sent[cursor];cursor+=1;c.result(result(m)) }
        let ons=sent.filter{$0.channel==0 && $0.payload[8]==1}
        XCTAssertEqual(ons.count,32)
        XCTAssertEqual(Set(ons.map{Int($0.payload[10])}),Set(48...79))
        XCTAssertEqual(Set(try ons.map{try LE.u64($0.payload,0)}).count,32)
        XCTAssertEqual(t.state,.submitted(32));XCTAssertEqual(c.heldKeys.count,32)
        t.stop();XCTAssertEqual(t.state,.idle);XCTAssertTrue(c.heldKeys.isEmpty)
        while cursor<sent.count { let m=sent[cursor];cursor+=1;c.result(result(m)) }
        let offs=sent.filter{$0.channel==0 && $0.payload[8]==2}
        XCTAssertEqual(Set(try ons.map{try LE.u64($0.payload,0)}),Set(try offs.map{try LE.u64($0.payload,0)}))
        XCTAssertEqual(failure,"")
    }
    func testStoppingDuringPreparationCannotStartLateNotes() throws {
        var sent: [Message]=[]
        let c=ClientSession(send:{sent.append($0);return true},terminate:{_ in},show:{_ in},clock:{0})
        try c.ready(sid);let t=SpectrumTest(client:c)
        XCTAssertTrue(t.start(8));t.stop();c.result(result(sent[0],4))
        XCTAssertEqual(sent.count,1);XCTAssertEqual(t.state,.idle)
        c.disconnected();t.disconnected();XCTAssertFalse(t.start(32))
    }
    func test48UsesOneNativeCommandInsteadOfAliasing32PhoneKeys() throws {
        var sent: [Message]=[]
        let c=ClientSession(send:{sent.append($0);return true},terminate:{_ in},show:{_ in},clock:{0})
        try c.ready(sid);let t=SpectrumTest(client:c)
        XCTAssertTrue(t.start(48));c.result(result(sent[0],4));c.result(result(sent[1]))
        c.result(result(sent[2]));c.result(result(sent[3]))
        XCTAssertEqual(sent.last?.opcode,86);XCTAssertEqual(sent.last?.payload,[1,48,0,0,0,0,0,0])
        XCTAssertTrue(c.heldKeys.isEmpty);XCTAssertEqual(t.state,.preparing(48))
        c.result(result(sent.last!,4));XCTAssertEqual(t.state,.submitted(48))
        t.stop();XCTAssertEqual(sent.last?.opcode,86);XCTAssertEqual(sent.last?.payload,[2,0,0,0,0,0,0,0])
        XCTAssertEqual(SpectrumTest.notes(48).count,48)
        XCTAssertEqual(Set(SpectrumTest.notes(48).map{SpectrumTest.frequency($0)}).count,48)
    }
    func testFrequencyPlanIsDistinctAndWithinAudibleRange() {
        let notes=SpectrumTest.notes(32), hz=notes.map{SpectrumTest.frequency($0)}
        XCTAssertEqual(hz.count,32);XCTAssertEqual(Set(hz).count,32)
        XCTAssertEqual(SpectrumTest.frequency(69),440,accuracy:0.00001)
        XCTAssertGreaterThan(hz.first!,130);XCTAssertLessThan(hz.last!,800)
    }
}
