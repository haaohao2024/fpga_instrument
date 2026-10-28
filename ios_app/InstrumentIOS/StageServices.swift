import Foundation
import AudioToolbox
import InstrumentCore

/// Phone-side click for the metronome and the loop count-in. The click comes
/// from the phone; Bluetooth adds a little latency relative to the board.
final class Metronome {
    private var timer: Timer?
    func start(bpm: Int) {
        stop()
        timer=Timer.scheduledTimer(withTimeInterval:60.0/Double(max(bpm,30)),repeats:true) { _ in AudioServicesPlaySystemSound(1104) }
        AudioServicesPlaySystemSound(1104)
    }
    func stop() { timer?.invalidate();timer=nil }
    /// Plays `beats` clicks, then calls `done` on the following beat.
    func countIn(bpm: Int,beats: Int,done: @escaping ()->Void) {
        var left=beats
        let interval=60.0/Double(max(bpm,30))
        AudioServicesPlaySystemSound(1104);left-=1
        Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { t in
            if left>0 { AudioServicesPlaySystemSound(1104);left-=1 } else { t.invalidate();done() }
        }
    }
}

/// SCORE.EVT upload, paced by acknowledgements: STOP the score, BEGIN, DATA
/// blocks of 500 bytes, then COMMIT, which the board confirms with SAVED.
final class ScoreUploader {
    private let client: ClientSession
    private let show: (String)->Void
    private var bytes: [UInt8]?
    private var offset=0
    private var token=0
    private var cancelling=false
    var active: Bool { bytes != nil }
    init(client: ClientSession,show: @escaping (String)->Void) { self.client=client;self.show=show }

    @discardableResult func start(_ file: [UInt8]) -> Bool {
        guard !active, client.connected else { show("请先连接乐器，并等待上一项文件操作结束");return false }
        guard (1024...ProtocolID.maxScore).contains(file.count), file.count%512==0 else {
            show("这不是有效的 SCORE.EVT：大小必须是 512 字节的整数倍，且不小于 1024 字节");return false
        }
        bytes=file;offset=0;cancelling=false;token+=1;let t=token
        show("正在停止当前曲谱；尚未写卡")
        let stop=client.command(opcode:38,payload:[3,0,0,0,0,0,0,0],label:"上传前停止曲谱",target:3,
            completed:{[weak self] _ in guard let self=self, t==self.token else { return };self.begin(t) },
            rejected:{[weak self] _ in guard let self=self, t==self.token else { return };self.fail("停止曲谱被拒绝，未开始上传") })
        if stop==nil { fail("停止曲谱无法排队，未开始上传");return false }
        return true
    }
    private func begin(_ t: Int) {
        guard let f=bytes else { return }
        if cancelling { finish("上传已取消，未提交文件");return }
        let payload=LE.bytes(UInt32(f.count))+LE.bytes(Wire.crc(f))+[UInt8](repeating:0,count:8)
        let sent=client.command(channel:2,opcode:64,payload:payload,label:"开始曲谱暂存",target:3,
            completed:{[weak self] _ in guard let self=self, t==self.token else { return };self.next(t) },
            rejected:{[weak self] _ in guard let self=self, t==self.token else { return };self.fail("设备拒绝上传") })
        if sent==nil { fail("文件通道忙，未开始上传") }
    }
    private func next(_ t: Int) {
        guard let f=bytes else { return }
        if cancelling { sendCancel(t);return }
        if offset==f.count {
            show("等待乐器回读校验并替换 SCORE.EVT")
            let sent=client.command(channel:2,opcode:66,label:"校验并保存曲谱",target:4,
                completed:{[weak self] r in guard let self=self, t==self.token else { return }
                    if r.saved { self.finish("SCORE.EVT 已由乐器确认保存") } else { self.fail("乐器没有返回“已保存”，不能确认上传成功") } },
                rejected:{[weak self] _ in guard let self=self, t==self.token else { return };self.fail("曲谱保存失败") })
            if sent==nil { fail("保存请求无法排队") }
            return
        }
        let count=min(500,f.count-offset)
        let chunk=Array(f[offset..<offset+count])
        let payload=LE.bytes(UInt64(offset))+LE.bytes(Wire.crc(chunk))+chunk
        let sent=client.command(channel:2,opcode:65,payload:payload,label:"曲谱块 \(offset)",target:3,
            completed:{[weak self] _ in guard let self=self, t==self.token else { return }
                self.offset+=count;self.show("已发送曲谱 \(self.offset)/\(f.count) 字节");self.next(t) },
            rejected:{[weak self] _ in guard let self=self, t==self.token else { return };self.fail("曲谱块被拒绝") })
        if sent==nil { fail("曲谱块无法排队") }
    }
    func cancel() { if active { cancelling=true;show("正在取消上传，等待当前块完成") } }
    private func sendCancel(_ t: Int) {
        let sent=client.command(channel:2,opcode:67,label:"取消上传",target:3,
            completed:{[weak self] _ in guard let self=self, t==self.token else { return };self.finish("上传已取消") },
            rejected:{[weak self] _ in guard let self=self, t==self.token else { return };self.finish("取消未确认，请重新连接后检查曲谱") })
        if sent==nil { finish("取消请求未发送；断开连接后乐器会清理临时文件") }
    }
    func disconnected() { if active { finish("连接中断，曲谱是否保存未确认；重新连接后再上传一次") } }
    private func fail(_ message: String) {
        _ = client.command(channel:2,opcode:67,label:"失败后取消暂存",target:3)
        finish(message)
    }
    private func finish(_ message: String) { token+=1;bytes=nil;cancelling=false;show(message) }
}
