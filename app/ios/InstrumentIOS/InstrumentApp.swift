import SwiftUI
import UIKit
import InstrumentCore

/// The native share sheet works on iOS 15 for both diagnostic text and files.
struct CompatibleShareButton: View {
    let title: String
    let items: ()->[Any]
    @State private var presenting=false
    var body: some View {
        Button { presenting=true } label: { Label(title,systemImage:"square.and.arrow.up") }
            .sheet(isPresented:$presenting) {
                ActivityShareSheet(items:items(),finished:{presenting=false})
            }
    }
}
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let finished: ()->Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller=UIActivityViewController(activityItems:items,applicationActivities:nil)
        controller.completionWithItemsHandler={_,_,_,_ in finished()}
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) {}
}

@main struct InstrumentApp: App {
    @StateObject private var model=InstrumentModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            // The stage is the home screen; the former tab pages open from its "更多" menu.
            StageView(model:model,link:model.link)
                .onChange(of:phase){ if $0 == .background { model.background() } }
        }
    }
}

struct InstrumentHome: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State private var page=0
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Circle().fill(link.ready ? Color.green : Color.orange).frame(width:9,height:9)
                Text(link.status).font(.footnote).lineLimit(2)
                Spacer()
            }.padding(.horizontal).padding(.vertical,8).background(Color(uiColor:.secondarySystemBackground))
            TabView(selection:$page) {
                NavigationView { ConnectionView(model:model,link:link) }.navigationViewStyle(.stack).tabItem{Label("连接",systemImage:"antenna.radiowaves.left.and.right")}.tag(0)
                NavigationView { PlayView(model:model,link:link) }.navigationViewStyle(.stack).tabItem{Label("演奏",systemImage:"pianokeys")}.tag(1)
                NavigationView { SoundView(model:model,link:link) }.navigationViewStyle(.stack).tabItem{Label("声音",systemImage:"slider.horizontal.3")}.tag(2)
                NavigationView { LoopView(model:model,link:link) }.navigationViewStyle(.stack).tabItem{Label("循环",systemImage:"repeat")}.tag(3)
                NavigationView { MoreView(model:model,link:link) }.navigationViewStyle(.stack).tabItem{Label("更多",systemImage:"ellipsis.circle")}.tag(4)
            }.onChange(of:page){_ in model.releaseAll()}
            Text(model.feedback).font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(8).background(Color(uiColor:.secondarySystemBackground))
        }.tint(.indigo).onAppear {
            #if targetEnvironment(simulator)
            let args=ProcessInfo.processInfo.arguments
            if let i=args.firstIndex(of:"--qa-page"),i+1<args.count,let n=Int(args[i+1]),(0...4).contains(n) { page=n }
            if args.contains("--qa-spectrum") { page=4 }
            #endif
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    var body: some View {
        List {
            Section("连接乐器") {
                Button(link.scanning ? "停止扫描" : "扫描附近乐器") { if link.scanning { link.stopScan() } else { link.scan() } }
                ForEach(link.devices) { d in Button { link.connect(d) } label: {
                    HStack { VStack(alignment:.leading){Text(d.name);Text("信号 \(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right") }
                } }
                if link.devices.isEmpty { Text("扫描到设备后，会在这里出现可点击的设备名称。").foregroundStyle(.secondary) }
                Button("断开并清理手机持音",role:.destructive){model.releaseAll();link.disconnect()}
            }
            Section("首次使用") {
                Text("在本App内扫描并点击设备；如出现系统配对提示，请确认。无需先去系统蓝牙页面搜索设备。")
                Text("本版需保持App在前台。进入后台会断开连接并清理手机持音；实体琴键仍可独立演奏。")
                Text("本版兼容配套的48kHz、96kHz及128kHz固件。实际振荡器数量由设备报告；板上功能验收以对应固件的实测结果为准。")
            }.font(.footnote)
            Section("排查") {
                Button("刷新设备状态"){model.refresh()}.disabled(!link.ready)
                CompatibleShareButton(title:"分享连接诊断",items:{[model.diagnostics()]})
                Button("复制连接诊断"){UIPasteboard.general.string=model.diagnostics()}
            }
        }.navigationTitle("FPGA 乐器")
    }
}

struct PlayView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("多指按住可演奏和弦；松开或移出原琴键即停止该音符。").font(.footnote).foregroundStyle(.secondary)
            Stepper("八度：\(model.octave >= 0 ? "+" : "")\(model.octave)",value:$model.octave,in:-2...2)
                .onChange(of:model.octave){_ in model.releaseAll()}
            HStack { Text("力度 \(Int(model.velocity))");Slider(value:$model.velocity,in:1...255,step:1) }
            TouchKeyboard(enabled:link.ready,down:{model.press($0)},up:{model.release($0)})
                .frame(height:240).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityLabel("16键多指演奏键盘")
            Button("松开所有手机琴键",role:.destructive){model.releaseAll()}.buttonStyle(.bordered)
            if let m=model.metrics {
                Text("FPGA实测：占槽 \(m.allocated)/\(m.capacity) · 按住 \(m.gated) · 有贡献 \(m.nonzero)\n每帧完成 \(m.completed)，计算 \(m.cycles) 拍，帧号 \(m.frame)").font(.footnote).monospacedDigit()
            }
            Button("刷新硬件统计"){model.command(41,"读取硬件统计",target:3)}.disabled(!link.ready)
            Spacer()
        }.padding().navigationTitle("演奏").onDisappear{model.releaseAll()}
    }
}

