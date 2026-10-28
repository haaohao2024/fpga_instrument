package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** File transfer is acknowledgement-paced. Bytes are from a private immutable
 * local file, not the provider URI that could change midway through an upload. */
class S9ScoreUpload(private val client:S9ClientSession,private val show:(String)->Unit) {
    interface Source {val length:Int;val crc:Long;fun read(offset:Int,count:Int):ByteArray;fun close()}
    private var source:Source?=null
    private var generation=0L
    private var offset=0
    private var cancelling=false
    val active:Boolean get()=source!=null
    private fun data(size:Int)=ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
    fun start(file:Source):Boolean {
        if(active||!client.connected){file.close();return false}
        require(file.length in 1024..S9Constants.MAX_SCORE_BYTES&&file.length%512==0)
        source=file;offset=0;cancelling=false;val token=++generation
        show("等待曲谱STOP屏障；尚未写卡")
        val stop=byteArrayOf(3,0,0,0,0,0,0,0)
        if(client.parameter(38,stop,"上传前STOP",3,rejected={if(token==generation)fail("STOP被拒绝，未开始上传")}) {
            if(token==generation)begin(token)
        }==null) {fail("STOP无法排队，未开始上传");return false}
        return true
    }
    private fun begin(token:Long) {
        val f=source?:return
        if(cancelling){finish("上传已取消，未提交文件");return}
        val p=data(16).putInt(f.length).putInt(f.crc.toInt()).putLong(0).array()
        if(client.fileCommand(64,p,"开始曲谱暂存",rejected={if(token==generation)fail("设备拒绝上传")}) {
            if(token==generation)next(token)
        }==null)fail("上传通道繁忙，未开始保存")
    }
    private fun next(token:Long) {
        val f=source?:return
        if(cancelling) {sendCancel(token);return}
        if(offset==f.length) {
            show("等待设备同步、完整回读校验和替换；尚未标记已保存")
            if(client.fileCommand(66,byteArrayOf(),"校验并保存曲谱",4,rejected={if(token==generation)fail("曲谱保存失败")}) {r ->
                if(token==generation) {if(r.saved)finish("SCORE.EVT已由设备确认保存") else fail("缺少SAVED标志，不能确认保存")}
            }==null)fail("提交保存未能排队")
            return
        }
        val count=minOf(500,f.length-offset)
        val bytes=try {f.read(offset,count).also {require(it.size==count)}}catch(_:Exception){fail("本地文件读取失败");return}
        val p=data(12+count).putLong(offset.toLong()).putInt(S9Protocol.crc(bytes).toInt()).put(bytes).array()
        if(client.fileCommand(65,p,"曲谱块 $offset",rejected={if(token==generation)fail("曲谱块被拒绝")}) {
            if(token==generation) {offset+=count;show("设备已接收曲谱 $offset/${f.length} 字节；尚未确认保存");next(token)}
        }==null)fail("曲谱块无法排队")
    }
    fun cancel() {if(active){cancelling=true;show("已请求取消，等待当前文件操作结束")}}
    private fun sendCancel(token:Long) {
        if(client.fileCommand(67,byteArrayOf(),"取消上传",rejected={if(token==generation)finish("取消未确认；文件状态须重新查询")}) {
            if(token==generation)finish("上传已取消")
        }==null)finish("取消尚未发送，结束连接后由设备清理临时文件")
    }
    fun disconnected() {if(active)finish("连接中断，保存结果未确认；重新连接后核查文件")}
    private fun fail(message:String) {
        // A best-effort CANCEL only cleans this upload. Never claims storage rollback.
        client.fileCommand(67,byteArrayOf(),"失败后取消暂存")
        finish(message)
    }
    private fun finish(message:String) {generation++;source?.close();source=null;cancelling=false;show(message)}
}
