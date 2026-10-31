package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

/** Non-reusable recording identity; device state advances a restarted client. */
class S11RecordingIds(initial:Long) {
    private var last=if(initial==0L)1L else initial
    fun observeRemote(id:Long) {if(java.lang.Long.compareUnsigned(id,last)>0)last=id}
    fun next():Long {require(last!=-1L) {"记录身份已耗尽"};last+=1;return last}
}

/** Stage11 wire contract, independent of Android widgets and transport. */
object S11Protocol {
    const val START=80; const val STOP=81; const val STATUS=82
    const val DOWNLOAD=83; const val CANCEL=84; const val EXPORT=85
    const val FIELD_TEST=86; const val DOWNLOAD_DATA=129; const val RECORD_INFO=130
    const val PCM=1; const val EVENT=2
    fun id(value:Long)=ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array()
    fun start(id:Long,mask:Int):ByteArray {
        require(id!=0L && mask in 1..3)
        return ByteArray(16).also {ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putLong(id).put(mask.toByte())}
    }
    fun download(id:Long,offset:Long,length:Int,kind:Int):ByteArray {
        require(id!=0L && offset>=0 && length in 1..480 && kind in 1..2)
        return ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
            .putLong(id).putLong(offset).putShort(length.toShort()).put(kind.toByte()).put(0).array()
    }
    fun field(voices:Int):ByteArray {
        require(voices in listOf(0,1,8,16,32,48,64))
        return ByteArray(8).also {it[0]=(if(voices==0)2 else 1).toByte();it[1]=voices.toByte()}
    }
    fun requestError(m:S9Message):Int? {
        if(m.channel!=2 && !(m.channel==1 && m.opcode==FIELD_TEST))return null
        val p=m.payload;val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN)
        fun zero(a:Int)=p.drop(a).all {it==0.toByte()}
        fun ok(value:Boolean)=if(value)0 else -4
        return when(m.opcode) {
            START -> ok(m.channel==2 && p.size==16 && b.getLong(0)!=0L && (p[8].toInt() and 255) in 1..3 && zero(9))
            STOP,CANCEL,EXPORT -> ok(m.channel==2 && p.size==8 && b.getLong(0)!=0L)
            STATUS -> ok(m.channel==2 && p.size==8)
            DOWNLOAD -> ok(m.channel==2 && p.size==20 && b.getLong(0)!=0L && b.getLong(8)>=0 &&
                (b.getShort(16).toInt() and 65535) in 1..480 && (p[18].toInt() and 255) in 1..2 && p[19]==0.toByte())
            FIELD_TEST -> ok(m.channel==1 && p.size==8 && zero(2) &&
                ((p[0]==1.toByte() && (p[1].toInt() and 255) in listOf(1,8,16,32,48,64)) || (p[0]==2.toByte() && p[1]==0.toByte())))
            else -> null
        }
    }
}

data class S11RecordInfo(val id:Long,val phase:Int,val wireState:Int,val mask:Int,val flags:Int,
    val error:Long,val pcmPairs:Long,val eventCells:Long,val pcmBytes:Long,val eventBytes:Long,
    val pcmCrc:Long,val eventCrc:Long,val firstFrame:Long,val lastFrame:Long) {
    fun downloadable(kind:Int)=phase==5 && flags and 4==0 && mask and kind!=0 && flags and kind!=0
    fun bytes(kind:Int)=if(kind==1)pcmBytes else eventBytes
    fun crc(kind:Int)=if(kind==1)pcmCrc else eventCrc
    val pcmChannels:Int? get()=if(flags and 1==0 || pcmPairs==0L)null else if(pcmBytes==512+2*pcmPairs)1 else 2
    fun description():String {
        val names=listOf("空闲","正在采集","正在排空","已关闭","等待停止伴奏后回读校验","已验证保存","不完整","错误")
        val format=when(pcmChannels){1->"（单声道）";2->"（双声道）";else->""}
        return "记录 $id：${names[phase]}；PCM $pcmPairs 帧$format，事件 $eventCells 单元；错误 $error"
    }
    companion object {
        fun decode(m:S9Message):S11RecordInfo {
            require(m.channel==3 && m.opcode==S11Protocol.RECORD_INFO && m.payload.size==72)
            val b=ByteBuffer.wrap(m.payload).order(ByteOrder.LITTLE_ENDIAN)
            val id=b.long;val phase=b.get().toInt() and 255;val wire=b.get().toInt() and 255
            val mask=b.get().toInt() and 255;val flags=b.get().toInt() and 255
            require(phase in 0..7 && wire in 0..6 && mask in 0..3 && flags and 248==0)
            val error=b.int.toLong()
            val pairs=b.long;val cells=b.long;val pcm=b.long;val event=b.long
            val pc=b.int.toLong() and 0xffffffffL;val ec=b.int.toLong() and 0xffffffffL
            val first=b.long;val last=b.long
            require(pairs>=0 && cells>=0 && pcm>=0 && event>=0 && pcm<=1073742336L)
            require(event<=0xffffffffL && ((flags and 3) and mask.inv())==0)
            if(phase==5)require(error==0L && flags and 4==0)
            if(flags and 3!=0)require(phase==5 && flags and 4==0)
            // Current firmware writes one Int16 per FPGA stereo pair;
            // legacy WAVs write two. Keep both without changing the protocol.
            if(flags and 1!=0)require(pairs<=536870912L &&
                (pcm==512+2*pairs || pcm==512+4*pairs)) {"WAV长度不符"}
            return S11RecordInfo(id,phase,wire,mask,flags,error,pairs,cells,pcm,event,pc,ec,first,last)
        }
    }
}

