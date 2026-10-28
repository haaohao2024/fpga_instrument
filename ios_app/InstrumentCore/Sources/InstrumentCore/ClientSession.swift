import Foundation

public struct Ticket: Hashable { public let channel: Int; public let sequence: UInt32 }
public final class ClientSession {
    private final class Pending {
        let message: Message, label: String, target: Int, created: UInt64
        var phase=0, attempts=0
        var lastSent: UInt64=0, progress: UInt32=0
        let completed: ((ExecutionResult)->Void)?, rejected: ((ExecutionResult)->Void)?
        init(_ message: Message, _ label: String, _ target: Int, _ created: UInt64, _ completed: ((ExecutionResult)->Void)?, _ rejected: ((ExecutionResult)->Void)?) {
            self.message=message;self.label=label;self.target=target;self.created=created;self.completed=completed;self.rejected=rejected
        }
    }
    private struct Gesture { let id: UInt64; var note: Int, pressure: Int }
    private let send: (Message)->Bool, terminate: (String)->Void, show: (String)->Void, clock: ()->UInt64
    private var identity: [UInt8]?
    private var sequence: [UInt64]=[1,1,1], nextPress: UInt64=1
    private var queues: [[Pending]]=[[],[],[]], inflight: [Ticket:Pending]=[:], hands: [Int:Gesture]=[:], barriers=Set<Ticket>()
    private var cursor=0, pumping=false
    public private(set) var loopPreparing=false
    private var lastApplicationSend: UInt64=0
    public var connected: Bool { identity != nil }
    public var pendingCount: Int { inflight.count+queues.reduce(0){$0+$1.count} }
    public var heldKeys: Set<Int> { Set(hands.keys) }
    public var pitchReady: Bool { barriers.isEmpty }
    public init(send: @escaping (Message)->Bool, terminate: @escaping (String)->Void, show: @escaping (String)->Void, clock: @escaping ()->UInt64) {
        self.send=send;self.terminate=terminate;self.show=show;self.clock=clock
    }
    public func ready(_ sid: [UInt8]) throws {
        try require(sid.count==16,"会话长度无效");disconnected();identity=sid;lastApplicationSend=clock()
        show("会话已就绪")
    }
    public func owns(_ m: Message) -> Bool { identity==m.session }
    public func disconnected() { loopPreparing=false;identity=nil;hands=[:];queues=[[],[],[]];inflight=[:];barriers=[];sequence=[1,1,1];nextPress=1;cursor=0 }
    private func fail(_ s: String) { disconnected();terminate(s) }
    private func canReserve(_ n: Int, hands new: Int=0) -> Bool { connected && pendingCount+n+hands.count+new<=96 }
    private func enqueue(channel: Int, opcode: Int, payload: [UInt8], label: String, target: Int, completed: ((ExecutionResult)->Void)?=nil, rejected: ((ExecutionResult)->Void)?=nil) -> Ticket? {
        guard let sid=identity, (0...2).contains(channel), canReserve(1) else { show("未提交：\(label)，连接或队列未就绪");return nil }
        guard sequence[channel]<=UInt64(UInt32.max) else { fail("命令编号耗尽，请重新连接");return nil }
        let seq=UInt32(sequence[channel]), m=Message(channel:channel,opcode:opcode,session:sid,sequence:seq,payload:payload)
        guard RequestRules.error(m)==0 else { show("未提交：\(label)，参数无效");return nil }
        sequence[channel]+=1
        queues[channel].append(Pending(m,label,target,clock(),completed,rejected))
        return Ticket(channel:channel,sequence:seq)
    }
    @discardableResult public func command(channel: Int=1, opcode: Int, payload: [UInt8]=[], label: String, target: Int=4, completed: ((ExecutionResult)->Void)?=nil, rejected: ((ExecutionResult)->Void)?=nil) -> Ticket? {
        if channel==2 && (!queues[2].isEmpty || inflight.keys.contains{$0.channel==2}) { return nil }
        let t=enqueue(channel:channel,opcode:opcode,payload:payload,label:label,target:target,completed:completed,rejected:rejected);pump();return t
    }
    @discardableResult public func press(key: Int, note: Int, pressure: Int, completed: ((ExecutionResult)->Void)?=nil) -> Bool {
        guard (0..<32).contains(key), (0...127).contains(note), (1...255).contains(pressure), hands[key]==nil, pitchReady, canReserve(1,hands:1), nextPress<UInt64.max else { return false }
        let id=nextPress;nextPress+=1
        guard let p=try? Commands.event(id:id,kind:1,key:key,note:note,value:pressure), enqueue(channel:0,opcode:16,payload:p,label:"按下琴键",target:3,completed:completed) != nil else { return false }
        hands[key]=Gesture(id:id,note:note,pressure:pressure);pump();return true
    }
    public func release(key: Int) {
        guard let h=hands.removeValue(forKey:key), connected else { return }
        guard let p=try? Commands.event(id:h.id,kind:2,key:key,note:0,value:0), enqueue(channel:0,opcode:16,payload:p,label:"松开琴键",target:3) != nil else { fail("松键发送失败，断开连接清理手机持音");return }
        pump()
    }
    public func releaseAll() { for key in Array(hands.keys) { release(key:key) } }
    @discardableResult public func vibrato(_ depth: Int) -> Bool {
        guard let p=try? Commands.event(id:0,kind:4,key:255,note:0,value:depth) else { return false }
        let t=enqueue(channel:0,opcode:16,payload:p,label:"颤音",target:3);pump();return t != nil
    }
    @discardableResult public func pitchParameter(opcode: Int, value: Int, completed: ((ExecutionResult)->Void)?=nil) -> Bool {
        guard [32,33].contains(opcode), (0...(opcode==32 ? 5 : 11)).contains(value), canReserve(2) else { return false }
        let phase=opcode==32 ? 3 : 4
        guard let config=enqueue(channel:1,opcode:opcode,payload:[UInt8(value)],label:opcode==32 ? "音色" : "松手衰减",target:phase) else { return false }
        let payload: [UInt8]=[1,UInt8(phase),0,0]+LE.bytes(config.sequence)
        guard let t=enqueue(channel:1,opcode:40,payload:payload,label:"声音设置屏障",target:3,completed:completed) else { fail("设置未完整提交，请重新连接");return false }
        barriers.insert(t);pump();return true
    }
    // A layer must capture the timbre actually applied by the FPGA. Wait
    // for its existing configuration barrier before submitting LOOP_BEGIN.
    @discardableResult public func beginLoop(timbre: Int) -> Bool {
        guard !loopPreparing, (0...5).contains(timbre), connected else { return false }
        releaseAll();loopPreparing=true
        let accepted=pitchParameter(opcode:32,value:timbre,completed:{[weak self] _ in
            guard let self=self, self.loopPreparing else { return }
            self.loopPreparing=false
            _=self.command(opcode:96,payload:[UInt8(timbre)],label:"开始录制一层")
        })
        if !accepted { loopPreparing=false }
        return accepted
    }
    public func result(_ m: Message) {
        guard owns(m), let r=try? ExecutionResult(m) else { return }
        let ticket=Ticket(channel:r.channel,sequence:r.sequence)
        guard let p=inflight[ticket], r.phase>=p.phase else { return }
        if r.phase>p.phase { p.lastSent=clock() }
        if p.message.opcode==66 && r.phase==2 && r.diagnostic>p.progress { p.progress=r.diagnostic;p.lastSent=clock();p.attempts=1 }
        p.phase=r.phase;show("\(p.label)：\(r.description)")
        if r.phase==6 || r.phase==7 {
            inflight.removeValue(forKey:ticket);p.rejected?(r)
            if p.message.channel==0 || barriers.contains(ticket) || [32,33].contains(p.message.opcode) { fail("演奏或声音设置未确认，已清理手机连接");return }
        } else if r.phase>=p.target { inflight.removeValue(forKey:ticket);barriers.remove(ticket);p.completed?(r) }
        pump()
    }
    public func tick() {
        guard connected else { return };let now=clock()
        let all=Array(inflight.values)+queues.flatMap{$0}
        for p in all {
            let limit: UInt64=p.message.opcode==66 ? 2_400_000 : p.message.channel==2 ? 60_000 : 12_000
            if now-p.created>=limit { fail("\(p.label)等待超时，已断开清理手机持音");return }
        }
        for p in Array(inflight.values) {
            let timeout: UInt64=p.message.channel==2 ? 10_000 : 2_000
            if now-p.lastSent>=timeout {
                if p.attempts>=4 { fail("设备执行反馈超时，已断开连接");return }
                if send(p.message) { p.attempts+=1;p.lastSent=now }
                else if now-p.lastSent>=timeout*2 { fail("发送持续阻塞，已断开连接");return }
            }
        }
        if now-lastApplicationSend>=100 && !all.contains(where:{$0.message.opcode==2}) { _=enqueue(channel:1,opcode:2,payload:[],label:"会话保活",target:3) }
        pump()
    }
    private func pump() {
        guard connected && !pumping else { return };pumping=true;defer{pumping=false}
        while inflight.count<4 {
            var selected: Int?
            for offset in 0..<3 { let c=(cursor+offset)%3;if !queues[c].isEmpty { selected=c;break } }
            guard let c=selected, let p=queues[c].first, send(p.message) else { return }
            queues[c].removeFirst();cursor=(c+1)%3;lastApplicationSend=clock();p.lastSent=clock();p.attempts=1
            inflight[Ticket(channel:c,sequence:p.message.sequence)]=p
        }
    }
}

