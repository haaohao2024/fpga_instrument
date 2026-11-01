import SwiftUI
import UIKit
import UniformTypeIdentifiers
import InstrumentCore

/// Second-level pages opened from the stage's "更多" menu.
enum StageSheet: String, Identifiable {
    case connection, sound, ensemble, loop, recording, keymap, spectrum, accompaniment
    var id: String { rawValue }
}

/// The main screen: an electronic-keyboard panel above a scrollable piano.
struct StageView: View {
    @ObservedObject var model: InstrumentModel
    @ObservedObject var link: BluetoothLink
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var startWhite=KeyLayout.whiteIndex(48)
    @State private var octaves: Double=UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1.5
    @State private var sheet: StageSheet?
    @State private var importing=false
    private var compact: Bool { verticalSize == .compact }
    private var visibleWhites: Int { Int((octaves*7).rounded()) }

    var body: some View {
        ZStack {
            Panel.ground.ignoresSafeArea()
            VStack(spacing:compact ? 5 : 8) {
                topBar
                controlStrip
                keyboardArea
                Text(model.feedback).font(.system(size:11)).foregroundColor(Panel.muted).lineLimit(1)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            .padding(.horizontal,compact ? 8 : 14).padding(.top,compact ? 4 : 8).padding(.bottom,4)
        }
        .preferredColorScheme(.dark)
        .sheet(item:$sheet) { s in
            NavigationView { StageSheetChrome(model:model) { page(s) } }.navigationViewStyle(.stack)
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data]) { result in uploadScore(result) }
        .onChange(of:model.guideNote) { n in if let n=n { follow(n) } }
        .onChange(of:octaves) { _ in startWhite=KeyLayout.clampStart(startWhite,visibleWhites:visibleWhites) }
        // Like Android's openPage()/closePage(): opening or leaving a second-level page
        // drops the notes the phone still holds in the instrument, so no note can stay
        // stuck under a finger while the sheet covers the keyboard.
        .onChange(of:sheet) { _ in model.releaseAll() }
        // Same as Android: a successful connection closes the connection page by itself.
        .onChange(of:link.ready) { ready in if ready, sheet == .connection { sheet = nil } }
        .onAppear {
            if !link.ready && !link.scanning { sheet = .connection }
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-demo") { sheet=nil;model.qaDemo() }
            #endif
        }
    }

