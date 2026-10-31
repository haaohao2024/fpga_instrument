import Foundation
import Combine
import InstrumentCore

final class InstrumentModel: ObservableObject {
    let link=BluetoothLink()
    @Published var feedback="请先连接乐器"
    @Published var metrics: VoiceMetrics?
    @Published var loop: LoopInfo?
    @Published var ensemble: EnsembleInfo?
    @Published var record: RecordInfo?
    @Published var velocity=160.0
    @Published var octave=0
    @Published var fileStatus="文件操作需要保持App在前台"
    @Published var exportedFile: URL?
    @Published var fileBusy=false
    @Published var spectrumState: SpectrumTest.State = .idle
    /// Opt-in live measurement of the FPGA's real synthesis rate. It costs BLE
    /// bandwidth, so it stays off until the user asks for it on the test page.
    @Published var liveRateOn=false
    @Published var rateReading: SampleRateMeter.Reading?
    private var rateMeter=SampleRateMeter()
    private var ratePending=false
    private var ratePolledAt: UInt64=0
    private var nextSpectrumPoll: UInt64=0
    private var nativeTestExpires: UInt64=0
    lazy var spectrum = SpectrumTest(client:client)
    private var timer: AnyCancellable?
    private var log: [String]=[]
    private var recordID: UInt64
    private var transfer: FileTransfer?
    private(set) lazy var client=ClientSession(send:{[weak self] in self?.link.send($0) ?? false},terminate:{[weak self] in self?.link.disconnect($0)},show:{[weak self] in self?.show($0)},clock:{BluetoothLink.now})
    static let timbres=["基础正弦","FM电钢琴","风琴","拨弦","Lead","简易鼓组"]
    init() {
        recordID=UInt64(UserDefaults.standard.string(forKey:"lastRecordID") ?? "0") ?? 0
        spectrum.changed = {[weak self] state in
            self?.spectrumState=state
            self?.nativeTestExpires = (state == .submitted(48) || state == .submitted(64)) ? BluetoothLink.now+31_000 : 0
        }
        link.onReady={[weak self] sid in
            guard let self=self else{return}
            do { try self.client.ready(sid);self.command(1,"读取设备参数",target:3);self.refresh() }
            catch { self.link.disconnect(error.localizedDescription) }
        }
        link.onMessage={[weak self] m in self?.receive(m)}
        link.onDisconnected={[weak self] in
            guard let self=self else{return};self.client.disconnected();self.metrics=nil;self.loop=nil;self.ensemble=nil;self.record=nil
            self.stopLiveRate()
            self.spectrum.disconnected()
            self.transfer=nil;self.fileBusy=false;self.fileStatus="连接已断开；未完成的文件不发布"
            self.uploader.disconnected();self.noteSlots=[:];self.recording=false;self.ensembleOn=false;self.scorePlaying=false
            self.guideNote=nil;self.physicalNotes=[]
        }
        timer=Timer.publish(every:0.1,on:.main,in:.common).autoconnect().sink{[weak self] _ in self?.tick()}
    }
    private func tick() {
        client.tick()
        if nativeTestExpires != 0, BluetoothLink.now>=nativeTestExpires { spectrum.disconnected() }
        if spectrumState != .idle, link.ready, BluetoothLink.now>=nextSpectrumPoll {
            nextSpectrumPoll=BluetoothLink.now+500
            command(41,"读取测试硬件统计",target:3)
        }
        // Live rate: one request per second, and none while the previous answer is
        // still outstanding, so the poll can never pile up on the BLE link.
        if liveRateOn, link.ready { pollRate() }
        if ratePending, BluetoothLink.now &- ratePolledAt>3000 { ratePending=false }
        guard let t=transfer,t.awaitingData,!t.awaitingResult,BluetoothLink.now-t.requestedAt>=5000 else{return}
        if t.attempts>=4 { cancelFile("文件数据通知超时，未发布下载文件") }
        else { nextBlock() }
    }
    private func show(_ text: String) {
        // Keepalive must not replace the user's last operation result.
        if text.hasPrefix("会话保活") { return };feedback=text
        log.append(text);if log.count>100 { log.removeFirst() }
    }
    func diagnostics() -> String { link.diagnostics()+"\n"+log.joined(separator:"\n") }
    @discardableResult func command(_ op: Int,_ label: String,_ payload: [UInt8]=[],target: Int=4) -> Ticket? {
        client.command(opcode:op,payload:payload,label:label,target:target)
    }
    func press(_ key: Int) -> Bool { spectrumState == .idle && client.press(key:key,note:60+octave*12+key,pressure:Int(velocity)) }
    func release(_ key: Int) { client.release(key:key) }

