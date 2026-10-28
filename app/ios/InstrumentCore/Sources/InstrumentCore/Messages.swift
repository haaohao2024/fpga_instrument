import Foundation

public enum Commands {
    public static func event(id: UInt64, kind: Int, key: Int, note: Int, value: Int) throws -> [UInt8] {
        try require((1...4).contains(kind) && (0...127).contains(note) && (0...255).contains(value),"音符参数无效")
        if kind==4 { try require(id==0 && key==255 && note==0,"颤音事件无效") }
        else {
            try require(id != 0 && (0..<32).contains(key),"按键身份无效")
            try require(kind != 1 || value > 0,"起音力度无效")
            try require(kind != 2 || (note==0 && value==0),"松键参数无效")
        }
        return LE.bytes(id)+[UInt8(kind),UInt8(key),UInt8(note),UInt8(value),0,0,0,0]
    }
    public static func gain(local: Int, external: Int, muteLocal: Bool, muteExternal: Bool) throws -> [UInt8] {
        try require((0...32768).contains(local) && (0...32768).contains(external),"增益范围无效")
        return LE.bytes(UInt16(local))+LE.bytes(UInt16(external))+[UInt8((muteLocal ? 1 : 0)|(muteExternal ? 2 : 0)),0,0,0]
    }
    public static func ensemble(level: Int, root: Int, minor: Bool, bpm: Int, style: Int) throws -> [UInt8] {
        try require((0...2).contains(level) && (0...11).contains(root) && (50...180).contains(bpm) && (0...2).contains(style),"合奏设置范围无效")
        return [1,UInt8(level),UInt8(root),minor ? 1 : 0]+LE.bytes(UInt16(bpm))+[UInt8(style),0]
    }
    public static func effects(_ w: [UInt32]) throws -> [UInt8] {
        try require(w.count==11,"效果参数个数无效")
        try require(w[0]<=127 && (1...16383).contains(w[1]) && w[2]<=24576,"回声参数无效")
        try require((96...1440).contains(w[3]) && w[4]<=480 && w[3]>=w[4]+2 && w[3]+w[4]<=1920,"合唱长度无效")
        try require(w[5]==0 || (4474...447392).contains(w[5]),"合唱速度无效")
        try require(w[6]<=28672 && w[7]<=28672 && w[8...10].allSatisfy{$0<=8192},"效果反馈或返回增益无效")
        return w.flatMap{LE.bytes($0)}
    }
    public static func keymap(_ notes: [Int]) throws -> [UInt8] {
        try require(notes.count==8 && notes.allSatisfy{(24...103).contains($0)},"8键音高范围无效")
        return notes.map(UInt8.init)
    }
    public static func recordingStart(id: UInt64, mask: UInt8) throws -> [UInt8] {
        try require(id != 0 && (1...3).contains(mask),"录音身份或类型无效")
        return LE.bytes(id)+[mask]+Array(repeating:0,count:7)
    }
    public static func fileBlock(id: UInt64, offset: UInt64, length: UInt16, kind: UInt8) throws -> [UInt8] {
        try require(id != 0 && (1...480).contains(length) && (1...2).contains(kind),"文件下载参数无效")
        return LE.bytes(id)+LE.bytes(offset)+LE.bytes(length)+[kind,0]
    }
}