    // MARK: Row A: effects, sound, volume, display, connection.
    private var topBar: some View {
        HStack(alignment:.bottom,spacing:10) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(alignment:.bottom,spacing:12) {
                    PanelGroup(title:"效果器",showTitle:!compact) {
                        fx("回声","echo",model.echo);fx("合唱","chorus",model.chorus);fx("混响","reverb",model.reverb);fx("旁路","bypass",model.bypass)
                    }
                    PanelGroup(title:"声音",showTitle:!compact) {
                        PanelSlider(title:"颤音",value:$model.vibratoDepth,range:0...255,width:compact ? 64 : 90,onCommit:model.applyVibrato)
                        PanelSlider(title:"释音",value:$model.releaseCode,range:0...7,format:{ "\(Int($0*21.333))ms" },width:compact ? 52 : 72,onCommit:model.applyRelease)
                        PanelSlider(title:"力度",value:$model.velocity,range:1...255,width:compact ? 56 : 80,onCommit:model.saveSettings)
                    }
                    PanelGroup(title:"音量",showTitle:!compact) {
                        PanelSlider(title:"合成",value:$model.synthVolume,range:0...1,step:0.01,format:{ "\(Int($0*100))" },width:compact ? 56 : 80,onCommit:model.applyGain)
                        PanelSlider(title:"伴奏",value:$model.accompanimentVolume,range:0...1,step:0.01,format:{ "\(Int($0*100))" },width:compact ? 56 : 80,onCommit:model.applyGain)
                    }
                }.padding(.vertical,2)
            }
            display
            VStack(alignment:.trailing,spacing:4) {
                Button { sheet = .connection } label: {
                    HStack(spacing:5) {
                        Circle().fill(link.ready ? Panel.ledGo : Color.orange).frame(width:8,height:8)
                        Text(link.ready ? "已连接" : "连接乐器").font(.system(size:12)).foregroundColor(Panel.text)
                    }
                }.buttonStyle(.plain)
                moreMenu
            }
        }
    }
    private func fx(_ title: String,_ key: String,_ on: Bool) -> some View {
        PanelButton(title:title,led:Panel.ledOn,isOn:on,compact:compact) { model.toggleEffect(key) }.disabled(!link.ready)
    }

    /// Small LCD: what is selected now, or which key the teaching mode wants next.
    private var display: some View {
        let topWhite=KeyLayout.whites[min(startWhite+visibleWhites-1,KeyLayout.whites.count-1)]
        let line1: String={
            if let g=model.guideNote { return "教学：请按 \(KeyLayout.name(g))" }
            return "\(InstrumentModel.timbres[model.timbre]) · \(KeyLayout.name(KeyLayout.whites[startWhite]))–\(KeyLayout.name(topWhite))"
        }()
        let line2: String={
            if model.teachMode && model.scorePlaying && !model.boardReportsGuide { return "琴键提示需要新版板载固件" }
            return "按住 \(model.client.heldKeys.count)/32 · 力度 \(Int(model.velocity))"
        }()
        return VStack(alignment:.leading,spacing:1) {
            Text(line1).font(.system(size:compact ? 12 : 14,weight:.semibold,design:.monospaced)).foregroundColor(Color(red:0.79,green:1,blue:0.85))
            if !compact { Text(line2).font(.system(size:11,design:.monospaced)).foregroundColor(Panel.lcdText) }
        }
        .lineLimit(1).padding(.horizontal,9).padding(.vertical,compact ? 4 : 6)
        .frame(minWidth:compact ? 150 : 190,alignment:.leading)
        .background(RoundedRectangle(cornerRadius:8).fill(Panel.lcdGround))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(Color(red:0.12,green:0.23,blue:0.17),lineWidth:1))
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button { sheet = .connection } label: { Label("连接与诊断",systemImage:"antenna.radiowaves.left.and.right") }
                Button { sheet = .sound } label: { Label("音色与声音细节",systemImage:"slider.horizontal.3") }
                Button { sheet = .ensemble } label: { Label("自动伴奏设置",systemImage:"music.note.list") }
                Button { sheet = .loop } label: { Label("循环叠录详情",systemImage:"repeat") }
                Button { sheet = .recording } label: { Label("SD 录音与下载",systemImage:"waveform") }
                Button { sheet = .keymap } label: { Label("实体键与曲谱",systemImage:"pianokeys") }
                Button { importing=true } label: { Label("上传曲谱到乐器",systemImage:"square.and.arrow.up") }.disabled(!link.ready || model.uploader.active)
                Button { sheet = .spectrum } label: { Label("赛题测试模式",systemImage:"chart.bar") }
                Button { sheet = .accompaniment } label: { Label("手机音乐伴奏",systemImage:"iphone.radiowaves.left.and.right") }
            }
            Section {
                Button { model.restoreSettings() } label: { Label("恢复上次设置",systemImage:"clock.arrow.circlepath") }.disabled(!model.hasSavedSettings)
                Button { model.demoPreset() } label: { Label("演示模式",systemImage:"sparkles") }
                Toggle("立体声展开（低音左、高音右）",isOn:$model.stereoSpread)
                Picker("一屏显示",selection:$octaves) {
                    Text("1.5 个八度").tag(1.5);Text("2 个八度").tag(2.0);Text("3 个八度").tag(3.0)
                }
            }
        } label: {
            Text("更多 ▾").font(.system(size:13,weight:.medium)).foregroundColor(Panel.text)
                .padding(.horizontal,11).padding(.vertical,compact ? 5 : 7).panelSurface(cornerRadius:10)
        }
    }

    // MARK: Row B: timbre, record/accompaniment, loop, score/teaching.
    private var controlStrip: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(alignment:.bottom,spacing:12) {
                PanelGroup(title:"音色",showTitle:!compact) {
                    ForEach(0..<6) { i in
                        PanelButton(title:InstrumentModel.timbres[i],isOn:model.timbre==i,compact:compact) { model.applyTimbre(i) }.disabled(!link.ready)
                    }
                }
                divider
                PanelGroup(title:"录音 · 伴奏",showTitle:!compact) {
                    PanelButton(title:"录音",detail:model.recording ? model.record?.description : nil,led:Panel.ledRec,isOn:model.recording,blinking:true,compact:compact) { model.toggleRecording() }
                    PanelButton(title:"自动伴奏",led:Panel.ledGo,isOn:model.ensembleOn,compact:compact) { model.toggleEnsemble() }
                }.disabled(!link.ready)
                divider
                PanelGroup(title:"循环叠录 · \(loopSummary)",showTitle:!compact) {
                    PanelButton(title:model.loopRecording ? "录制中" : "录第\(model.loopLayers+1)层",led:Panel.ledRec,isOn:model.loopRecording,blinking:true,compact:compact) { model.recordLoopLayer() }
                        .disabled(model.loopRecording || model.loopLayers>=4)
                    PanelButton(title:"■ 结束本层",compact:compact) { model.endLoopLayer() }.disabled(!model.loopRecording)
                    PanelButton(title:"↶ 撤销",compact:compact) { model.undoLoopLayer() }.disabled(model.loopRecording || model.loopLayers==0)
                    PanelButton(title:model.loop?.state==5 ? "播放" : "停止",led:Panel.ledGo,isOn:model.loop?.state==2,compact:compact) { model.toggleLoopPlayback() }
                        .disabled(model.loopRecording || model.loopLayers==0)
                    PanelButton(title:"清空",compact:compact) { model.clearLoop() }.disabled(model.loopRecording || model.loopLayers==0)
                }.disabled(!link.ready)
                divider
                PanelGroup(title:"曲谱 · 教学",showTitle:!compact) {
                    PanelButton(title:model.scorePlaying ? "■ 停止曲谱" : "▶ 播放曲谱",led:Panel.ledGo,isOn:model.scorePlaying,compact:compact) {
                        if model.scorePlaying { model.stopScore() } else { model.playScore() }
                    }
                    PanelButton(title:"教学",led:Panel.ledOn,isOn:model.teachMode,compact:compact) { model.teachMode.toggle() }.disabled(model.scorePlaying)
                }.disabled(!link.ready)
            }.padding(.vertical,2)
        }
    }
    private var divider: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(width:1,height:compact ? 26 : 40) }
    private var loopSummary: String {
        guard let l=model.loop else { return "空" }
        let seconds=Double(l.length)/l.sampleRate
        return l.layers==0 && !model.loopRecording ? "空" : "\(l.description) \(l.layers)/4 层\(seconds>0 ? String(format:" · %.1fs",seconds) : "")"
    }

    // MARK: Keyboard: overview strip on top, octave buttons at the sides.
    private var keyboardArea: some View {
        VStack(spacing:compact ? 4 : 6) {
            KeyboardOverview(startWhite:$startWhite,visibleWhites:visibleWhites,guideNote:model.guideNote).frame(height:compact ? 20 : 28)
            HStack(spacing:6) {
                octaveButton("‹",-7)
                PianoKeyboard(startWhite:startWhite,visibleWhites:visibleWhites,enabled:link.ready,guideNote:model.guideNote,
                              litNotes:model.physicalNotes,down:{ model.pressNote($0) },up:{ model.releaseNote($0) })
                    .clipShape(RoundedRectangle(cornerRadius:10)).accessibilityLabel("多指演奏钢琴键盘")
                octaveButton("›",7)
            }
            .frame(maxHeight:.infinity)
        }
        .frame(maxHeight:.infinity)
    }
    private func octaveButton(_ title: String,_ step: Int) -> some View {
        Button { startWhite=KeyLayout.clampStart(startWhite+step,visibleWhites:visibleWhites) } label: {
            Text(title).font(.system(size:18,weight:.semibold)).foregroundColor(Panel.text).frame(width:compact ? 26 : 34).frame(maxHeight:.infinity)
        }.buttonStyle(.plain).panelSurface(cornerRadius:10)
    }
    /// Keeps the teaching target on screen.
    private func follow(_ note: Int) {
        let w=KeyLayout.whiteIndex(note)
        if w<startWhite || w>=startWhite+visibleWhites { startWhite=KeyLayout.clampStart(w-visibleWhites/3,visibleWhites:visibleWhites) }
    }

    private func uploadScore(_ result: Result<URL,Error>) {
        guard case .success(let url)=result else { return }
        let scoped=url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data=try? Data(contentsOf:url) else { model.feedback="无法读取所选文件";return }
        model.uploader.start([UInt8](data))
    }

    @ViewBuilder private func page(_ s: StageSheet) -> some View {
        switch s {
        case .connection: ConnectionView(model:model,link:link)
        case .sound: SoundView(model:model,link:link)
        case .ensemble: EnsembleView(model:model,link:link,bpm:model.tempo)
        case .loop: LoopView(model:model,link:link)
        case .recording: RecordingView(model:model,link:link)
        case .keymap: KeymapView(model:model,link:link)
        case .spectrum: SpectrumTestView(model:model,link:link)
        case .accompaniment: AccompanimentHelp()
        }
    }
}