    // MARK: Stage (main screen) state. These are the values the phone last sent,
    // not a readback of the board; the board's own knobs can change them.
    @Published var timbre=1
    @Published var releaseCode=4.0
    @Published var vibratoDepth=0.0
    @Published var synthVolume=0.7
    @Published var accompanimentVolume=0.5
    @Published var echo=false
    @Published var chorus=false
    @Published var reverb=false
    @Published var bypass=false
    @Published var stereoSpread=false
    @Published var metronomeOn=false
    @Published var tempo=100
    @Published var countIn=false
    @Published var recording=false
    @Published var ensembleOn=false
    @Published var scorePlaying=false
    @Published var teachMode=false
    /// Reserved board notices (opcodes 133..135). Empty until a firmware sends them.
    @Published var guideNote: Int?
    @Published var physicalNotes: Set<Int>=[]
    @Published var boardReportsGuide=false
    @Published var scoreStatus=""
    private var noteSlots: [Int:Int]=[:]   // note -> phone key slot 0..31
    let metronome=Metronome()
    lazy var uploader=ScoreUploader(client:client,show:{[weak self] in self?.scoreStatus=$0;self?.show($0)})

    /// Plays a note on the first free phone key slot; the protocol allows 32 held keys.
    func pressNote(_ note: Int) -> Bool {
        guard spectrumState == .idle, noteSlots[note]==nil else { return false }
        let used=Set(noteSlots.values).union(client.heldKeys)
        guard let slot=(0..<32).first(where:{ !used.contains($0) }) else { return false }
        let spread=stereoSpread
        let ok=client.press(key:slot,note:note,pressure:Int(velocity)) {[weak self] r in
            guard spread, r.instance != 0 else { return }
            self?.pan(instance:r.instance,generation:r.generation,note:note)
        }
        if ok { noteSlots[note]=slot }
        return ok
    }
    func releaseNote(_ note: Int) { if let slot=noteSlots.removeValue(forKey:note) { client.release(key:slot) } }
    func releaseStage() { noteSlots=[:];releaseAll() }
    /// Low notes left, high notes right (0..256, 128 = centre).
    private func pan(instance: UInt64,generation: UInt16,note: Int) {
        let position=UInt16(max(0,min(256,(note-KeyLayout.low)*256/(KeyLayout.high-KeyLayout.low))))
        let payload=LE.bytes(instance)+LE.bytes(generation)+LE.bytes(position)+[0,0,0,0]
        command(34,"声像",payload)
    }

    func applyTimbre(_ t: Int) { timbre=t;releaseStage();_ = client.pitchParameter(opcode:32,value:t);saveSettings() }
    func applyRelease() { _ = client.pitchParameter(opcode:33,value:Int(releaseCode));saveSettings() }
    func applyVibrato() { vibrato(Int(vibratoDepth));saveSettings() }
    func applyGain() { gain(synthVolume,accompanimentVolume,false,false);saveSettings() }
    func applyEffects() { effects(delay:echo,chorus:chorus,reverb:reverb,bypass:bypass) }
    func toggleEffect(_ name: String) {
        switch name {
        case "bypass": bypass.toggle()
        case "echo": echo.toggle();bypass=false
        case "chorus": chorus.toggle();bypass=false
        default: reverb.toggle();bypass=false
        }
        applyEffects();saveSettings()
    }
    func toggleRecording() {
        if recording { stopRecord();recording=false } else { startRecord(mask:3);recording=true }
    }
    func toggleEnsemble() {
        if ensembleOn { command(105,"停止智能合奏");ensembleOn=false }
        else { startEnsemble(level:2,root:0,minor:false,bpm:tempo,style:0);ensembleOn=true }
    }
    func toggleMetronome() { metronomeOn.toggle();if metronomeOn { metronome.start(bpm:tempo) } else { metronome.stop() } }