struct TouchKeyboard: UIViewRepresentable {
    var enabled: Bool
    var down: (Int)->Bool,up: (Int)->Void
    func makeUIView(context: Context) -> KeySurface { let v=KeySurface();v.isMultipleTouchEnabled=true;return v }
    func updateUIView(_ v: KeySurface,context: Context) { v.down=down;v.up=up;v.enabled=enabled;v.setNeedsDisplay() }
    static func dismantleUIView(_ v: KeySurface,coordinator: Void) { v.clear() }
}
final class KeySurface: UIView {
    var down: ((Int)->Bool)?,up: ((Int)->Void)?
    var enabled=false { didSet { if !enabled { clear() } } }
    private var held: [ObjectIdentifier:Int]=[:]
    func clear() { let keys=Array(held.values);held=[:];keys.forEach{up?($0)};setNeedsDisplay() }
    private func key(_ p: CGPoint) -> Int? {
        guard bounds.contains(p),bounds.width>0,bounds.height>0 else{return nil}
        return min(7,Int(p.x/bounds.width*8))+(p.y>=bounds.height/2 ? 8 : 0)
    }
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard enabled else{return}
        for t in touches { if let k=key(t.location(in:self)),!held.values.contains(k),down?(k)==true { held[ObjectIdentifier(t)]=k } };setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>,with event: UIEvent?) {
        for t in touches { let id=ObjectIdentifier(t);if let k=held[id],key(t.location(in:self)) != k { held.removeValue(forKey:id);up?(k) } };setNeedsDisplay()
    }
    private func ended(_ touches: Set<UITouch>) { for t in touches { if let k=held.removeValue(forKey:ObjectIdentifier(t)){up?(k)} };setNeedsDisplay() }
    override func touchesEnded(_ touches: Set<UITouch>,with event: UIEvent?) { ended(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>,with event: UIEvent?) { ended(touches) }
    override func draw(_ rect: CGRect) {
        guard let c=UIGraphicsGetCurrentContext() else{return}
        let names=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B","C","C♯","D","D♯"]
        for i in 0..<16 {
            let r=CGRect(x:CGFloat(i%8)*bounds.width/8,y:CGFloat(i/8)*bounds.height/2,width:bounds.width/8,height:bounds.height/2).insetBy(dx:1,dy:1)
            let black=[1,3,6,8,10,13,15].contains(i)
            c.setFillColor((held.values.contains(i) ? UIColor.systemIndigo : black ? UIColor.darkGray : UIColor.systemGray6).withAlphaComponent(enabled ? 1 : 0.45).cgColor);c.fill(r)
            (names[i] as NSString).draw(at:CGPoint(x:r.minX+5,y:r.maxY-28),withAttributes:[.font:UIFont.systemFont(ofSize:13),.foregroundColor:black ? UIColor.white : UIColor.black])
        }
    }
}