/// Navigation chrome shared by every page opened from the stage's "更多" menu.
/// The sheet gets a visible "返回" button in the top-left and a "完成" button in the
/// top-right; on an iPhone in landscape a sheet is close to full screen, so the
/// swipe-down gesture alone is not a usable way back. Both buttons release the
/// notes the phone still holds and then dismiss the sheet (iOS 15 safe API).
struct StageSheetChrome<Content: View>: View {
    let model: InstrumentModel
    let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    init(model: InstrumentModel, @ViewBuilder content: @escaping () -> Content) {
        self.model=model
        self.content=content
    }
    var body: some View {
        content()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    Button {
                        model.releaseAll(); dismiss()
                    } label: {
                        HStack(spacing:3) {
                            Image(systemName:"chevron.left").font(.system(size:15,weight:.semibold))
                            Text("返回").font(.system(size:16,weight:.medium))
                        }
                    }.accessibilityIdentifier("stage-back")
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button {
                        model.releaseAll(); dismiss()
                    } label: {
                        Text("完成").font(.system(size:16,weight:.medium))
                    }.accessibilityIdentifier("stage-done")
                }
            }
    }
}

struct AccompanimentHelp: View {
    var body: some View {
        Form {
            Section("首次连接") {
                Text("App 内连接只负责控制乐器，不会自动把手机音乐送到乐器。请先停止循环和自动伴奏，再打开 iPhone 的设置→蓝牙，连接 BTBLE-DEV。")
                Text("播放一首手机音乐，在控制中心的音频输出里选择 BTBLE-DEV。回到主界面调高“伴奏”音量。手机音量键可以直接调伴奏大小。")
            }
            Section("没有声音时") {
                Text("系统蓝牙或音频输出列表里没有设备，说明音频连接还没建立；主界面显示“已连接”只表示控制连接成功。")
            }
        }.navigationTitle("手机音乐伴奏")
    }
}
