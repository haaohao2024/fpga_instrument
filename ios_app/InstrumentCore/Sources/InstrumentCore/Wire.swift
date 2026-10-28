import Foundation

public enum InstrumentError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
func require(_ condition: @autoclosure () -> Bool, _ text: String) throws {
    if !condition() { throw InstrumentError.invalid(text) }
}
public enum LE {
    public static func u16(_ b: [UInt8], _ i: Int) throws -> UInt16 {
        try require(i >= 0 && i + 2 <= b.count, "字段长度不足")
        return UInt16(b[i]) | UInt16(b[i+1]) << 8
    }
    public static func u32(_ b: [UInt8], _ i: Int) throws -> UInt32 {
        try require(i >= 0 && i + 4 <= b.count, "字段长度不足")
        var v: UInt32 = 0; for n in 0..<4 { v |= UInt32(b[i+n]) << (n*8) }; return v
    }
    public static func u64(_ b: [UInt8], _ i: Int) throws -> UInt64 {
        try require(i >= 0 && i + 8 <= b.count, "字段长度不足")
        var v: UInt64 = 0; for n in 0..<8 { v |= UInt64(b[i+n]) << (n*8) }; return v
    }
    public static func bytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        (0..<(T.bitWidth/8)).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }
    }
}
public enum ProtocolID {
    public static let service = "48990100-7f02-4ab6-a30c-99cc67269b19"
    public static let info = "48990101-7f02-4ab6-a30c-99cc67269b19"
    public static let channels = ["48990102-7f02-4ab6-a30c-99cc67269b19", "48990103-7f02-4ab6-a30c-99cc67269b19", "48990104-7f02-4ab6-a30c-99cc67269b19"]
    public static let status = "48990105-7f02-4ab6-a30c-99cc67269b19"
    public static let maxScore = 17_067_520
}
public struct Message: Equatable {
    public let channel: Int, opcode: Int
    public let session: [UInt8]
    public let sequence: UInt32
    public let payload: [UInt8]
    public init(channel: Int, opcode: Int, session: [UInt8], sequence: UInt32, payload: [UInt8] = []) {
        self.channel=channel; self.opcode=opcode; self.session=session; self.sequence=sequence; self.payload=payload
    }
}
public enum Wire {
    public static func crc(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = .max
        for x in b { c ^= UInt32(x); for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xedb88320 : c >> 1 } }
        return ~c
    }
    public static func encode(_ m: Message) throws -> [UInt8] {
        try require((0...3).contains(m.channel) && (0...255).contains(m.opcode), "通道或命令无效")
        try require(m.session.count == 16 && m.session.prefix(8).contains(where: {$0 != 0}) && m.session.suffix(8).contains(where: {$0 != 0}), "会话身份无效")
        try require(m.sequence != 0 && m.payload.count <= 512 && (m.channel >= 2 || m.payload.count + 36 <= 192), "消息长度或编号无效")
        var b: [UInt8] = [83,57,65,80,1,UInt8(m.channel),UInt8(m.opcode),0]
        b += m.session; b += LE.bytes(m.sequence); b += LE.bytes(UInt16(m.payload.count)); b += [0,0]; b += m.payload
        b += LE.bytes(crc(b)); return b
    }
    public static func decode(_ b: [UInt8]) throws -> Message {
        try require((36...548).contains(b.count), "消息长度无效")
        try require(Array(b.prefix(4)) == [83,57,65,80] && b[4] == 1 && b[5] <= 3 && b[7] == 0, "消息头无效")
        let n = Int(try LE.u16(b,28))
        try require(n + 36 == b.count && b[30] == 0 && b[31] == 0 && (b[5] >= 2 || b.count <= 192), "消息长度字段不符")
        let received = try LE.u32(b,b.count-4)
        try require(crc(Array(b.dropLast(4))) == received, "消息CRC不符")
        let sid = Array(b[8..<24]); let seq = try LE.u32(b,24)
        try require(seq != 0 && sid.prefix(8).contains(where: {$0 != 0}) && sid.suffix(8).contains(where: {$0 != 0}), "消息会话或编号无效")
        return Message(channel:Int(b[5]),opcode:Int(b[6]),session:sid,sequence:seq,payload:Array(b[32..<(32+n)]))
    }
    public static func fragments(_ m: Message, maxWrite: Int) throws -> [[UInt8]] {
        try require((20...244).contains(maxWrite), "GATT写长度无效")
        let b = try encode(m), capacity = maxWrite - 8
        return stride(from:0,to:b.count,by:capacity).map { offset in
            let count=min(capacity,b.count-offset)
            return LE.bytes(m.sequence) + LE.bytes(UInt16(offset)) + LE.bytes(UInt16(count)) + Array(b[offset..<(offset+count)])
        }
    }
}
public final class NotificationAssembler {
    private var bytes: [UInt8] = []
    private var sequence: UInt32 = 0
    private var began: UInt64 = 0, progressed: UInt64 = 0
    public private(set) var discarded = 0
    public init() {}
    public func reset() { bytes=[]; sequence=0; began=0; progressed=0 }
    public func push(_ f: [UInt8], now: UInt64) throws -> Message? {
        try require(f.count >= 9, "通知分包过短")
        let seq=try LE.u32(f,0), offset=Int(try LE.u16(f,4)), count=Int(try LE.u16(f,6))
        try require(seq != 0 && count > 0 && count+8 == f.count && offset+count <= 548, "通知分包头无效")
        if sequence != 0 && (now-progressed >= 250 || now-began >= 3000) { discarded += 1; reset() }
        if sequence != 0 && sequence != seq { try require(offset == 0,"通知编号跳变"); discarded += 1; reset() }
        if sequence == 0 { try require(offset == 0,"通知首包缺失"); sequence=seq; began=now; progressed=now }
        try require(offset <= bytes.count,"通知分包有缺口")
        let part=Array(f.dropFirst(8))
        if offset < bytes.count { try require(offset+count <= bytes.count && Array(bytes[offset..<(offset+count)]) == part,"重传内容不一致") }
        else { bytes += part; progressed=now }
        if bytes.count < 32 { return nil }
        let total=Int(try LE.u16(bytes,28))+36
        try require(total <= 548 && bytes.count <= total,"通知总长无效")
        guard bytes.count == total else { return nil }
        let m=try Wire.decode(bytes)
        try require(m.channel == 3 && m.sequence == sequence && [128,129,130,131,132].contains(m.opcode),"未知状态通知")
        let n=m.payload.count
        try require((m.opcode==128 && n==36)||(m.opcode==129 && (33...512).contains(n))||(m.opcode==130 && n==72)||([131,132].contains(m.opcode)&&n==64),"通知负载长度无效")
        reset(); return m
    }
}