/** Sequential immutable-file reader. Duplicate data is checked and never
 * appended twice. Device execution ACK is independent of file data arrival. */
class S11Download(private val client:S9ClientSession,private val show:(String)->Unit,
    private val clock:()->Long) {
    interface Sink { fun write(bytes:ByteArray); fun finish(); fun abort() }
    private var sink:Sink?=null
    private var info:S11RecordInfo?=null
    private var kind=0
    private var position=0L
    private var generation=0L
    private var commandDone=false
    private var gotData=false
    private var pendingOffset=0L
    private var pendingCount=0
    private var lastData:ByteArray?=null
    private var lastOffset=-1L
    private var requestedAt=0L
    private var issued=false
    private var attempts=0
    private var cancelId=0L
    private val crc=CRC32()
    val active:Boolean get()=sink!=null
    val received:Long get()=position
    fun start(value:S11RecordInfo,fileKind:Int,destination:Sink):Boolean {
        if(active || !client.connected || !value.downloadable(fileKind)){destination.abort();return false}
        require(fileKind in 1..2 && value.id!=0L && value.bytes(fileKind)>0)
        generation++;info=value;kind=fileKind;sink=destination;position=0;crc.reset()
        lastData=null;lastOffset=-1;attempts=0;cancelId=0
        show("正在接收已验证文件，尚未核对完整摘要")
        request();return true
    }
    private fun request() {
        val value=info?:return
        val token=generation
        pendingOffset=position;pendingCount=minOf(480L,value.bytes(kind)-position).toInt()
        gotData=false;commandDone=false;requestedAt=clock();attempts++
        issued=false
        val ticket=client.fileCommand(S11Protocol.DOWNLOAD,S11Protocol.download(value.id,position,pendingCount,kind),"下载文件块 $position",3,
            rejected={if(token==generation && active)fail("设备拒绝文件下载：${it.error}")},
            completed={if(token==generation && active){commandDone=true;advance()}})
        issued=ticket!=null
        if(ticket==null){attempts--;show("等待文件通道空闲")}
    }
    fun data(message:S9Message) {
        if(!active || !client.ownsSession(message))return
        val value=info?:return
        try {
            require(message.channel==3 && message.opcode==S11Protocol.DOWNLOAD_DATA && message.payload.size in 33..512)
            val b=ByteBuffer.wrap(message.payload).order(ByteOrder.LITTLE_ENDIAN)
            val id=b.long;val offset=b.long;val total=b.long;val expected=b.int.toLong() and 0xffffffffL
            val fileKind=b.get().toInt() and 255;val flags=b.get().toInt() and 255;val reserved=b.short
            if(id!=value.id || fileKind!=kind)return
            require(total==value.bytes(kind) && offset>=0 && reserved==0.toShort() && flags and 254==0)
            val bytes=message.payload.copyOfRange(32,message.payload.size)
            require(S9Protocol.crc(bytes)==expected)
            if(offset==lastOffset){require(lastData!!.contentEquals(bytes));return}
            require(offset==pendingOffset && bytes.size==pendingCount && offset+bytes.size<=total && !gotData)
            sink!!.write(bytes);crc.update(bytes);position+=bytes.size;gotData=true
            lastOffset=offset;lastData=bytes;advance()
        }catch(e:Exception){fail("下载校验或写入失败：${e.message}")}
    }
    private fun advance() {
        val value=info?:return
        if(!active || !gotData || !commandDone)return
        if(position==value.bytes(kind)) {
            if(crc.value!=value.crc(kind)){fail("完整文件CRC不符，未公布文件");return}
            val destination=sink!!;sink=null;info=null;generation++
            try {destination.finish();show("文件下载完成，长度及完整CRC已核对")}
            catch(e:Exception){destination.abort();show("下载文件发布失败：${e.message}")}
        }else {attempts=0;request()}
    }
    private fun fail(reason:String) {cancel();show(reason)}
    fun cancel() {
        val value=info;generation++;sink?.abort();sink=null;info=null;lastData=null
        if(value!=null && client.connected)cancelId=value.id
        tick()
    }
    fun disconnected() {cancelId=0;generation++;sink?.abort();sink=null;info=null;lastData=null}
    fun tick() {
        if(cancelId!=0L && client.connected) {
            if(client.fileCommand(S11Protocol.CANCEL,S11Protocol.id(cancelId),"取消文件下载",3)!=null)cancelId=0
        }
        if(!active)return
        if(!client.connected){disconnected();return}
        if(!issued){request();return}
        if(!gotData && commandDone && clock()-requestedAt>=10000) {
            if(attempts>=4)fail("文件数据超时，保留失败状态") else request()
        }
    }
}