struct SoundView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State var timbre=0
    @State var tail=4
    @State var vibrato=0.0
    @State var local=0.5
    @State var external=0.5
    @State var muteLocal=false
    @State var muteExternal=false
    @State var delay=false
    @State var chorus=false
    @State var reverb=false
    @State var bypass=false
    var body: some View {
        Form {
            Section("新按下音符的声音") {
                Picker("音色",selection:$timbre){ForEach(0..<6){Text(InstrumentModel.timbres[$0]).tag($0)}}
                Picker("松手衰减",selection:$tail){ForEach(0..<8){Text("\($0) · 约 \(Int(Double($0)*21.333)) ms").tag($0)}}
                Button("应用音色与衰减"){model.sound(timbre,tail:tail)}
                Text("已响起或已录入循环的音符保持原音色。鼓组8键依次是底鼓、军鼓、闭镲、开镲、低嗵鼓、高嗵鼓、拍手、镲。").font(.caption)
            }
            Section("颤音") { Slider(value:$vibrato,in:0...255,step:1);Text("深度 \(Int(vibrato))");Button("应用颤音"){model.vibrato(Int(vibrato))} }
            Section("输出音量") {
                Text("合成音量 \(Int(local*100))%");Slider(value:$local,in:0...1)
                Text("外部伴奏 \(Int(external*100))%");Slider(value:$external,in:0...1)
                Toggle("静音合成",isOn:$muteLocal);Toggle("静音外部伴奏",isOn:$muteExternal)
                Button("应用音量"){model.gain(local,external,muteLocal,muteExternal)}
            }
            Section("效果器") {
                Toggle("回声",isOn:$delay);Toggle("合唱",isOn:$chorus);Toggle("混响",isOn:$reverb);Toggle("旁路效果器",isOn:$bypass)
                Button("应用效果器预设"){model.effects(delay:delay,chorus:chorus,reverb:reverb,bypass:bypass)}
            }
            Section { Text("这些是待提交的设置，不代表设备当前值。以底部实际执行反馈为准。").font(.caption) }
        }.disabled(!link.ready).navigationTitle("声音")
    }
}

struct LoopView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State var timbre=5
    var body: some View {
        Form {
            Section("Live Looping") {
                Text(model.loop?.description ?? "尚未取得循环状态")
                if let s=model.loop {
                    Text("\(s.layers)/4 层 · \(s.events) 个事件 · \(String(format:"%.2f",Double(s.length)/s.sampleRate)) 秒")
                    if s.error != 0 { Text("上一操作错误 \(s.error)，录制原因 \(s.reason)。请保留这两个编号；结束按钮不能恢复已经失败的录制。").foregroundStyle(.red) }
                }
                Picker("本层音色",selection:$timbre){ForEach(0..<6){Text(InstrumentModel.timbres[$0]).tag($0)}}
                Button("开始录制一层"){model.startLoop(timbre)}
                Button("结束录制，加入循环"){model.command(97,"结束录制一层")}.disabled(model.loop?.state != 1 && model.loop?.state != 3)
                Button("撤销上一层"){model.command(98,"撤销上一层")}
                Button("停止循环"){model.command(99,"停止循环")}
                Button("恢复循环"){model.command(102,"恢复循环")}
                Button("清空循环",role:.destructive){model.command(100,"清空循环")}
                Button("刷新循环状态"){model.command(101,"读取循环状态",target:3)}
            }
            Section { Text("第一层的开始和结束确定循环长度，后续层沿用该长度。最多4层、4096个事件、16秒；运行数据断电不保存。\n请先停止智能合奏、曲谱与SD录音，再操作循环。开始时自动应用本层音色；等“开始录制一层：已生效”后再演奏。录制期间不要切换音色；录制后仍可现场演奏。").font(.footnote) }
        }.disabled(!link.ready).navigationTitle("循环叠录")
    }
}

