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
import android.text.InputType
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
    private var prepared:File?=null
    private var preparedCrc=0L
    private var preparing=false
    private var destroyed=false
    private var prepareGeneration=0
    private val ticker=object:Runnable {
        override fun run(){if(running){client.tick();if(::download.isInitialized)download.tick();if((page==7||page==8)&&client.connected&&client.pendingCount<2&&SystemClock.elapsedRealtime()-lastVoicePoll>=1000){lastVoicePoll=SystemClock.elapsedRealtime();client.parameter(41,byteArrayOf(),"读取硬件声部",3)};handler.postDelayed(this,100)}}
    }
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        requestedRecording=getPreferences(MODE_PRIVATE).getLong("lastRecordID",0L)
        if(requestedRecording!=0L)recordingIds.observeRemote(requestedRecording)
        link=BleInstrumentLink(this,this)
        client=S9ClientSession(link::send,{reason->link.close();status(reason)},{feedback.text=it},SystemClock::elapsedRealtime)
        upload=S9ScoreUpload(client,{feedback.text=it})
        download=S11Download(client,{feedback.text=it},SystemClock::elapsedRealtime)
        val column=LinearLayout(this).apply {orientation=1;setPadding(20,48,20,24)}
        column.addView(TextView(this).apply {text="FPGA 乐器控制";textSize=25f})
        state=TextView(this).apply {text="未连接";textSize=16f};column.addView(state)
        mediaState=TextView(this).apply {text="设备尚未提供伴奏数字状态";textSize=14f};column.addView(mediaState)
        feedback=TextView(this).apply {text="参数为易失配置；无线与实卡尚需实机验证";textSize=14f};column.addView(feedback)
        val nav=Spinner(this).apply {
            adapter=ArrayAdapter(this@MainActivity,android.R.layout.simple_spinner_dropdown_item,listOf("连接与设备","琴键演奏","音色与效果","键位映射","曲谱播放","录音文件","实时循环","智能合奏","赛题测试（48路）"))
            onItemSelectedListener=object:AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent:AdapterView<*>?,view:View?,position:Int,id:Long){if(::body.isInitialized)showPage(position)}
                override fun onNothingSelected(parent:AdapterView<*>?){}
            }
        };column.addView(nav)
        body=LinearLayout(this).apply {orientation=1}
        column.addView(ScrollView(this).apply {addView(body)},LinearLayout.LayoutParams(-1,0,1f))
        setContentView(column);showPage(0)
    }
    private fun label(text:String){body.addView(TextView(this).apply {this.text=text;textSize=16f})}
    private fun button(text:String,action:()->Unit) {body.addView(Button(this).apply {this.text=text;setOnClickListener {guard(action)}})}
    private fun guard(action:()->Unit) {try {action()}catch(e:IllegalArgumentException){feedback.text="参数不合法：${e.message?:"请检查数值范围"}"}catch(e:java.io.IOException){feedback.text="文件读取失败：${e.message}"}}
    private fun number(title:String,value:Int):EditText {
        label(title);return EditText(this).apply {inputType=InputType.TYPE_CLASS_NUMBER;setText(value.toString());body.addView(this)}
    }
    private fun checked(text:String,initial:Boolean=false)=CheckBox(this).apply {this.text=text;isChecked=initial;body.addView(this)}
    private fun showPage(index:Int) {
        if(page==8 && index!=8)stopFieldTest()
        keyboard?.cancel();client.releaseAll();keyboard=null;devices=null
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
        button("刷新实际硬件统计"){client.parameter(41,byteArrayOf(),"读取测试硬件声部",3)}
        label("下列是短测试，约10.7ms后结束；48路测试30秒后自动结束。需要配套R87固件，旧固件会拒绝48路。断链后原生测试最迟30秒结束。")
        listOf(1,8,16,32).forEach {n->button("原生短测试 $n 路"){startFieldTest(n)}}
        label("预期基频（不是实测频谱）：")
        (48..95).forEach {note->label("MIDI $note · ${String.format(java.util.Locale.US,"%.2f",440.0*Math.pow(2.0,(note-69)/12.0))} Hz")}
        label("请求48路不等于已验证48个谱峰。请采集真实音频检查独立基频；容量、占槽、非零贡献快照和每帧完成数分别判断，谐波和噪声不计额外振荡器。评分使用实际音频输出采样率，不能使用48kHz录音率代替128kHz输出率。")
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
        client.parameter(106,byteArrayOf(),"读取合奏状态",3);status("设备会话已就绪；正在查询参数快照")
    }
    override fun result(message:S9Message){
        when(message.opcode) {
            132 -> if(client.ownsSession(message))try{ensembleInfo=EnsembleInfo.decode(message.payload);ensembleText?.text=ensembleDescription()}catch(_:IllegalArgumentException){feedback.text="合奏状态格式不正确"}
            131 -> if(client.ownsSession(message))try{loopDescription=EnsembleProtocol.loopDescription(message.payload);loopText?.text=loopDescription}catch(_:IllegalArgumentException){feedback.text="循环状态格式不正确"}
            128 -> {
                if(client.ownsSession(message))try{val result=S9ExecutionResult.decode(message);if(result.voiceMetrics!=null){voiceInfo=result.voiceMetrics;ensembleText?.text=ensembleDescription();fieldText?.text=voiceInfo?.description()}}catch(_:IllegalArgumentException){}
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
        if(::mediaState.isInitialized)mediaState.text="设备尚未提供伴奏数字状态"
        if(::feedback.isInitialized)feedback.text="会话已结束，之前的就绪提示已失效"
if(::client.isInitialized){keyboard?.cancel();client.disconnected();upload.disconnected();if(::download.isInitialized)download.disconnected()};status("会话已结束")}
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
