import Foundation

/// One immutable, sequential device file. A transport ACK and a data notice are independent.
/// A partial file is never returned to the caller for sharing.
public final class RecordingDownload {
    public let id: UInt64,kind: UInt8,total: UInt64,expectedCRC: UInt32,url: URL
    public private(set) var offset: UInt64=0
    public var awaitingResult=false,awaitingData=false
    public var requestedAt: UInt64=0,attempts=0
    private let handle: FileHandle
    private var crc: UInt32 = .max
    private var lastOffset: UInt64?,lastData: [UInt8]=[]
    public var nextLength: UInt16 { UInt16(min(480,total-offset)) }
    public var finished: Bool { offset==total && !awaitingData && !awaitingResult }
    public init(record: RecordInfo,kind: UInt8) throws {
        try require((1...2).contains(kind) && record.id != 0 && record.downloadable(kind),"录音尚未验证保存")
        self.id=record.id;self.kind=kind;total=kind==1 ? record.pcmBytes : record.eventBytes;expectedCRC=kind==1 ? record.pcmCRC : record.eventCRC
        try require(total>0,"文件为空")
        url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".partial")
        try require(FileManager.default.createFile(atPath:url.path,contents:nil),"无法创建临时文件")
        handle=try FileHandle(forWritingTo:url)
    }
    deinit { try? handle.close();try? FileManager.default.removeItem(at:url) }
    public func accept(_ b: [UInt8]) throws {
        guard b.count>=33,try LE.u64(b,0)==id,try LE.u64(b,16)==total,b[28]==kind,b[29]<=1,b[30]==0,b[31]==0 else { throw InstrumentError.invalid("文件块身份或长度不匹配") }
        let pos=try LE.u64(b,8),data=Array(b.dropFirst(32)),expected=try LE.u32(b,24)
        try require(Wire.crc(data)==expected,"文件块CRC不匹配")
        if pos<offset {
            try require(pos==lastOffset && data==lastData,"重传文件块内容不符");return
        }
        try require(awaitingData && pos==offset && data.count==Int(nextLength) && UInt64(data.count)<=total-offset,"文件块偏移或大小不匹配")
        try handle.write(contentsOf:Data(data))
        for x in data { crc ^= UInt32(x);for _ in 0..<8 { crc=crc & 1 == 1 ? (crc>>1)^0xedb88320 : crc>>1 } }
        lastOffset=offset;lastData=data;offset+=UInt64(data.count);awaitingData=false;attempts=0
    }
    public func publish() throws -> URL {
        try require(finished && ~crc==expectedCRC,"文件未完成或整文件CRC不匹配，未发布下载文件")
        try handle.synchronize();try handle.close()
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("录音_\(id).\(kind==1 ? "wav" : "evr")")
        if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
        try FileManager.default.moveItem(at:url,to:destination);return destination
    }
}