struct MoreView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State private var showSpectrum=false
    var body: some View {
        List {
            NavigationLink("赛题测试模式",isActive:$showSpectrum){ SpectrumTestView(model:model,link:link) }
            NavigationLink("智能合奏"){ EnsembleView(model:model,link:link) }
            NavigationLink("SD录音与下载"){ RecordingView(model:model,link:link) }
            NavigationLink("实体键与曲谱"){ KeymapView(model:model,link:link) }
            Section("本版说明") {
                Text("所有演奏音频均由FPGA合成。iPhone仅发送音符、参数与文件控制，不计算或传送合成采样。")
                NavigationLink("手机音乐伴奏怎么连接") {
                    Form {
                        Section("首次连接") {
                            Text("App内连接负责控制乐器，不会自动把手机音乐送到乐器。请先停止循环和智能合奏，再打开iPhone的设置→蓝牙，连接BTBLE-DEV。")
                            Text("播放一首手机音乐，再从控制中心的音频输出列表选择BTBLE-DEV。回到本App的声音页面，关闭“静音外部伴奏”，提高“外部伴奏”音量并点击应用。实体琴键可与音乐一起发声。")
                        }
                        Section("没有声音时") {
                            Text("如果系统蓝牙或音频输出列表里没有设备，说明音频连接还没建立；App显示已就绪只表示控制连接成功。请记录是无法发现、无法配对，还是已选输出但静音，用于进一步排查。")
                            Text("音频由手机的系统蓝牙音频连接传输；App不读取其他应用的音频。此连接链路仍需本板实测确认。")
                        }
                    }.navigationTitle("手机音乐伴奏")
                }
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("更多功能").onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-spectrum") { showSpectrum=true }
            #endif
        }
    }
}
struct SpectrumTestView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State private var voices=48
    private var status: String {
        switch model.spectrumState {
        case .idle: return "持续测试未启动"
        case .preparing(let n): return "正在设置并提交\(n)路音符"
        case .submitted(let n): return "\(n)路音符已提交\(n==48 ? "（最多30秒）" : "")；实际发声数请看下方硬件统计"
        }
    }
    var body: some View {
        Form {
            Section("多频率持续测试") {
                Picker("目标路数",selection:$voices){ForEach(SpectrumTest.sizes,id:\.self){Text("\($0)路").tag($0)}}
                    .disabled(model.spectrumState != .idle)
                Text(status).accessibilityIdentifier("spectrum-status")
                Button("启动持续测试"){model.startSpectrumTest(voices)}.disabled(!link.ready || model.spectrumState != .idle)
                Button("停止持续测试",role:.destructive){model.stopSpectrumTest()}.disabled(!link.ready)
                Text("先停止合奏、循环、曲谱和录音，松开实体琴键，调低功放音量。测试使用基础正弦、关闭颤音并旁路效果器；测试后这些声音设置会保留，可在“声音”页重新设置。48路使用FPGA原生测试源，30秒自动结束；需要本次配套固件。离页会请求停止；断链时原生测试最迟30秒结束。").font(.footnote)
            }
            Section("FPGA真实计数") {
                if let m=model.metrics {
                    Text("硬件容量 \(m.capacity) · 占槽 \(m.allocated)\n按住 \(m.gated) · 有贡献 \(m.nonzero) · 窗口峰值 \(m.peak)\n每帧完成 \(m.completed) · 计算 \(m.cycles) 拍\n故障标志 \(m.faults) · 帧号 \(m.frame)").monospacedDigit()
                } else { Text("尚无本次硬件统计") }
                // The frame counter above is the source: pairing it with the phone's
                // monotonic clock turns it into the board's real synthesis rate.
                Toggle("实时测量采样率",isOn:Binding(get:{model.liveRateOn},set:{model.setLiveRate($0)}))
                    .disabled(!link.ready).accessibilityIdentifier("live-rate-toggle")
                Text("测量会占用蓝牙带宽，播放蓝牙伴奏时请关闭。").font(.footnote)
                if model.liveRateOn {
                    Text(model.rateReading?.summary ?? "测量中…（至少 5 秒后出结果）")
                        .monospacedDigit().accessibilityIdentifier("live-rate-reading")
                    Text(SampleRateMeter.Reading.provenance).font(.footnote)
                }
                Button("刷新硬件统计"){model.command(41,"读取测试硬件统计",target:3)}.disabled(!link.ready)
                Text("容量、占槽和每帧完成数不等于活跃可闻振荡器数。有贡献计数是硬件快照，谱峰仍须由实际音频频谱验证。本页不把请求路数当作评分结果，也不把48kHz录音采样率当作128kHz音频输出采样率。").font(.footnote)
            }
            Section("预期基频（不是实测频谱）") {
                ForEach(SpectrumTest.notes(voices),id:\.self){ note in
                    Text("MIDI \(note)   \(String(format:"%.2f",SpectrumTest.frequency(note))) Hz").monospacedDigit()
                }
                Text("使用音频采集或频谱仪观察对应数量的独立谱峰。建议稳定发声后读取长窗FFT；相邻低音谱峰约间隔8Hz。不要把噪声或谐波算作额外振荡器。").font(.footnote)
            }
            Section("固件原生短测试") {
                Button("触发\(voices)路短测试"){model.nativeFieldTest(voices)}.disabled(!link.ready || model.spectrumState != .idle)
                Button("停止固件短测试"){model.nativeFieldTest(0)}.disabled(!link.ready)
                Text("1／8／16／32路原生测试约10.7ms自动结束，48路为30秒测试。要使用正弦预设和实时统计，请使用上方入口。48路由配套FPGA逐音实时合成，手机不传音频采样。").font(.footnote)
            }
        }.navigationTitle("赛题测试模式").onDisappear { model.stopLiveRate();model.releaseAll() }
    }
}
struct EnsembleView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State var level=2
    @State var root=0
    @State var minor=false
    @State var bpm=120
    @State var style=0
    let roots=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
    var body: some View {
        Form {
            Section("伴奏设置") {
                Picker("丰富度",selection:$level){Text("基础").tag(0);Text("标准").tag(1);Text("丰富").tag(2)}
                Picker("主音",selection:$root){ForEach(0..<12){Text(roots[$0]).tag($0)}}
                Toggle("小调",isOn:$minor);Stepper("速度 \(bpm) BPM",value:$bpm,in:50...180)
                Picker("风格",selection:$style){Text("常规").tag(0);Text("舒缓").tag(1);Text("律动").tag(2)}
                Button("启动智能合奏"){model.startEnsemble(level:level,root:root,minor:minor,bpm:bpm,style:style)}
                Button("停止伴奏",role:.destructive){model.command(105,"停止智能合奏")}
                Button("刷新状态"){model.command(106,"读取合奏状态",target:3)}
            }
            Section("设备实际状态") {
                Text(model.ensemble?.description ?? "尚未取得状态")
                if let e=model.ensemble { Text("已观察 \(e.observed) · 已生成 \(e.generated) · 跳过 \(e.skipped)\n现场按住 \(e.human) · 伴奏占槽 \(e.slots) · 原因 \(e.reason)") }
            }
            Section { Text("先停止循环、曲谱、录音及外部伴奏。伴奏按设定BPM运行，根据最近音符调整和声，停顿时加入回应。它不是自动精准跟拍。现场琴键可同时演奏。").font(.footnote) }
        }.disabled(!link.ready).navigationTitle("智能合奏")
    }
}
struct RecordingView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State var mask=3
    var body: some View {
        Form {
            Section("录入SD卡") {
                Picker("内容",selection:$mask){Text("声音与事件").tag(3);Text("声音WAV").tag(1);Text("演奏事件").tag(2)}
                Button("开始录音"){model.startRecord(mask:UInt8(mask))}
                Button("停止并保存"){model.stopRecord()}
                Button("刷新录音状态"){model.queryRecord()}
                if let r=model.record { Text(verbatim:r.summary).font(.footnote).foregroundStyle(r.phase>=6 ? .red : .primary) }
            }.disabled(model.fileBusy)
            Section("导出到手机") {
                Button("下载WAV"){model.download(1)}.disabled(model.fileBusy || model.record?.downloadable(1) != true)
                Button("下载事件文件"){model.download(2)}.disabled(model.fileBusy || model.record?.downloadable(2) != true)
                Button("将事件录音转为曲谱"){model.exportEvents()}.disabled(model.fileBusy || model.record?.downloadable(2) != true)
                Text(model.fileStatus).font(.footnote)
                if model.fileBusy { Button("取消下载",role:.destructive){model.cancelFile()} }
                if let url=model.exportedFile { CompatibleShareButton(title:"分享或保存已验证文件",items:{[url]}) }
            }
            Section { Text("当前配套固件录音为48kHz单声道，合成输出仍为128kHz；兼容已有双声道录音。需插入FAT32格式SD卡；不要直接格式化有文件的卡。错误−12表示设备文件读写失败，需要结合设备日志确认。开始后等到“正在采集”再演奏；停止后等待“已验证保存”再下载。BLE下载较慢，请保持App在前台。\n本版可管理本App发起或已知编号的录音，不提供SD卡历史目录浏览。").font(.footnote) }
        }.disabled(!link.ready).navigationTitle("SD录音")
    }
}
struct KeymapView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @State var notes=[60,62,64,65,67,69,71,72]
    @State var teach=false
    @State var repeatScore=false
    var body: some View {
        Form {
            Section("8个实体键的MIDI音高") {
                ForEach(0..<8){i in Stepper("键 \(i+1)：\(notes[i])",value:$notes[i],in:24...103)}
                Button("应用实体键映射"){model.keymap(notes)}
            }
            Section("SD曲谱播放") {
                Toggle("教学模式",isOn:$teach);Toggle("循环播放",isOn:$repeatScore)
                Button("开始曲谱"){model.command(38,"播放曲谱",[1,UInt8((teach ? 1 : 0)|(repeatScore ? 2 : 0)),0,0,0,0,0,0],target:3)}
                Button("暂停"){model.command(38,"暂停曲谱",[4,0,0,0,0,0,0,0],target:3)}
                Button("继续"){model.command(38,"继续曲谱",[5,0,0,0,0,0,0,0],target:3)}
                Button("停止"){model.command(38,"停止曲谱",[3,0,0,0,0,0,0,0],target:3)}
                Text("曲谱文件为项目专用的SCORE.EVT，不是PDF、图片或普通MIDI。可在主界面“更多→上传曲谱到乐器”选择文件上传，乐器校验后替换卡上的SCORE.EVT；也可把文件复制到FAT32卡根目录。录音页面可将兼容的事件录音转换为曲谱；当前转换器对音色和效果设置有限制。").font(.caption)
                if !model.scoreStatus.isEmpty { Text(model.scoreStatus).font(.caption) }
            }
        }.disabled(!link.ready).navigationTitle("实体键与曲谱")
    }
}