public enum RequestRules {
    public static func error(_ m: Message) -> Int {
        do { return try checked(m) } catch { return -4 }
    }
    private static func checked(_ m: Message) throws -> Int {
        let p=m.payload, n=p.count, op=m.opcode
        func zero(_ from: Int) -> Bool { p.dropFirst(from).allSatisfy{$0==0} }
        func ok(_ b: Bool) -> Int { b ? 0 : -4 }
        if m.channel==0 {
            if op != 16 || n==0 || n%16 != 0 || n>144 { return -2 }
            for i in stride(from:0,to:n,by:16) {
                let id=try LE.u64(p,i), k=p[i+8], key=p[i+9], note=p[i+10], value=p[i+11]
                if !(1...4).contains(k) || note>127 || !p[(i+12)..<(i+16)].allSatisfy({$0==0}) { return -4 }
                if k==4 { if id != 0 || key != 255 || note != 0 { return -4 } }
                else if id==0 || key>=32 || (k==1 && value==0) || (k==2 && (note != 0 || value != 0)) { return -4 }
            }
            return 0
        }
        if m.channel==1 {
            switch op {
            case 1,2,3,41,97,98,99,100,101,102,105,106: return n==0 ? 0 : -1
            case 4: return try ok(n==5 && p[0]<=2 && LE.u32(p,1) != 0)
            case 40: return try ok(n==8 && p[0]<=1 && (3...5).contains(p[1]) && p[2]==0 && p[3]==0 && LE.u32(p,4) != 0)
            case 96: return ok(n==1 && p[0]<=5)
            case 104: return try ok(n==8 && p[0]==1 && p[1]<=2 && p[2]<=11 && p[3]<=1 && (50...180).contains(LE.u16(p,4)) && p[6]<=2 && p[7]==0)
            case 32: return ok(n==1 && p[0]<=5)
            case 33: return ok(n==1 && p[0]<=11)
            case 34: return try ok(n==16 && LE.u64(p,0) != 0 && LE.u16(p,10)<=256 && zero(12))
            case 36: return try ok(n==8 && LE.u16(p,0)<=32768 && LE.u16(p,2)<=32768 && p[4]<=3 && zero(5))
            case 37: return n==8 ? ok(p.allSatisfy{(24...103).contains($0)}) : -1
            case 39: return try ok(n==9 && p[0]<32 && LE.u64(p,1) != 0)
            case 38: return ok(n==8 && zero(2) && ((p[0]==1 && p[1]<=3)||(p[0]==6 && p[1]<=1)||((3...5).contains(p[0]) && p[1]==0)))
            case 35:
                if n != 44 { return -1 }
                _ = try Commands.effects((0..<11).map{try LE.u32(p,$0*4)}); return 0
            case 86: return ok(n==8 && zero(2) && ((p[0]==1 && [1,8,16,32,48].contains(p[1]))||(p[0]==2 && p[1]==0)))
            default: return -2
            }
        }
        if m.channel==2 {
            switch op {
            case 80: return try ok(n==16 && LE.u64(p,0) != 0 && (1...3).contains(p[8]) && zero(9))
            case 81,84,85: return try ok(n==8 && LE.u64(p,0) != 0)
            case 82: return n==8 ? 0 : -4
            case 83: return try ok(n==20 && LE.u64(p,0) != 0 && LE.u64(p,8)<=1_073_742_336 && (1...480).contains(LE.u16(p,16)) && (1...2).contains(p[18]) && p[19]==0)
            case 64:
                guard n==16 else { return -4 }; let size=try LE.u32(p,0)
                return ok((1024...UInt32(ProtocolID.maxScore)).contains(size) && size%512==0 && zero(8))
            case 65:
                guard (13...512).contains(n) else { return -4 }; let offset=try LE.u64(p,0)
                guard offset<=UInt64(ProtocolID.maxScore) && UInt64(n-12)<=UInt64(ProtocolID.maxScore)-offset else { return -4 }
                return try Wire.crc(Array(p.dropFirst(12))) == LE.u32(p,8) ? 0 : -3
            case 66,67: return n==0 ? 0 : -1
            default: return -2
            }
        }
        return -2
    }
}