    // Loop: record and end each layer explicitly; the next layer waits for the player.
    var loopRecording: Bool { loop?.state==1 || loop?.state==3 }
    var loopLayers: Int { loop?.layers ?? 0 }
    func recordLoopLayer() {
        releaseStage()
        if countIn { metronome.countIn(bpm:tempo,beats:4) {[weak self] in guard let self=self else { return };self.startLoop(self.timbre) } }
        else { startLoop(timbre) }
    }
    func endLoopLayer() { command(97,"结束录制一层") }
    func undoLoopLayer() { command(98,"撤销上一层") }
    func toggleLoopPlayback() { if loop?.state==5 { command(102,"恢复循环") } else { command(99,"停止循环") } }
    func clearLoop() { command(100,"清空循环") }

    func playScore() { command(38,"播放曲谱",[1,UInt8(teachMode ? 1 : 0),0,0,0,0,0,0],target:3);scorePlaying=true }
    func stopScore() { command(38,"停止曲谱",[3,0,0,0,0,0,0,0],target:3);scorePlaying=false;guideNote=nil }

    /// Reserved notices; older firmware never sends them, so nothing changes until it does.
    /// 133 guide: [1, count, note0...]  134 physical keys: [1, 0, 16-byte note bitmap]
    /// 135 board parameters: [1, timbre, release, vibrato, effectFlags]  (docs/app_reserved_notices.md)
    func reservedNotice(_ m: Message) {
        let p=m.payload
        switch m.opcode {
        case 133:
            guard p.count>=2, p[0]==1, p.count>=2+Int(p[1]) else { return }
            boardReportsGuide=true
            guideNote=p[1]>0 ? Int(p[2]) : nil
        case 134:
            guard p.count==18, p[0]==1 else { return }
            var notes=Set<Int>()
            for i in 0..<128 where p[2+i/8] & (UInt8(1)<<UInt8(i%8)) != 0 { notes.insert(i) }
            physicalNotes=notes
        case 135:
            guard p.count>=5, p[0]==1, p[1]<=5, p[2]<=11 else { return }
            timbre=Int(p[1]);releaseCode=Double(p[2]);vibratoDepth=Double(p[3])
            echo=p[4]&1 != 0;chorus=p[4]&2 != 0;reverb=p[4]&4 != 0;bypass=p[4]&8 != 0
        default: break
        }
    }

    // MARK: Remembered settings. Saved locally; sent to the board only on request.
    private let settingsKey="stageSettings.v1"
    func saveSettings() {
        let s: [String:Any]=["timbre":timbre,"release":releaseCode,"vibrato":vibratoDepth,"velocity":velocity,
            "synth":synthVolume,"accomp":accompanimentVolume,"echo":echo,"chorus":chorus,"reverb":reverb,"bypass":bypass,
            "stereo":stereoSpread,"tempo":tempo]
        UserDefaults.standard.set(s,forKey:settingsKey)
    }
    var hasSavedSettings: Bool { UserDefaults.standard.dictionary(forKey:settingsKey) != nil }
    func restoreSettings() {
        guard let s=UserDefaults.standard.dictionary(forKey:settingsKey) else { show("还没有保存过的设置");return }
        timbre=s["timbre"] as? Int ?? timbre;releaseCode=s["release"] as? Double ?? releaseCode
        vibratoDepth=s["vibrato"] as? Double ?? vibratoDepth;velocity=s["velocity"] as? Double ?? velocity
        synthVolume=s["synth"] as? Double ?? synthVolume;accompanimentVolume=s["accomp"] as? Double ?? accompanimentVolume
        echo=s["echo"] as? Bool ?? echo;chorus=s["chorus"] as? Bool ?? chorus;reverb=s["reverb"] as? Bool ?? reverb;bypass=s["bypass"] as? Bool ?? bypass
        stereoSpread=s["stereo"] as? Bool ?? stereoSpread;tempo=s["tempo"] as? Int ?? tempo
        pushStage("恢复上次设置")
    }
    /// Preset for filming: FM piano, echo + reverb, medium vibrato.
    func demoPreset() {
        timbre=1;releaseCode=4;vibratoDepth=96;velocity=170;synthVolume=0.7;accompanimentVolume=0.5
        echo=true;chorus=false;reverb=true;bypass=false
        pushStage("演示模式");saveSettings()
    }
    private func pushStage(_ label: String) {
        guard link.ready else { show("\(label)：界面已更新，连接后再按一次发送到乐器");return }
        releaseStage()
        _ = client.pitchParameter(opcode:32,value:timbre);_ = client.pitchParameter(opcode:33,value:Int(releaseCode))
        vibrato(Int(vibratoDepth));gain(synthVolume,accompanimentVolume,false,false);applyEffects()
        show("\(label)：已发送到乐器")
    }

