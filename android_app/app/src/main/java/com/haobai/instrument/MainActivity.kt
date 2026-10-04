package com.haobai.instrument

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.bluetooth.BluetoothDevice
import android.content.Intent
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
    private var prepared:File?=null
    private var preparedCrc=0L
    private var preparing=false
    private var destroyed=false
    private var prepareGeneration=0
    private val ticker=object:Runnable {
        override fun run(){if(running){client.tick();if(::download.isInitialized)download.tick();handler.postDelayed(this,100)}}
    }
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        link=BleInstrumentLink(this,this)
        client=S9ClientSession(link::send,{reason->link.close();status(reason)},{feedback.text=it},SystemClock::elapsedRealtime)
        upload=S9ScoreUpload(client,{feedback.text=it})
        download=S11Download(client,{feedback.text=it},SystemClock::elapsedRealtime)
        val column=LinearLayout(this).apply {orientation=1;setPadding(20,48,20,24)}
        column.addView(TextView(this).apply {text="FPGA 乐器控制";textSize=25f})
        state=TextView(this).apply {text="未连接";textSize=16f};column.addView(state)
        mediaState=TextView(this).apply {text="设备尚未提供伴奏数字状态";textSize=14f};column.addView(mediaState)
        feedback=TextView(this).apply {text="参数为易失配置；无线与实卡尚需实机验证";textSize=14f};column.addView(feedback)
        val nav=LinearLayout(this)
        listOf("连接","演奏","参数","键位","曲谱","记录").forEachIndexed {i,title ->
            nav.addView(Button(this).apply {text=title;textSize=12f;setPadding(0,0,0,0);setOnClickListener {showPage(i)}},LinearLayout.LayoutParams(0,-2,1f))
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
        keyboard?.cancel();client.releaseAll();keyboard=null;devices=null
        body.removeAllViews();page=index
        when(index){0->connectionPage();1->performancePage();2->parameterPage();3->mappingPage();4->scorePage();5->recordingPage()}
    }
    private fun connectionPage() {
        button("扫描乐器") {
            val permissions=link.missingPermissions()
            if(permissions.isEmpty()){devices?.removeAllViews();link.scan()} else requestPermissions(permissions,9)
        }
        button("断开并清理手机持音"){client.releaseAll();link.close()}
        button("刷新设备状态"){link.requestInfo()}
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
        val timbre=number("音色 ID（0基准；1～4实时音色）",0)
        button("设置新实例音色"){client.pitchParameter(32,timbre.text.toString().toInt())}
        val glide=number("Glide 编码（0～11）",0)
        button("设置Glide"){client.pitchParameter(33,glide.text.toString().toInt())}
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
        val event=checked("完整演奏事件记录",true)
        val pcm=checked("最终立体声PCM录音",true)
        label("先准备SD文件后开始；伴奏运行时的最终回读校验可能等待。录制与下载/上传互斥。")
        button("开始记录") {
            require(!download.active && !upload.active)
            val mask=(if(pcm.isChecked)1 else 0) or (if(event.isChecked)2 else 0)
            require(mask!=0)
            if(recording==null) {
                client.fileCommand(S11Protocol.STATUS,S11Protocol.id(0),"读取记录身份",3)
                feedback.text="先取得设备记录身份，再开始新记录"
                return@button
            }
            val id=recordingIds.next()
            if(client.fileCommand(S11Protocol.START,S11Protocol.start(id,mask),"请求开始记录",3)!=null) {
                requestedRecording=id;feedback.text="开始请求已排队，等待设备实际采集状态"
            }
        }
        button("停止并排空记录") {
            val id=recording?.id?.takeIf{it!=0L}?:requestedRecording
            require(id!=0L)
            client.fileCommand(S11Protocol.STOP,S11Protocol.id(id),"请求停止记录",3)
        }
        button("查询实际记录/保存状态") {client.fileCommand(S11Protocol.STATUS,S11Protocol.id(0),"查询记录状态",3)}
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
        label("独立现场测试：不依赖SD，与AUTO/TEACH互斥；声部各自运行。")
        listOf(1,8,16,32).forEach {n->button("现场测试 $n Voice") {client.parameter(S11Protocol.FIELD_TEST,S11Protocol.field(n),"现场测试 $n Voice",3)}}
        button("停止现场测试") {client.parameter(S11Protocol.FIELD_TEST,S11Protocol.field(0),"停止现场测试",3)}
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
    override fun ready(session:ByteArray){recording=null;client.ready(session);client.fileCommand(S11Protocol.STATUS,S11Protocol.id(0),"读取记录身份",3);client.parameter(1,byteArrayOf(),"读取设备参数快照",3);status("设备会话已就绪；正在查询参数快照")}
    override fun result(message:S9Message){
        when(message.opcode) {
            S11Protocol.RECORD_INFO -> if(client.ownsSession(message))try {
                recording=S11RecordInfo.decode(message);
                recordingIds.observeRemote(recording!!.id)
                feedback.text=recording!!.description()
                if(page==5 && !download.active)showPage(5)
            }catch(e:IllegalArgumentException){feedback.text="记录状态不合法，未确认保存"}
            S11Protocol.DOWNLOAD_DATA -> download.data(message)
            else -> client.result(message)
        }
    }
    override fun disconnected(){
        if(::mediaState.isInitialized)mediaState.text="设备尚未提供伴奏数字状态"
if(::client.isInitialized){keyboard?.cancel();client.disconnected();upload.disconnected();if(::download.isInitialized)download.disconnected()};status("会话已结束")}
    override fun onStart(){super.onStart();running=true;handler.post(ticker)}
    override fun onStop(){running=false;handler.removeCallbacks(ticker);keyboard?.cancel();client.releaseAll();link.stopScan();link.close();super.onStop()}
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