public struct DeviceInfo {
    public let session: [UInt8], ready: Bool, linkState: UInt8
    public init(_ b: [UInt8]) throws {
        try require(b.count==64 && Array(b.prefix(4))==[83,57,73,78] && b[4]==1,"设备INFO格式无效")
        let crc=try LE.u32(b,60)
        try require(Wire.crc(Array(b.prefix(60)))==crc,"设备INFO CRC无效")
        let maxMessage=try LE.u16(b,24), maxControl=try LE.u16(b,26)
        try require(maxMessage==548 && maxControl==192,"设备协议容量不兼容")
        linkState=b[5]; ready=b[5]==2; session=Array(b[8..<24])
        if ready { try require(session.prefix(8).contains{$0 != 0} && session.suffix(8).contains{$0 != 0},"设备未提供有效会话") }
    }
}
public struct VoiceMetrics: Equatable {
    public let capacity: Int, allocated: Int, gated: Int, nonzero: Int, peak: Int, completed: Int, faults: Int, cycles: Int
    public let frame: UInt32
    public init(_ b: [UInt8]) throws {
        try require(b.count==16,"硬件统计长度无效")
        let window=try LE.u16(b,10), c=try LE.u16(b,8)
        try require(b[0]==1 && [32,48,64].contains(b[1]) && b[2...6].allSatisfy{$0<=b[1]} && b[7]<=3 && window==512 && (1...511).contains(c),"硬件统计格式无效")
        capacity=Int(b[1]);allocated=Int(b[2]);gated=Int(b[3]);nonzero=Int(b[4]);peak=Int(b[5]);completed=Int(b[6]);faults=Int(b[7]);cycles=Int(c);frame=try LE.u32(b,12)
    }
}
public struct ExecutionResult {
    public let sequence: UInt32, channel: Int, phase: Int, error: Int, effectiveFrame: UInt32?, flags: UInt32, diagnostic: UInt32
    public let instance: UInt64, generation: UInt16, metrics: VoiceMetrics?
    public var saved: Bool { flags & 4 != 0 }
    public init(_ m: Message) throws {
        let b=m.payload
        try require(m.channel==3 && m.opcode==128 && b.count==36,"执行反馈格式无效")
        sequence=try LE.u32(b,0);channel=Int(b[4]);phase=Int(b[5]);error=Int(Int16(bitPattern:try LE.u16(b,6)))
        flags=try LE.u32(b,32);diagnostic=try LE.u32(b,28);instance=try LE.u64(b,16);generation=try LE.u16(b,24)
        try require(sequence != 0 && channel<=2 && (1...7).contains(phase) && (-13...0).contains(error) && flags & ~15 == 0,"执行反馈字段无效")
        try require(flags & 8 == 0 || (flags==8 && channel==1 && phase==3 && error==0),"硬件统计反馈类型无效")
        try require(flags & 4 == 0 || (channel==2 && phase==4 && error==0),"保存反馈类型无效")
        try require(phase != 4 || flags & 5 != 0,"执行反馈缺少生效证据")
        try require(phase != 7 || error < 0,"拒绝反馈缺少错误码")
        try require(flags & 2 == 0 || instance != 0,"实例身份无效")
        effectiveFrame=flags & 1 != 0 ? try LE.u32(b,8) : nil
        metrics=flags & 8 != 0 ? try VoiceMetrics(Array(b[16..<32])) : nil
    }
    public var description: String {
        switch phase {
        case 1: return "设备已收到"
        case 2: return "设备已接受，处理中"
        case 3: return "已提交"
        case 4: return saved ? "已校验保存" : "已生效"
        case 5: return "音量已到目标"
        case 6: return "已取消"
        default: return "已拒绝，错误码 \(error)"
        }
    }
}
public struct LoopInfo {
    public let sampleRate: Double
    public let state: Int, layers: Int, length: UInt64, events: UInt32
    public let error: Int, reason: Int
    public init(_ p: [UInt8]) throws {
        try require(p.count==64 && (p[0]==1 || p[0]==2 || p[0]==3) && p[1]<=7 && p[2]<=4,"循环状态无效")
        sampleRate=p[0]==3 ? 128000 : p[0]==2 ? 96000 : 48000
        error=Int(Int32(bitPattern:try LE.u32(p,8)));reason=Int(p[59])
        state=Int(p[1]);layers=Int(p[2]);length=try LE.u64(p,24);events=try LE.u32(p,32)
    }
    public var description: String { ["空闲","录第一层","循环播放","录下一层","等待尾音","已停止","正在切换","错误"][state] }
}
public struct EnsembleInfo {
    public let state: Int, level: Int, bpm: UInt16, generated: UInt32, observed: UInt32, skipped: UInt32, human: Int, slots: Int, reason: Int
    public init(_ p: [UInt8]) throws {
        try require(p.count==64 && p[0]==1 && p[1]<=3 && p[2]<=2 && p[3]<=11 && p[4]<=1 && p[32]<=48 && p[33]<=16,"合奏状态无效")
        state=Int(p[1]);level=Int(p[2]);bpm=try LE.u16(p,6);generated=try LE.u32(p,16);observed=try LE.u32(p,20);skipped=try LE.u32(p,24);human=Int(p[32]);slots=Int(p[33]);reason=Int(p[35])
    }
    public var description: String { ["未运行","准备中","运行中","已停止并报告异常"][state] }
}
public struct RecordInfo {
    public let id: UInt64, phase: Int, mask: UInt8, flags: UInt8, error: Int, pcmPairs: UInt64, eventCells: UInt64, pcmBytes: UInt64, eventBytes: UInt64, pcmCRC: UInt32, eventCRC: UInt32
    public init(_ p: [UInt8]) throws {
        try require(p.count==72 && p[8]<=7 && p[9]<=6 && p[10]<=3 && p[11] & 248 == 0,"录音状态格式无效")
        id=try LE.u64(p,0);phase=Int(p[8]);mask=p[10];flags=p[11];error=Int(Int32(bitPattern:try LE.u32(p,12)));pcmPairs=try LE.u64(p,16);eventCells=try LE.u64(p,24);pcmBytes=try LE.u64(p,32);eventBytes=try LE.u64(p,40);pcmCRC=try LE.u32(p,48);eventCRC=try LE.u32(p,52)
        try require(pcmBytes<=1_073_742_336 && eventBytes<=UInt64(UInt32.max) && (flags & 3) & ~mask == 0,"录音文件范围无效")
        try require(phase != 5 || (error==0 && flags & 4 == 0),"录音尚未验证保存")
        try require(flags & 3 == 0 || (phase==5 && flags & 4 == 0),"文件就绪状态不符")
        // The frame counter still counts incoming FPGA stereo pairs. Current
        // firmware downmixes each pair to one Int16 when writing the WAV;
        // older recordings retain both channels. No wire format change.
        if flags & 1 != 0 {
            try require(pcmPairs <= 536_870_912 &&
                (pcmBytes==512+2*pcmPairs || pcmBytes==512+4*pcmPairs),"WAV长度不符")
        }
    }
    public var pcmChannels: Int? {
        guard flags & 1 != 0 && pcmPairs>0 else { return nil }
        return pcmBytes==512+2*pcmPairs ? 1 : 2
    }
    public func downloadable(_ kind: UInt8) -> Bool { phase==5 && flags & 4 == 0 && mask & kind != 0 && flags & kind != 0 }
    public var description: String { ["空闲","正在采集","正在排空","已关闭","等待停止伴奏后校验","已验证保存","不完整","错误"][phase] }
    public var summary: String {
        let format=pcmChannels.map { $0==1 ? "，单声道" : "，双声道" } ?? ""
        return "\(description)\n记录 \(id)，错误码 \(error)\(format)"
    }
}