    #if targetEnvironment(simulator)
    func qaDemo() { guideNote=67;physicalNotes=[60,64];echo=true;reverb=true }
    #endif
    func releaseAll() { if spectrumState != .idle { spectrum.stop() } else { client.releaseAll() } }
    func startSpectrumTest(_ voices: Int) {
        if voices==64 && metrics?.capacity != 64 { show("64路测试需要64路FPGA：请先刷新硬件统计，确认容量为64");return }
        metrics=nil
        if !spectrum.start(voices) { show("测试未开始：请先停止当前测试并等待连接和声音设置完成") }
    }
    func stopSpectrumTest() { spectrum.stop();show("已请求松开测试音符；请按硬件统计确认尾音结束") }
    func nativeFieldTest(_ voices: Int) {
        if voices==0, spectrumState != .idle { stopSpectrumTest();return }
        if voices==64 && metrics?.capacity != 64 { show("64路测试需要64路FPGA：请先刷新硬件统计，确认容量为64");return }
        releaseAll()
        if let payload=try? SpectrumTest.nativeCommand(voices) {
            command(86,voices==0 ? "停止固件短测试" : "固件短测试\(voices)路",payload,target:4)
        }
    }
    func background() { stopLiveRate();releaseAll();link.stopScan();link.disconnect("App已进入后台，连接与手机持音已清理；回到前台后重新连接") }
    func sound(_ timbre: Int,tail: Int) {
        releaseAll();_ = client.pitchParameter(opcode:32,value:timbre);_ = client.pitchParameter(opcode:33,value:tail)
    }
    func startLoop(_ timbre: Int) {
        if !client.beginLoop(timbre:timbre) { show("录制未开始：请等待声音设置完成并确认连接") }
    }
    func vibrato(_ v: Int) { _ = client.vibrato(v) }
    func gain(_ local: Double,_ external: Double,_ ml: Bool,_ me: Bool) {
        if let p=try? Commands.gain(local:Int(local*32768),external:Int(external*32768),muteLocal:ml,muteExternal:me) { command(36,"应用音量",p,target:5) }
    }
    func effects(delay: Bool,chorus: Bool,reverb: Bool,bypass: Bool) {
        let flags: UInt32=(delay ? 1 : 0)|(chorus ? 2 : 0)|(reverb ? 4 : 0)|(bypass ? 8 : 0)
        if let p=try? Commands.effects([flags,11520,12288,576,192,71583,24576,16384,6144,4096,4096]) { command(35,"应用效果器",p) }
    }
    func keymap(_ notes: [Int]) { if let p=try? Commands.keymap(notes) { command(37,"应用实体键音高",p,target:3) } }
    func refresh() {
        command(41,"读取硬件统计",target:3);command(101,"读取循环状态",target:3);command(106,"读取合奏状态",target:3)
        if recordID != 0 { queryRecord() }
    }