public final class WriteScheduler {
    public struct Fragment { public let channel: Int;public let bytes: [UInt8] }
    private var queues: [[Fragment]]=[[],[],[]], cursor=0
    private var active: Fragment?
    private var since: UInt64=0
    public var count: Int { queues.reduce(0){$0+$1.count}+(active==nil ? 0 : 1) }
    public init() {}
    public func enqueue(_ m: Message, maxWrite: Int) throws -> Bool {
        try require((0...2).contains(m.channel),"写入通道无效")
        let frames=try Wire.fragments(m,maxWrite:maxWrite)
        let own=queues[m.channel].count+(active?.channel==m.channel ? 1 : 0)
        guard count+frames.count<=96 && (m.channel != 2 || own+frames.count<=64) else { return false }
        queues[m.channel] += frames.map{Fragment(channel:m.channel,bytes:$0)};return true
    }
    public func next(now: UInt64) throws -> Fragment? {
        if let a=active { try require(now-since<3000,"GATT写入超时");return a }
        let rotation=[0,0,1,2]
        for _ in rotation {
            let c=rotation[cursor];cursor=(cursor+1)%rotation.count
            if !queues[c].isEmpty { let f=queues[c].removeFirst();active=f;since=now;return f }
        }
        return nil
    }
    public func acknowledged() throws { try require(active != nil,"收到无对应写入的确认");active=nil }
    public func clear() { queues=[[],[],[]];active=nil;cursor=0;since=0 }
}
