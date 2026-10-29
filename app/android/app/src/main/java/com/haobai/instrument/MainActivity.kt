package com.haobai.instrument

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.bluetooth.BluetoothDevice
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.view.Gravity
import kotlin.math.roundToInt
import android.view.MotionEvent
import android.view.View
import android.widget.*
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.CRC32

/** Native client using the tested production protocol/controllers. */
class MainActivity : Activity(), BleInstrumentLink.Listener {
    private lateinit var link:BleInstrumentLink
    private lateinit var client:S9ClientSession
    private lateinit var upload:S9ScoreUpload
    private lateinit var download:S11Download
    private var recording:S11RecordInfo?=null
    private val recordingIds=S11RecordingIds(System.currentTimeMillis().coerceAtLeast(1))
    private var requestedRecording=0L
    private var downloaded:File?=null
    private lateinit var state:TextView
    private lateinit var feedback:TextView
    private lateinit var mediaState:TextView
    private lateinit var body:LinearLayout
    private var devices:LinearLayout?=null
    private var keyboard:PianoView?=null
    private val handler=Handler(Looper.getMainLooper())
    private var running=false
    private var page=0
    private var ensembleInfo:EnsembleInfo?=null
    private var voiceInfo:VoiceMetrics?=null
    private var ensembleText:TextView?=null
    private var loopText:TextView?=null
    private var loopDescription="尚未查询循环状态"
    private var lastVoicePoll=0L
    private var fieldText:TextView?=null
    private var fieldGeneration=0
    private var fieldRequested=false
    // Measured synthesis rate: opt-in, because the extra polling costs BLE bandwidth.
    private val rateMeter=SampleRateMeter()
    private var liveRate=false
    private var rateReading:SampleRateMeter.Reading?=null
    private var ratePending=false
    private var ratePolledAt=0L
    private var rateToggle:CheckBox?=null
    private var rateText:TextView?=null
    private var prepared:File?=null
    private var preparedCrc=0L
    private var preparing=false
    private var destroyed=false
    private var prepareGeneration=0
    private val ticker=object:Runnable {
        override fun run(){if(running){client.tick();if(::download.isInitialized)download.tick()
            val now=SystemClock.elapsedRealtime()
            if(client.connected&&client.pendingCount<2) {
                // The ensemble page keeps its one-second voice poll; the test page polls
                // only while the user asked for a live sample-rate reading.
                if(page==7&&now-lastVoicePoll>=1000){lastVoicePoll=now;client.parameter(41,byteArrayOf(),"读取硬件声部",3)}
                if(liveRate&&page==8&&!ratePending&&now-ratePolledAt>=1000){
                    ratePolledAt=now;ratePending=true
                    if(client.parameter(41,byteArrayOf(),"读取实测采样率",3)==null)ratePending=false
                }
            }
            // A lost answer must not stall the measurement; the next tick tries again.
            if(ratePending&&now-ratePolledAt>3000)ratePending=false
            // Loop status drives the stage's layer buttons while a loop exists.
            if(client.connected&&(loopState!=0||loopLayers>0)&&client.pendingCount<2&&now-lastLoopPoll>=1000){lastLoopPoll=now;client.parameter(101,byteArrayOf(),"查询循环",3)}
            handler.postDelayed(this,100)}}
    }
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        requestedRecording=getPreferences(MODE_PRIVATE).getLong("lastRecordID",0L)
        if(requestedRecording!=0L)recordingIds.observeRemote(requestedRecording)
        link=BleInstrumentLink(this,this)
        client=S9ClientSession(link::send,{reason->link.close();status(reason)},{feedback.text=it},SystemClock::elapsedRealtime)
        upload=S9ScoreUpload(client,{feedback.text=it})
        download=S11Download(client,{feedback.text=it},SystemClock::elapsedRealtime)
        loadSettings()
        // The stage is the home screen; the former pages open in a full-screen overlay from "更多".
        val root=FrameLayout(this)
        root.addView(buildStage(),FrameLayout.LayoutParams(-1,-1))
        overlay=buildOverlay();overlay.visibility=View.GONE
        root.addView(overlay,FrameLayout.LayoutParams(-1,-1))
        setContentView(root);refreshStage()
        // Android 13+: system back closes a second-level page before leaving the app.
        if(android.os.Build.VERSION.SDK_INT>=33)onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT){
            if(overlay.visibility==View.VISIBLE)closePage() else finish()
        }
        if(!client.connected)openPage(0,"连接与设备")
    }

    // ---------------- Stage (main screen) ----------------
    private var timbre=1
    private var releaseCode=4
    private var vibratoDepth=0
    private var velocity=160
    private var synthVolume=70
    private var accompanimentVolume=50
    private var fxEcho=false
    private var fxChorus=false
    private var fxReverb=false
    private var fxBypass=false
    private var stereoSpread=false
    private var tempo=100
    private var metronomeOn=false
    private var countIn=false
    private var recordingOn=false
    private var ensembleOn=false
    private var scorePlaying=false
    private var teachMode=false
    private var loopState=0
    private var loopLayers=0
    private var loopSeconds=0.0
    /** Reserved board notices 133..135; empty until a firmware sends them. */
    private var guideNote:Int?=null
    private var physicalNotes:Set<Int> = emptySet()
    private var boardReportsGuide=false
    private val noteSlots=HashMap<Int,Int>()
    private var octaves=1.5f
    private lateinit var piano:PianoStageView
    private lateinit var overview:KeyboardOverviewView
    private lateinit var lcd:TextView
    private lateinit var lcdDetail:TextView
    private lateinit var overlay:LinearLayout
    private lateinit var overlayTitle:TextView
    private val panel=HashMap<String,PanelButton>()
    private var tone:android.media.ToneGenerator?=null
    private var lastLoopPoll=0L
    private val visibleWhites get()=(octaves*7).roundToInt()
    private val compact get()=resources.configuration.screenHeightDp<500
    private val fxDefaults=longArrayOf(11520,12288,576,192,71583,24576,16384,6144,4096,4096)

    private fun pb(key:String,label:String,led:Int?=null,blink:Boolean=false,action:()->Unit)=PanelButton(this,label,led,blink,action).also{panel[key]=it}
    private fun hscroll(content:View)=HorizontalScrollView(this).apply{isHorizontalScrollBarEnabled=false;addView(content)}
    private fun row(vararg views:View)=LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.BOTTOM
        views.forEach{addView(it,LinearLayout.LayoutParams(-2,-2).apply{marginEnd=dp(12f).toInt()})}}

    private fun buildStage():View {
        val c=compact
        val stage=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setBackgroundColor(StagePalette.GROUND)
            val h=dp(if(c)8f else 14f).toInt();setPadding(h,dp(4f).toInt(),h,dp(4f).toInt())}
        // Row A: effects, sound, volume | display | connection + more
        val effects=panelGroup("效果器",!c,pb("echo","回声",StagePalette.LED_ON){fxEcho=!fxEcho;fxBypass=false;sendEffects()},
            pb("chorus","合唱",StagePalette.LED_ON){fxChorus=!fxChorus;fxBypass=false;sendEffects()},
            pb("reverb","混响",StagePalette.LED_ON){fxReverb=!fxReverb;fxBypass=false;sendEffects()},
            pb("bypass","旁路",StagePalette.LED_ON){fxBypass=!fxBypass;sendEffects()})
        val sound=panelGroup("声音",!c,
            panelSlider("颤音",255,vibratoDepth,if(c)64f else 90f,{"$it"}){vibratoDepth=it;client.vibrato(it);saveSettings()},
            panelSlider("释音",7,releaseCode,if(c)52f else 72f,{"${(it*21.333).roundToInt()}ms"}){releaseCode=it;client.pitchParameter(33,it);saveSettings()},
            panelSlider("力度",254,velocity-1,if(c)56f else 80f,{"${it+1}"}){velocity=it+1;saveSettings()})
        val volume=panelGroup("音量",!c,
            panelSlider("合成",100,synthVolume,if(c)56f else 80f,{"$it"}){synthVolume=it;sendGain()},
            panelSlider("伴奏",100,accompanimentVolume,if(c)56f else 80f,{"$it"}){accompanimentVolume=it;sendGain()})
        lcd=TextView(this).apply{textSize=if(c)12f else 14f;typeface=Typeface.create(Typeface.MONOSPACE,Typeface.BOLD);setTextColor(StagePalette.LCD_TEXT);setSingleLine(true)}
        lcdDetail=TextView(this).apply{textSize=11f;typeface=Typeface.MONOSPACE;setTextColor(0xff9fe3b4.toInt());setSingleLine(true);visibility=if(c)View.GONE else View.VISIBLE}
        val display=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;background=GradientDrawable().apply{setColor(StagePalette.LCD);cornerRadius=dp(8f)}
            setPadding(dp(9f).toInt(),dp(5f).toInt(),dp(9f).toInt(),dp(5f).toInt());minimumWidth=dp(if(c)150f else 190f).toInt();addView(lcd);addView(lcdDetail)}
        state=TextView(this).apply{text="未连接";textSize=12f;setTextColor(StagePalette.TEXT);setOnClickListener{openPage(0,"连接与设备")}}
        val more=PanelButton(this,"更多 ▾"){}
        more.setOnClickListener{showMoreMenu(more)}
        val side=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;gravity=Gravity.END;addView(state);addView(more)}
        stage.addView(LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.BOTTOM
            addView(hscroll(row(effects,sound,volume)),LinearLayout.LayoutParams(0,-2,1f))
            addView(display,LinearLayout.LayoutParams(-2,-2).apply{marginStart=dp(8f).toInt();marginEnd=dp(8f).toInt()})
            addView(side)})
        // Row B: timbre, record/accompaniment, loop layers, score/teaching, metronome
        val timbres=panelGroup("音色",!c,*toneNames.indices.map{i->pb("timbre$i",toneNames[i]){timbre=i;stageRelease();client.pitchParameter(32,i);saveSettings();refreshStage()}}.toTypedArray())
        val recordGroup=panelGroup("录音 · 伴奏",!c,pb("record","录音",StagePalette.LED_REC,true){toggleRecording()},pb("ensemble","自动伴奏",StagePalette.LED_GO){toggleEnsemble()})
        val loopGroup=panelGroup("循环叠录",!c,pb("loopRec","录第1层",StagePalette.LED_REC,true){recordLoopLayer()},
            pb("loopEnd","■ 结束本层"){loopCommand(97,"结束录制一层")},pb("loopUndo","↶ 撤销"){loopCommand(98,"撤销上一层")},
            pb("loopPlay","停止",StagePalette.LED_GO){if(loopState==5)loopCommand(102,"恢复循环") else loopCommand(99,"停止循环")},
            pb("loopClear","清空"){loopCommand(100,"清空循环")})
        val scoreGroup=panelGroup("曲谱 · 教学",!c,pb("score","▶ 播放曲谱",StagePalette.LED_GO){toggleScore()},pb("teach","教学",StagePalette.LED_ON){teachMode=!teachMode;refreshStage()})
        val metroGroup=panelGroup("节拍器",!c,pb("metro","节拍",StagePalette.LED_ON){toggleMetronome()},pb("countIn","预备拍",StagePalette.LED_ON){countIn=!countIn;refreshStage()},
            pb("slower","−"){tempo=(tempo-5).coerceAtLeast(40);tempoChanged()},pb("faster","＋"){tempo=(tempo+5).coerceAtMost(200);tempoChanged()})
        stage.addView(hscroll(row(timbres,recordGroup,loopGroup,scoreGroup,metroGroup)),LinearLayout.LayoutParams(-1,-2).apply{topMargin=dp(if(c)4f else 8f).toInt()})
        // Keyboard: overview strip, then octave buttons around the piano
        overview=KeyboardOverviewView(this){start->piano.startWhite=start;overview.startWhite=start;refreshStage()}
        stage.addView(overview,LinearLayout.LayoutParams(-1,dp(if(c)20f else 28f).toInt()).apply{topMargin=dp(if(c)4f else 8f).toInt()})
        piano=PianoStageView(this,::pressNote,::releaseNote)
        val octaveDown=PanelButton(this,"‹"){shift(-7)}.apply{textSize=18f;gravity=Gravity.CENTER}
        val octaveUp=PanelButton(this,"›"){shift(7)}.apply{textSize=18f;gravity=Gravity.CENTER}
        stage.addView(LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL
            addView(octaveDown,LinearLayout.LayoutParams(dp(if(c)28f else 36f).toInt(),-1))
            addView(piano,LinearLayout.LayoutParams(0,-1,1f).apply{marginStart=dp(6f).toInt();marginEnd=dp(6f).toInt()})
            addView(octaveUp,LinearLayout.LayoutParams(dp(if(c)28f else 36f).toInt(),-1))
        },LinearLayout.LayoutParams(-1,0,1f).apply{topMargin=dp(4f).toInt()})
        feedback=TextView(this).apply{textSize=11f;setTextColor(StagePalette.MUTED);setSingleLine(true);text="请先连接乐器"}
        stage.addView(feedback)
        return stage
    }
    private fun buildOverlay():LinearLayout = LinearLayout(this).apply {
        orientation=LinearLayout.VERTICAL;setBackgroundColor(Color.WHITE);setPadding(dp(16f).toInt(),dp(8f).toInt(),dp(16f).toInt(),dp(8f).toInt())
        overlayTitle=TextView(context).apply{textSize=20f}
        addView(LinearLayout(context).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL
            addView(Button(context).apply{text="← 返回演奏台";setOnClickListener{closePage()}});addView(overlayTitle,LinearLayout.LayoutParams(-2,-2).apply{marginStart=dp(12f).toInt()})})
        mediaState=TextView(context).apply{text="设备尚未提供伴奏数字状态";textSize=13f};addView(mediaState)
        body=LinearLayout(context).apply{orientation=1}
        addView(ScrollView(context).apply{addView(body)},LinearLayout.LayoutParams(-1,0,1f))
    }
    private fun openPage(index:Int,title:String) {stageRelease();overlayTitle.text=title;overlay.visibility=View.VISIBLE;showPage(index)}
    /** Back to the stage: stop the page's own task, drop phone-held notes, hide the overlay. */
    private fun closePage() {if(page==8){stopFieldTest();stopLiveRate()};stageRelease();rateToggle=null;rateText=null;body.removeAllViews();overlay.visibility=View.GONE;page=-1;refreshStage()}
    @Deprecated("Native back handling")
    override fun onBackPressed() {if(::overlay.isInitialized&&overlay.visibility==View.VISIBLE)closePage() else super.onBackPressed()}

    private fun showMoreMenu(anchor:View) {
        val menu=PopupMenu(this,anchor)
        val pages=listOf("连接与设备" to 0,"音色与效果参数" to 2,"实体键映射" to 3,"曲谱播放与上传" to 4,"录音文件" to 5,"循环叠录详情" to 6,"自动伴奏设置" to 7,"赛题测试（48路）" to 8)
        pages.forEachIndexed{i,(t,_)->menu.menu.add(0,i,i,t)}
        menu.menu.add(1,100,100,"手机音乐伴奏")
        menu.menu.add(1,101,101,"恢复上次设置").isEnabled=getSharedPreferences("stage",MODE_PRIVATE).contains("timbre")
        menu.menu.add(1,102,102,"演示模式")
        menu.menu.add(1,103,103,"立体声展开（低音左、高音右）").apply{isCheckable=true;isChecked=stereoSpread}
        menu.menu.add(1,104,104,"一屏显示：1.5 个八度")
        menu.menu.add(1,105,105,"一屏显示：2 个八度")
        menu.menu.add(1,106,106,"一屏显示：3 个八度")
        menu.setOnMenuItemClickListener{item->
            when(item.itemId) {
                in pages.indices->openPage(pages[item.itemId].second,pages[item.itemId].first)
                100->android.app.AlertDialog.Builder(this).setTitle("手机音乐伴奏").setMessage("App 内连接只负责控制乐器。请在系统蓝牙里连接 BTBLE-DEV，播放手机音乐并把输出选为该设备，回到演奏台调高“伴奏”音量。手机音量键可直接调伴奏大小。").setPositiveButton("知道了",null).show()
                101->restoreSettings()
                102->demoPreset()
                103->{stereoSpread=!stereoSpread;saveSettings()}
                104->setOctaves(1.5f)
                105->setOctaves(2f)
                106->setOctaves(3f)
            }
            true
        }
        menu.show()
    }
    private fun setOctaves(o:Float){octaves=o;piano.visibleWhites=visibleWhites;shift(0)}
    private fun shift(step:Int){val s=KeyRange.clampStart(piano.startWhite+step,visibleWhites);piano.startWhite=s;overview.startWhite=s;overview.visibleWhites=visibleWhites;refreshStage()}

    /** Plays a note on the first free phone key slot; the protocol allows 32 held keys. */
    private fun pressNote(note:Int):Boolean {
        if(fieldRequested||noteSlots.containsKey(note))return false
        val slot=(0 until 32).firstOrNull{it !in noteSlots.values}?:return false
        if(!client.press(slot,note,velocity))return false
        noteSlots[note]=slot
        if(stereoSpread)client.pan(slot,((note-KeyRange.LOW)*256/(KeyRange.HIGH-KeyRange.LOW)).coerceIn(0,256))
        refreshStage();return true
    }
    private fun releaseNote(note:Int){noteSlots.remove(note)?.let{client.release(it)};refreshStage()}
    private fun stageRelease(){if(::piano.isInitialized)piano.cancel();noteSlots.clear();client.releaseAll()}

    private fun sendEffects() {
        val bits=(if(fxEcho)1 else 0) or (if(fxChorus)2 else 0) or (if(fxReverb)4 else 0) or (if(fxBypass)8 else 0)
        client.parameter(35,S9Protocol.effects(longArrayOf(bits.toLong(),*fxDefaults)),"效果器");saveSettings();refreshStage()
    }
    private fun sendGain(){client.parameter(36,S9Protocol.gain(synthVolume*32768/100,accompanimentVolume*32768/100,false,false),"音量",5);saveSettings()}
    private fun toggleRecording() {
        if(recordingOn) {
            val id=recording?.id?.takeIf{it!=0L}?:requestedRecording
            if(id!=0L)client.fileCommand(S11Protocol.STOP,S11Protocol.id(id),"停止录音",3);recordingOn=false
        } else if(!download.active&&!upload.active) {
            val id=recordingIds.next()
            if(client.fileCommand(S11Protocol.START,S11Protocol.start(id,3),"开始录音",3)!=null){requestedRecording=id;getPreferences(MODE_PRIVATE).edit().putLong("lastRecordID",id).apply();recordingOn=true}
        }
        refreshStage()
    }
    private fun toggleEnsemble() {
        if(ensembleOn)client.parameter(105,byteArrayOf(),"停止智能合奏",4)
        else client.parameter(104,EnsembleProtocol.start(2,0,0,tempo.coerceIn(50,180),0),"启动智能合奏",4)
        ensembleOn=!ensembleOn;refreshStage()
    }
    private fun loopCommand(op:Int,label:String){client.parameter(op,byteArrayOf(),label,4,completed={client.parameter(101,byteArrayOf(),"查询循环",3)})}
    /** Each layer is started and ended explicitly; the next layer waits for the player. */
    private fun recordLoopLayer() {
        stageRelease()
        val begin:()->Unit={client.parameter(32,byteArrayOf(timbre.toByte()),"本层音色",3,completed={client.parameter(96,byteArrayOf(timbre.toByte()),"开始录制一层",4,completed={client.parameter(101,byteArrayOf(),"查询循环",3)})})}
        if(countIn)beats(4,begin) else begin()
    }
    private fun toggleScore() {
        if(scorePlaying){client.parameter(38,byteArrayOf(3,0,0,0,0,0,0,0),"停止曲谱",3);guideNote=null}
        else client.parameter(38,byteArrayOf(1,(if(teachMode)1 else 0).toByte(),0,0,0,0,0,0),"播放曲谱",3)
        scorePlaying=!scorePlaying;refreshStage()
    }
    private fun click(){try{if(tone==null)tone=android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC,80);tone?.startTone(android.media.ToneGenerator.TONE_PROP_BEEP,40)}catch(_:RuntimeException){}}
    private val metronomeTick=object:Runnable{override fun run(){if(metronomeOn){click();handler.postDelayed(this,60000L/tempo)}}}
    private fun toggleMetronome(){metronomeOn=!metronomeOn;handler.removeCallbacks(metronomeTick);if(metronomeOn)handler.post(metronomeTick);refreshStage()}
    private fun tempoChanged(){if(metronomeOn){handler.removeCallbacks(metronomeTick);handler.post(metronomeTick)};saveSettings();refreshStage()}
    private fun beats(n:Int,done:()->Unit){click();if(n<=1)handler.postDelayed(done,60000L/tempo) else handler.postDelayed({beats(n-1,done)},60000L/tempo)}

    private fun refreshStage() {
        if(!::piano.isInitialized)return
        val ready=client.connected
        panel["echo"]?.on=fxEcho;panel["chorus"]?.on=fxChorus;panel["reverb"]?.on=fxReverb;panel["bypass"]?.on=fxBypass
        toneNames.indices.forEach{panel["timbre$it"]?.on=it==timbre}
        panel["record"]?.on=recordingOn;panel["ensemble"]?.on=ensembleOn
        val recordingLayer=loopState==1||loopState==3
        panel["loopRec"]?.apply{label=if(recordingLayer)"录制中" else "录第${loopLayers+1}层";on=recordingLayer;isEnabled=ready&&!recordingLayer&&loopLayers<4}
        panel["loopEnd"]?.isEnabled=ready&&recordingLayer
        listOf("loopUndo","loopClear").forEach{panel[it]?.isEnabled=ready&&!recordingLayer&&loopLayers>0}
        panel["loopPlay"]?.apply{label=if(loopState==5)"播放" else "停止";on=loopState==2;isEnabled=ready&&!recordingLayer&&loopLayers>0}
        panel["score"]?.apply{label=if(scorePlaying)"■ 停止曲谱" else "▶ 播放曲谱";on=scorePlaying}
        panel["teach"]?.apply{on=teachMode;isEnabled=!scorePlaying}
        panel["metro"]?.apply{on=metronomeOn;label="节拍 $tempo"};panel["countIn"]?.on=countIn
        listOf("echo","chorus","reverb","bypass","record","ensemble","score","teach").forEach{panel[it]?.isEnabled=ready&&(it!="teach"||!scorePlaying)}
        toneNames.indices.forEach{panel["timbre$it"]?.isEnabled=ready}
        piano.enabledForPlay=ready;piano.guideNote=guideNote;piano.litNotes=physicalNotes
        overview.guideNote=guideNote;overview.startWhite=piano.startWhite;overview.visibleWhites=visibleWhites
        val top=KeyRange.whites[minOf(piano.startWhite+visibleWhites-1,KeyRange.whites.size-1)]
        lcd.text=guideNote?.let{"教学：请按 ${KeyRange.name(it)}"}?:"${toneNames[timbre]} · ${KeyRange.name(KeyRange.whites[piano.startWhite])}–${KeyRange.name(top)}"
        lcdDetail.text=if(teachMode&&scorePlaying&&!boardReportsGuide)"琴键提示需要新版板载固件" else "按住 ${noteSlots.size}/32 · 力度 $velocity"
    }
    private fun followGuide(n:Int){val w=KeyRange.whiteIndex(n);if(w<piano.startWhite||w>=piano.startWhite+visibleWhites)shift(w-visibleWhites/3-piano.startWhite)}

    /** Reserved notices: 133 guide [1,n,notes], 134 physical keys [1,0,16-byte bitmap],
     * 135 board parameters [1,timbre,release,vibrato,effects]. See docs/app_reserved_notices.md. */
    private fun reservedNotice(message:S9Message) {
        val p=message.payload
        when(message.opcode) {
            133->if(p.size>=2&&p[0].toInt()==1&&p.size>=2+(p[1].toInt() and 255)){boardReportsGuide=true;guideNote=if(p[1].toInt()!=0)(p[2].toInt() and 255) else null;guideNote?.let(::followGuide)}
            134->if(p.size==18&&p[0].toInt()==1)physicalNotes=(0 until 128).filter{(p[2+it/8].toInt() shr (it%8)) and 1==1}.toSet()
            135->if(p.size>=5&&p[0].toInt()==1&&p[1] in 0..5&&p[2] in 0..11){timbre=p[1].toInt();releaseCode=p[2].toInt();vibratoDepth=p[3].toInt() and 255
                val f=p[4].toInt();fxEcho=f and 1!=0;fxChorus=f and 2!=0;fxReverb=f and 4!=0;fxBypass=f and 8!=0}
        }
        refreshStage()
    }

    // Remembered settings: saved locally, sent to the board only when restored.
    private fun saveSettings()=getSharedPreferences("stage",MODE_PRIVATE).edit().putInt("timbre",timbre).putInt("release",releaseCode).putInt("vibrato",vibratoDepth)
        .putInt("velocity",velocity).putInt("synth",synthVolume).putInt("accomp",accompanimentVolume).putBoolean("echo",fxEcho).putBoolean("chorus",fxChorus)
        .putBoolean("reverb",fxReverb).putBoolean("bypass",fxBypass).putBoolean("stereo",stereoSpread).putInt("tempo",tempo).apply()
    private fun loadSettings() {
        val s=getSharedPreferences("stage",MODE_PRIVATE)
        stereoSpread=s.getBoolean("stereo",false);tempo=s.getInt("tempo",100)
        octaves=if(resources.configuration.smallestScreenWidthDp>=600)2f else 1.5f
    }
    private fun restoreSettings() {
        val s=getSharedPreferences("stage",MODE_PRIVATE)
        timbre=s.getInt("timbre",timbre);releaseCode=s.getInt("release",releaseCode);vibratoDepth=s.getInt("vibrato",vibratoDepth);velocity=s.getInt("velocity",velocity)
        synthVolume=s.getInt("synth",synthVolume);accompanimentVolume=s.getInt("accomp",accompanimentVolume)
        fxEcho=s.getBoolean("echo",fxEcho);fxChorus=s.getBoolean("chorus",fxChorus);fxReverb=s.getBoolean("reverb",fxReverb);fxBypass=s.getBoolean("bypass",fxBypass)
        pushStage("恢复上次设置")
    }
    /** Preset for filming: FM piano, echo + reverb, medium vibrato. */
    private fun demoPreset(){timbre=1;releaseCode=4;vibratoDepth=96;velocity=170;synthVolume=70;accompanimentVolume=50;fxEcho=true;fxChorus=false;fxReverb=true;fxBypass=false;saveSettings();pushStage("演示模式")}
    private fun pushStage(label:String) {
        if(!client.connected){feedback.text="$label：界面已更新，连接后再选一次发送到乐器";refreshStage();return}
        stageRelease();client.pitchParameter(32,timbre);client.pitchParameter(33,releaseCode);client.vibrato(vibratoDepth);sendGain();sendEffects()
        feedback.text="$label：已发送到乐器";refreshStage()
    }
    private fun label(text:String){body.addView(TextView(this).apply {this.text=text;textSize=16f})}
    private fun button(text:String,action:()->Unit) {body.addView(Button(this).apply {this.text=text;setOnClickListener {guard(action)}})}
    private fun guard(action:()->Unit) {try {action()}catch(e:IllegalArgumentException){feedback.text="参数不合法：${e.message?:"请检查数值范围"}"}catch(e:java.io.IOException){feedback.text="文件读取失败：${e.message}"}}
    private fun number(title:String,value:Int):EditText {
        label(title);return EditText(this).apply {inputType=InputType.TYPE_CLASS_NUMBER;setText(value.toString());body.addView(this)}
    }
    private fun checked(text:String,initial:Boolean=false)=CheckBox(this).apply {this.text=text;isChecked=initial;body.addView(this)}
    private fun showPage(index:Int) {
        if(page==8 && index!=8){stopFieldTest();stopLiveRate()}
        keyboard?.cancel();client.releaseAll();keyboard=null;devices=null
        rateToggle=null;rateText=null
        body.removeAllViews();ensembleText=null;loopText=null;fieldText=null;page=index
        when(index){0->connectionPage();1->performancePage();2->parameterPage();3->mappingPage();4->scorePage();5->recordingPage();6->loopPage();7->ensemblePage();8->fieldTestPage()}
    }
    private fun connectionPage() {
        button("扫描乐器") {
            val permissions=link.missingPermissions()
            if(permissions.isEmpty()){devices?.removeAllViews();link.scan()} else requestPermissions(permissions,9)
        }
        button("断开并清理手机持音"){client.releaseAll();link.close()}
        button("刷新设备状态"){link.requestInfo()}
        button("复制连接诊断（不含音符、密钥）"){
            val clipboard=getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("GATT诊断",link.diagnostics()))
            feedback.text="已复制连接时序诊断，可粘贴给助手"
        }
        devices=LinearLayout(this).apply {orientation=1;body.addView(this)}
        label("首次连接可能需要系统配对确认。设备启动与共存尚未完成实机验收。")
    }
    private fun performancePage() {
        label("16键支持多点触控；移出原键、触摸取消或退出此页会释放。")
        val base=number("第一键 MIDI 音高（0～112）",60)
        val pressure=number("力度（1～255）",160)
        val piano=PianoView({key->
            val note=base.text.toString().toIntOrNull();val velocity=pressure.text.toString().toIntOrNull()
            if(note==null||note !in 0..112||velocity==null||velocity !in 1..255){feedback.text="请填写有效音高/力度";false}
            else client.press(key,note+key,velocity)
        },client::release)
        keyboard=piano;body.addView(piano,LinearLayout.LayoutParams(-1,360))
        val depth=number("全局颤音深度（0～255）",0)
        button("发送颤音"){client.vibrato(depth.text.toString().toInt())}
        val key=number("持音键号（0～15）",0)
        val target=number("该持音目标音高（0～127）",60)
        button("更新该持音音高/力度"){client.expression(key.text.toString().toInt(),target.text.toString().toInt(),pressure.text.toString().toInt())}
        val pan=number("该持音 Pan（0左、128中、256右）",128)
        button("查询实例后设置Pan"){if(!client.pan(key.text.toString().toInt(),pan.text.toString().toInt()))feedback.text="所选键没有当前持音，未发送Pan"}
        button("释放全部手机持音"){piano.cancel();client.releaseAll()}
    }
    private fun parameterPage() {
        label("下列值为本次编辑值，不代表设备已生效值。请以执行反馈为准。")
        val timbre=choices("新按下琴键的音色",toneNames)
        button("应用音色"){client.pitchParameter(32,timbre.selectedItemPosition)}
        val glide=number("松手后的衰减时间（0～7，越大越长）",0)
        button("设置松手衰减"){client.pitchParameter(33,glide.text.toString().toInt())}
        val local=number("本地增益（0～32768）",32768)
        val external=number("外部增益（0～32768）",32768)
        val lm=checked("本地静音");val em=checked("外部静音")
        button("设置增益/静音，等待到达目标") {
            client.parameter(36,S9Protocol.gain(local.text.toString().toInt(),external.text.toString().toInt(),lm.isChecked,em.isChecked),"增益",5)
        }
        label("效果器：原始定点参数，按既定范围校验。")
        val delay=checked("Delay");val chorus=checked("Chorus");val reverb=checked("Reverb");val bypass=checked("总旁路",true)
        val names=listOf("Delay长度 1～16383","Delay反馈 0～24576","Chorus基准 96～1440","Chorus深度 0～480","Chorus步长 0或4474～447392","Reverb反馈 0～28672","Reverb扩散 0～28672","Delay返回 0～8192","Chorus返回 0～8192","Reverb返回 0～8192")
        val defaults=listOf(11520,12288,576,192,71583,24576,16384,6144,4096,4096)
        val fields=names.mapIndexed {i,n->number(n,defaults[i])}
        fun fx(clear:Int):ByteArray {
            val bits=(if(delay.isChecked)1 else 0) or (if(chorus.isChecked)2 else 0) or (if(reverb.isChecked)4 else 0) or (if(bypass.isChecked)8 else 0) or (clear shl 4)
            return S9Protocol.effects(longArrayOf(bits.toLong(),*fields.map {it.text.toString().toLong()}.toLongArray()))
        }
        button("提交效果参数"){client.parameter(35,fx(0),"效果参数")}
        button("独立清除三种尾音"){client.parameter(35,fx(7),"清尾音")}
    }
    private val toneNames=listOf("基础正弦","FM音色","谐波音色A","谐波音色B","波形塑形","简易鼓组")
    private fun choices(title:String,values:List<String>):Spinner {
        label(title);return Spinner(this).apply {adapter=ArrayAdapter(this@MainActivity,android.R.layout.simple_spinner_dropdown_item,values);body.addView(this)}
    }
    private fun loopPage(){
        label("第一层开始/结束决定循环长度；随后可叠录，最多4层。现场琴键始终由FPGA直接发声。")
        label("循环、智能合奏、文件录音与外部音频目前按模式使用；设备繁忙会明确拒绝新模式。")
        loopText=TextView(this).apply {text=loopDescription;textSize=16f;body.addView(this)}
        val tone=choices("本层音色",toneNames)
        button("开始录制一层"){
            val timbre=tone.selectedItemPosition
            client.parameter(32,byteArrayOf(timbre.toByte()),"本层音色",3,completed={client.parameter(96,byteArrayOf(timbre.toByte()),"开始叠录",4)})
        }
        button("结束录制，加入循环"){client.parameter(97,byteArrayOf(),"结束叠录",4)}
        button("撤销上一层"){client.parameter(98,byteArrayOf(),"撤销上一层",4)}
        button("停止循环"){client.parameter(99,byteArrayOf(),"停止循环",4)}
        button("恢复循环"){client.parameter(102,byteArrayOf(),"恢复循环",4)}
        button("清空所有层"){client.parameter(100,byteArrayOf(),"清空循环",4)}
        button("刷新循环状态"){client.parameter(101,byteArrayOf(),"查询循环",3)}
        label("鼓组8键依次为：底鼓、军鼓、闭镲、开镲、低嗵鼓、高嗵鼓、拍手、镲。")
    }
    private fun ensemblePage(){
        label("实体琴键直接演奏；BL616分析演奏事件并排程伴奏，FPGA合成全部声音。")
        ensembleText=TextView(this).apply {text=ensembleDescription();textSize=16f;body.addView(this)}
        val level=choices("丰富度",listOf("基础：和弦","标准：和弦＋低音＋鼓","丰富：分层和声＋低音＋鼓＋回应"));level.setSelection(2)
        val key=choices("主音",listOf("C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"))
        val mode=choices("调式",listOf("大调","自然小调"))
        val bpm=number("速度 BPM（50～180）",120)
        val style=choices("伴奏风格",listOf("常规","柔和","律动"))
        button("启动智能合奏"){
            client.parameter(104,EnsembleProtocol.start(level.selectedItemPosition,key.selectedItemPosition,mode.selectedItemPosition,bpm.text.toString().toInt(),style.selectedItemPosition),"启动智能合奏",4)
        }
        button("停止伴奏，继续现场演奏"){client.parameter(105,byteArrayOf(),"停止智能合奏",4)}
        button("刷新合奏与硬件状态"){client.parameter(106,byteArrayOf(),"读取合奏状态",3);client.parameter(41,byteArrayOf(),"读取硬件声部",3)}
        label("伴奏可根据最近音符调整和声；节拍按设定BPM运行。回应旋律在玩家停顿时出现。断开手机不影响实体琴键或已启动的伴奏。")
        label("声部统计来自FPGA。非零贡献在效果器/总增益之前测量，不能替代最终音频测量或直接当作比赛得分。")
    }
    private fun ensembleDescription():String = (ensembleInfo?.description()?:"尚未取得合奏状态")+"\n"+(voiceInfo?.description()?:"尚未取得FPGA硬件声部状态")
    private fun mappingPage() {
        label("8键基础音高（24～103）；全释放且本地事件提交完毕后原子生效。断电不保存。")
        val fields=listOf(60,62,64,65,67,69,71,72).mapIndexed {i,n->number("FSR ${i+1}",n)}
        button("提交整张键位表"){client.parameter(37,S9Protocol.keymap(fields.map {it.text.toString().toInt()}),"8键映射")}
    }
    private fun scorePage() {
        label("固定 SCORE.EVT；上传先停止曲谱。仅设备确认SAVED才算保存成功。")
        label(prepared?.let {"已准备 ${it.length()} 字节"}?:"尚未选择文件")
        button("选择曲谱文件") {
            if(!upload.active&&!preparing)startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {type="*/*";addCategory(Intent.CATEGORY_OPENABLE)},10)
        }
        button("上传并保存到SD") {
            val file=prepared?:throw IllegalArgumentException("先选择文件")
            if(!upload.active) {
                val input=RandomAccessFile(file,"r")
                upload.start(object:S9ScoreUpload.Source {
                    override val length=file.length().toInt();override val crc=preparedCrc
                    override fun read(offset:Int,count:Int):ByteArray=ByteArray(count).also {input.seek(offset.toLong());input.readFully(it)}
                    override fun close(){input.close()}
                })
            }
        }
        button("取消上传"){upload.cancel()}
        val teach=checked("教学模式（不自动发声音符）");val loop=checked("循环")
        fun play(command:Int,arg:Int=0) {client.parameter(38,byteArrayOf(command.toByte(),arg.toByte(),0,0,0,0,0,0),"曲谱命令 $command",3)}
        button("开始播放/教学"){play(1,(if(teach.isChecked)1 else 0) or (if(loop.isChecked)2 else 0))}
        button("暂停并释放曲谱持音"){play(4)}
        button("继续（持音重新Attack）"){play(5)}
        button("停止曲谱"){play(3)}
    }
    private fun recordingPage() {
        label(recording?.description()?:"尚未取得记录状态")
        label("当前固件录音48kHz单声道，合成输出128kHz；兼容已有双声道录音。")
        val event=checked("完整演奏事件记录",true)
        val pcm=checked("声音WAV（48kHz单声道）",true)
        label("先准备SD文件后开始；伴奏运行时的最终回读校验可能等待。录制与下载/上传互斥。")
        button("开始记录") {
            require(!download.active && !upload.active)
            val mask=(if(pcm.isChecked)1 else 0) or (if(event.isChecked)2 else 0)
            require(mask!=0)
            val id=recordingIds.next()
            if(client.fileCommand(S11Protocol.START,S11Protocol.start(id,mask),"请求开始记录",3)!=null) {
                requestedRecording=id;getPreferences(MODE_PRIVATE).edit().putLong("lastRecordID",id).apply()
                feedback.text="开始请求已排队，等待设备实际采集状态"
            }
        }
        button("停止并排空记录") {
            val id=recording?.id?.takeIf{it!=0L}?:requestedRecording
            require(id!=0L)
            client.fileCommand(S11Protocol.STOP,S11Protocol.id(id),"请求停止记录",3)
        }
        button("查询实际记录/保存状态") {
            val id=recording?.id?.takeIf{it!=0L}?:requestedRecording
            require(id!=0L){"请先录音，再查询这段录音的状态"}
            client.fileCommand(S11Protocol.STATUS,S11Protocol.id(id),"查询记录状态",3)
        }
        button("下载已验证WAV") {beginDownload(1)}
        button("下载已验证EVR") {beginDownload(2)}
        button("取消文件下载") {download.cancel()}
        button("导出兼容子集SCORE.EVT") {
            val value=recording?:throw IllegalArgumentException("请先查询记录")
            require(value.downloadable(2))
            client.fileCommand(S11Protocol.EXPORT,S11Protocol.id(value.id),"请求兼容曲谱导出",3)
        }
        button("将已下载文件保存到选定位置") {
            val value=downloaded?:throw IllegalArgumentException("尚无完成下载的文件")
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE);type=if(value.extension=="WAV")"audio/wav" else "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE,value.name)
            },11)
        }
        label("48路现场测试：先停止合奏/循环/曲谱/录音并调低功放音量。48路保持30秒后自动停止；旧1/8/16/32路仍是短测试。需要本次配套固件，旧固件会拒绝48路。")
        button("打开赛题测试（48路）"){showPage(8)}
    }
    private fun fieldTestPage() {
        label("当前FPGA：48个独立振荡器。测试先设置基础正弦、关闭颤音、旁路效果器，保留输出增益。请先停止合奏/循环/曲谱/录音、松开实体键并调低功放音量。测试后声音设置保留。")
        button("启动48路测试（30秒）"){startFieldTest(48)}
        button("停止测试"){stopFieldTest()}
        fieldText=TextView(this).apply {text=voiceInfo?.description()?:"尚未取得硬件计数";textSize=16f;body.addView(this)}
        // Live measurement of the real synthesis rate; off until the user asks for it.
        rateToggle=CheckBox(this).apply {text="实时测量采样率";isChecked=liveRate;setOnCheckedChangeListener{_,on->setLiveRate(on)};body.addView(this)}
        label("测量会占用蓝牙带宽，播放蓝牙伴奏时请关闭。")
        rateText=TextView(this).apply {textSize=16f;body.addView(this)}
        refreshRateText()
        button("刷新实际硬件统计"){client.parameter(41,byteArrayOf(),"读取测试硬件声部",3)}
        label("下列是短测试，约10.7ms后结束；48路测试30秒后自动结束。需要配套R87固件，旧固件会拒绝48路。断链后原生测试最迟30秒结束。")
        listOf(1,8,16,32).forEach {n->button("原生短测试 $n 路"){startFieldTest(n)}}
        label("预期基频（不是实测频谱）：")
        (48..95).forEach {note->label("MIDI $note · ${String.format(java.util.Locale.US,"%.2f",440.0*Math.pow(2.0,(note-69)/12.0))} Hz")}
        label("请求48路不等于已验证48个谱峰。请采集真实音频检查独立基频；容量、占槽、非零贡献快照和每帧完成数分别判断，谐波和噪声不计额外振荡器。评分使用实际音频输出采样率，不能使用48kHz录音率代替128kHz输出率。")
    }
    /** Turns the live measurement on or off; the checkbox is the only entry point. */
    private fun setLiveRate(on:Boolean) {
        liveRate=on;rateMeter.reset();rateReading=null;ratePending=false
        if(on) {
            ratePolledAt=SystemClock.elapsedRealtime()
            if(client.connected&&client.parameter(41,byteArrayOf(),"读取实测采样率",3)!=null)ratePending=true
        }
        refreshRateText()
    }
    /** Stops measuring and drops what it showed; safe to call at any time. */
    private fun stopLiveRate() {
        liveRate=false;rateMeter.reset();rateReading=null;ratePending=false
        rateToggle?.let{if(it.isChecked)it.isChecked=false}
        refreshRateText()
    }
    private fun refreshRateText() {
        val view=rateText?:return
        val reading=rateReading
        view.text=when {
            !liveRate->""
            reading!=null->reading.summary()+"\n"+SampleRateMeter.PROVENANCE
            else->"测量中…（至少 5 秒后出结果）"
        }
    }
    private fun startFieldTest(voices:Int) {
        if(!client.connected||fieldRequested){feedback.text="请连接设备并先停止当前测试";return}
        client.releaseAll();fieldRequested=true;val token=++fieldGeneration
        client.pitchParameter(32,0) {
            if(token==fieldGeneration)client.vibrato(0) {
                if(token==fieldGeneration)client.parameter(35,S9Protocol.effects(longArrayOf(8,11520,12288,576,192,71583,24576,16384,6144,4096,4096)),"测试：旁路效果器",4,
                    rejected={if(token==fieldGeneration){fieldRequested=false;fieldGeneration++}},
                    completed={if(token==fieldGeneration)client.parameter(S11Protocol.FIELD_TEST,S11Protocol.field(voices),"现场测试 $voices 路",4,
                        rejected={if(token==fieldGeneration){fieldRequested=false;fieldGeneration++}},
                        completed={handler.postDelayed({if(token==fieldGeneration)fieldRequested=false},if(voices==48)31000L else 1000L)})})
            }
        }
    }
    private fun stopFieldTest() {
        fieldGeneration++
        if(fieldRequested&&client.connected)client.parameter(S11Protocol.FIELD_TEST,S11Protocol.field(0),"停止现场测试",4)
        fieldRequested=false
    }
    private fun beginDownload(kind:Int) {
        val value=recording?:throw IllegalArgumentException("请先查询记录状态")
        require(value.downloadable(kind) && !upload.active)
        val directory=getExternalFilesDir(null)?:filesDir
        val target=File(directory,"R${value.id}.${if(kind==1)"WAV" else "EVR"}")
        val partial=File(directory,target.name+".part")
        val stream=partial.outputStream()
        download.start(value,kind,object:S11Download.Sink {
            private var closed=false
            private fun close(){if(!closed){stream.close();closed=true}}
            override fun write(bytes:ByteArray){stream.write(bytes)}
            override fun finish(){stream.flush();stream.fd.sync();close();require(!target.exists()||target.delete());require(partial.renameTo(target));downloaded=target}
            override fun abort(){close();partial.delete()}
        })
    }
    @Deprecated("Native Activity result callback")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==11 && resultCode==RESULT_OK) {
            val uri=data?.data?:return;val value=downloaded?:return
            Thread {
                try {contentResolver.openOutputStream(uri).use {out->requireNotNull(out);value.inputStream().use {it.copyTo(out)}};handler.post {feedback.text="已保存下载文件到所选位置"}}
                catch(e:Exception){handler.post {feedback.text="文件导出失败：${e.message}"}}
            }.start();return
        }
        if(requestCode!=10||resultCode!=RESULT_OK)return
        val uri=data?.data?:return;preparing=true;val token=++prepareGeneration
        feedback.text="正在复制并校验本地文件；返回后需重新连接设备"
        Thread {
            val candidate=File.createTempFile("score-",".evt",cacheDir)
            try {
                var total=0;val crc=CRC32()
                contentResolver.openInputStream(uri).use {source->
                    requireNotNull(source)
                    candidate.outputStream().use {out->
                        val buffer=ByteArray(8192)
                        while(true){val n=source.read(buffer);if(n<0)break;if(n==0)continue;total+=n;require(total<=S9Constants.MAX_SCORE_BYTES);out.write(buffer,0,n);crc.update(buffer,0,n)}
                    }
                }
                require(total>=1024&&total%512==0)
                handler.post {
                    preparing=false
                    if(destroyed||token!=prepareGeneration)candidate.delete()
                    else {prepared?.delete();prepared=candidate;preparedCrc=crc.value;feedback.text="本地已准备$total 字节；尚未上传到SD";if(page==4)showPage(4)}
                }
            }catch(e:Exception){candidate.delete();handler.post {preparing=false;if(!destroyed)feedback.text="曲谱准备失败：${e.message}"}}
        }.start()
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==9) {if(grantResults.isNotEmpty()&&grantResults.all {it==PackageManager.PERMISSION_GRANTED})link.scan() else status("未授予蓝牙权限，无法扫描")}
    }
    override fun mediaStatus(info:S10MediaInfo?){
        if(::mediaState.isInitialized)mediaState.text=info?.description()?:"设备尚未提供伴奏数字状态"
    }
    override fun status(text:String){if(::state.isInitialized)state.text=text}
    override fun discovered(device:BluetoothDevice,displayName:String){devices?.addView(Button(this).apply {text=displayName;setOnClickListener{link.connect(device)}})}
    override fun ready(session:ByteArray){
        recording=null;voiceInfo=null;ensembleInfo=null;client.ready(session)
        if(requestedRecording!=0L)client.fileCommand(S11Protocol.STATUS,S11Protocol.id(requestedRecording),"读取上次录音状态",3)
        client.parameter(1,byteArrayOf(),"读取设备参数快照",3)
        client.parameter(106,byteArrayOf(),"读取合奏状态",3);client.parameter(101,byteArrayOf(),"查询循环",3);status("已连接")
        if(::overlay.isInitialized&&overlay.visibility==View.VISIBLE&&page==0)closePage() else refreshStage()
    }
    override fun result(message:S9Message){
        when(message.opcode) {
            132 -> if(client.ownsSession(message))try{ensembleInfo=EnsembleInfo.decode(message.payload);ensembleText?.text=ensembleDescription()}catch(_:IllegalArgumentException){feedback.text="合奏状态格式不正确"}
            131 -> if(client.ownsSession(message))try{loopDescription=EnsembleProtocol.loopDescription(message.payload);loopText?.text=loopDescription
                val p=message.payload;if(p.size==64){loopState=p[1].toInt();loopLayers=p[2].toInt();refreshStage()}}catch(_:IllegalArgumentException){feedback.text="循环状态格式不正确"}
            133,134,135 -> if(client.ownsSession(message))reservedNotice(message)
            128 -> {
                if(client.ownsSession(message))try{val result=S9ExecutionResult.decode(message);result.voiceMetrics?.let{m->
                    voiceInfo=m;ensembleText?.text=ensembleDescription();fieldText?.text=voiceInfo?.description()
                    if(liveRate){
                        // The frame counter arrives with this result; pair it with a
                        // monotonic phone timestamp to get the real synthesis rate.
                        ratePending=false
                        rateReading=rateMeter.add(m.frame,SystemClock.elapsedRealtimeNanos())
                        refreshRateText()
                    }}}catch(_:IllegalArgumentException){}
                client.result(message)
            }
            S11Protocol.RECORD_INFO -> if(client.ownsSession(message))try {
                recording=S11RecordInfo.decode(message);
                recordingIds.observeRemote(recording!!.id)
                if(recording!!.id!=0L){requestedRecording=recording!!.id;getPreferences(MODE_PRIVATE).edit().putLong("lastRecordID",requestedRecording).apply()}
                feedback.text=recording!!.description()
                if(page==5 && !download.active)showPage(5)
            }catch(e:IllegalArgumentException){recording=null;if(page==5 && !download.active)showPage(5);feedback.text="记录状态不合法，未确认保存：${e.message}"}
            S11Protocol.DOWNLOAD_DATA -> download.data(message)
            else -> client.result(message)
        }
    }
    override fun disconnected(){
        fieldGeneration++;fieldRequested=false
        stopLiveRate()
        if(::mediaState.isInitialized)mediaState.text="设备尚未提供伴奏数字状态"
        if(::feedback.isInitialized)feedback.text="会话已结束，之前的就绪提示已失效"
if(::client.isInitialized){keyboard?.cancel();if(::piano.isInitialized)piano.cancel();noteSlots.clear();client.disconnected();upload.disconnected();if(::download.isInitialized)download.disconnected()}
        recordingOn=false;ensembleOn=false;scorePlaying=false;guideNote=null;physicalNotes=emptySet();loopState=0;loopLayers=0
        status("未连接");refreshStage()}
    override fun onPause(){stopLiveRate();super.onPause()}
    override fun onStart(){super.onStart();running=true;handler.post(ticker)}
    override fun onStop(){stopFieldTest();running=false;handler.removeCallbacks(ticker);keyboard?.cancel();client.releaseAll();link.stopScan();link.close();super.onStop()}
    override fun onDestroy(){destroyed=true;prepareGeneration++;link.close();prepared?.delete();super.onDestroy()}

    private inner class PianoView(down:(Int)->Boolean,up:(Int)->Unit):View(this@MainActivity) {
        private val paint=Paint(Paint.ANTI_ALIAS_FLAG)
        private val pressed=HashSet<Int>()
        private val touches=S9TouchKeys({key->down(key).also {if(it){pressed.add(key);invalidate()}}},{key->pressed.remove(key);up(key);invalidate()})
        fun cancel(){touches.cancel()}
        private fun key(x:Float,y:Float)=if(x<0||x>=width||y<0||y>=height)-1 else (x*8/width).toInt()+(if(y>=height/2)8 else 0)
        override fun onDraw(canvas:Canvas) {
            for(k in 0..15){val x=(k%8)*width/8f;val y=(k/8)*height/2f;paint.color=if(k in pressed)0xff8bc7fa.toInt() else Color.WHITE;canvas.drawRect(x+1,y+1,x+width/8f-1,y+height/2f-1,paint);paint.color=Color.BLACK;paint.textSize=28f;canvas.drawText(k.toString(),x+10,y+50,paint)}
        }
        override fun onTouchEvent(event:MotionEvent):Boolean {
            parent.requestDisallowInterceptTouchEvent(true)
            when(event.actionMasked) {
                MotionEvent.ACTION_DOWN,MotionEvent.ACTION_POINTER_DOWN->{val i=event.actionIndex;touches.press(event.getPointerId(i),key(event.getX(i),event.getY(i)))}
                MotionEvent.ACTION_MOVE->for(i in 0 until event.pointerCount)touches.move(event.getPointerId(i),key(event.getX(i),event.getY(i)))
                MotionEvent.ACTION_UP,MotionEvent.ACTION_POINTER_UP->touches.release(event.getPointerId(event.actionIndex))
                MotionEvent.ACTION_CANCEL->cancel()
            };return true
        }
        override fun performClick():Boolean {super.performClick();return true}
    }
}