    // MARK: Measured synthesis rate
    /// Starts or stops the live measurement; the test page's switch is the only
    /// entry point. Turning it on drops stale samples and asks for the first count.
    func setLiveRate(_ on: Bool) {
        liveRateOn=on
        rateMeter.reset();rateReading=nil;ratePending=false;ratePolledAt=0
        if on { pollRate() }
    }
    func stopLiveRate() {
        liveRateOn=false;rateMeter.reset();rateReading=nil;ratePending=false
    }
    private func pollRate() {
        guard liveRateOn, link.ready, !ratePending, client.pendingCount<3,
              BluetoothLink.now &- ratePolledAt>=1000 else { return }
        ratePolledAt=BluetoothLink.now;ratePending=true
        let sent=client.command(opcode:41,payload:[],label:"读取实测采样率",target:3,
            completed:{[weak self] _ in self?.ratePending=false},
            rejected:{[weak self] _ in self?.ratePending=false})
        if sent==nil { ratePending=false }
    }
    /// Pairs the counter with a monotonic timestamp; the wall clock can be stepped.
    private func recordRate(_ frame: UInt32) {
        guard liveRateOn else { return }
        ratePending=false
        rateReading=rateMeter.add(frame:frame,timeNanos:DispatchTime.now().uptimeNanoseconds)
    }
    func startEnsemble(level: Int,root: Int,minor: Bool,bpm: Int,style: Int) {
        if let p=try? Commands.ensemble(level:level,root:root,minor:minor,bpm:bpm,style:style) { command(104,"启动智能合奏",p) }
    }
    func startRecord(mask: UInt8) {
        guard !fileBusy else{return}
        recordID=max(UInt64(Date().timeIntervalSince1970*1000),recordID+1)
        UserDefaults.standard.set(String(recordID),forKey:"lastRecordID")
        guard let p=try? Commands.recordingStart(id:recordID,mask:mask) else{return}
        _ = client.command(channel:2,opcode:80,payload:p,label:"开始SD录音",target:3)
    }
    func stopRecord() { guard recordID != 0 else{return};_ = client.command(channel:2,opcode:81,payload:LE.bytes(recordID),label:"停止SD录音",target:3) }
    func queryRecord() { guard recordID != 0 else{return};_ = client.command(channel:2,opcode:82,payload:LE.bytes(recordID),label:"读取录音状态",target:3) }
    func exportEvents() { guard let r=record,r.downloadable(2),!fileBusy else{return};_ = client.command(channel:2,opcode:85,payload:LE.bytes(r.id),label:"将事件录音转成曲谱",target:3) }
    func download(_ kind: UInt8) {
        guard let r=record,r.downloadable(kind),!fileBusy else{return}
        do {
            let t=try FileTransfer(record:r,kind:kind);transfer=t;fileBusy=true;exportedFile=nil;nextBlock()
        } catch { fileStatus=error.localizedDescription }
    }
    private func nextBlock() {
        guard let t=transfer else{return}
        if t.finished {
            do { exportedFile=try t.publish();fileStatus="下载完成，整文件CRC校验通过" }
            catch { fileStatus=error.localizedDescription }
            transfer=nil;fileBusy=false;return
        }
        guard let payload=try? Commands.fileBlock(id:t.id,offset:t.offset,length:t.nextLength,kind:t.kind) else{return}
        t.awaitingResult=true;t.awaitingData=true;t.requestedAt=BluetoothLink.now;t.attempts+=1
        let ticket=client.command(channel:2,opcode:83,payload:payload,label:"读取文件分块",target:3,completed:{[weak self,weak t] _ in
            guard let self=self,let t=t,self.transfer === t else{return};t.awaitingResult=false;self.advanceDownload()
        },rejected:{[weak self] _ in self?.cancelFile("设备拒绝文件读取")})
        if ticket==nil { cancelFile("文件通道忙，请稍后重试") }
    }
    private func advanceDownload() { if let t=transfer,!t.awaitingResult,!t.awaitingData { nextBlock() } }
    func cancelFile(_ reason: String="已取消文件操作") {
        if let t=transfer { _ = client.command(channel:2,opcode:84,payload:LE.bytes(t.id),label:"取消文件读取",target:3) }
        transfer=nil;fileBusy=false;fileStatus=reason
    }
    private func receive(_ m: Message) {
        guard client.owns(m) else{return}
        do {
            switch m.opcode {
            case 128:
                let r=try ExecutionResult(m);if let v=r.metrics { metrics=v;recordRate(v.frame) };client.result(m)
            case 130:
                let r: RecordInfo
                do { r=try RecordInfo(m.payload) }
                catch { record=nil;fileStatus="录音状态未能解析，请刷新状态";throw error }
                record=r;recordID=max(recordID,r.id)
                UserDefaults.standard.set(String(recordID),forKey:"lastRecordID")
                if !fileBusy {
                    fileStatus=r.phase>=6 ? "录音未成功保存，错误码 \(r.error)；当前没有可下载的完整文件" : "设备实际状态：\(r.description)"
                    if r.phase>=6 { show("录音未保存：\(r.description)，错误码 \(r.error)") }
                }
            case 131: loop=try LoopInfo(m.payload)
            case 132: ensemble=try EnsembleInfo(m.payload)
            case 129:
                if let t=transfer { try t.accept(m.payload);fileStatus="已读取 \(t.offset) / \(t.total) 字节";advanceDownload() }
            case 133,134,135: reservedNotice(m)
            default: break
            }
        } catch { show(error.localizedDescription);if m.opcode==129 { cancelFile(error.localizedDescription) } }
    }
}

private typealias FileTransfer = RecordingDownload
