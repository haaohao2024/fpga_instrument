package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Actual client command/gesture state, independent of Android widgets for tests.
 * Four outstanding commands leave cache headroom. Reserved OFF capacity is
 * included in every admission check. No successful GATT send is an execution ACK.
 */
class S9ClientSession(
    private val send:(S9Message)->Boolean,
    private val terminate:(String)->Unit,
    private val show:(String)->Unit,
    private val clock:()->Long
) {
    data class Gesture(val press:Long,var note:Int,var pressure:Int)
    data class Ticket(val channel:Int,val sequence:Long)
    private data class Pending(val message:S9Message,val label:String,val target:Int,
                               val created:Long,var phase:Int=0,var lastSent:Long=0,var attempts:Int=0,var progress:Long=0,
                               val completed:((S9ExecutionResult)->Unit)?=null,
                               val rejected:((S9ExecutionResult)->Unit)?=null)
    private var session:ByteArray?=null
    private val sequence=LongArray(3){1}
    private var nextPress=1L
    private val queues=List(3){ArrayDeque<Pending>()}
    private val inflight=LinkedHashMap<Ticket,Pending>()
    private val hands=LinkedHashMap<Int,Gesture>()
    private val pitchBarriers=HashSet<Ticket>()
    private var cursor=0
    private var lastApplicationSend=0L
    val connected:Boolean get()=session!=null
    val heldKeys:Set<Int> get()=hands.keys.toSet()
    val pendingCount:Int get()=inflight.size+queues.sumOf{it.size}
    val pitchReady:Boolean get()=pitchBarriers.isEmpty()
    fun ownsSession(message:S9Message)=session?.contentEquals(message.session)==true

    fun ready(identity:ByteArray) {
        require(identity.size==16)
        disconnected();session=identity.clone();lastApplicationSend=clock();show("会话已就绪；参数与曲谱需等待设备反馈")
    }
    fun disconnected() {
        session=null;hands.clear();queues.forEach{it.clear()};inflight.clear();pitchBarriers.clear()
        sequence.fill(1);nextPress=1;cursor=0
    }
    private fun fail(reason:String) {disconnected();terminate(reason)}
    private fun canReserve(messages:Int,newHands:Int=0)=connected&&pendingCount+messages+hands.size+newHands<=96
    private fun enqueue(channel:Int,opcode:Int,payload:ByteArray,label:String,target:Int,
                        completed:((S9ExecutionResult)->Unit)?=null,
                        rejected:((S9ExecutionResult)->Unit)?=null):Ticket? {
        val sid=session?:return null
        if(!canReserve(1)){show("发送队列繁忙，未提交：$label");return null}
        val seq=sequence[channel]
        if(seq>0xffffffffL){fail("命令编号耗尽，请重新连接");return null}
        val message=S9Message(channel,opcode,sid.clone(),seq,payload.clone())
        require(S9RequestRules.error(message)==0)
        sequence[channel]++
        queues[channel].addLast(Pending(message,label,target,clock(),completed=completed,rejected=rejected))
        return Ticket(channel,seq)
    }
    fun press(key:Int,note:Int,pressure:Int):Boolean {
        require(key in 0..31&&note in 0..127&&pressure in 1..255)
        if(!pitchReady){show("音色/Glide屏障未完成，本次按下未提交");return false}
        if(key in hands||!canReserve(1,1))return false
        if(nextPress==Long.MAX_VALUE){fail("按键身份编号耗尽，请重新连接");return false}
        val id=nextPress++
        if(enqueue(0,16,S9Protocol.event(id,1,key,note,pressure),"按下 $key",3)==null)return false
        hands[key]=Gesture(id,note,pressure);pump();return true
    }
    fun release(key:Int) {
        val held=hands.remove(key)?:return
        if(!connected)return
        if(enqueue(0,16,S9Protocol.event(held.press,2,key,0,0),"释放 $key",3)==null){fail("释放队列异常，断开会话以清理持音");return}
        pump()
    }
    fun releaseAll() {hands.keys.toList().forEach(::release)}
    fun expression(key:Int,note:Int,pressure:Int):Boolean {
        require(note in 0..127&&pressure in 0..255)
        val held=hands[key]?:return false
        if(!pitchReady)return false
        if(enqueue(0,16,S9Protocol.event(held.press,3,key,note,pressure),"表情 $key",3)==null)return false
        held.note=note;held.pressure=pressure;pump();return true
    }
    fun vibrato(depth:Int):Boolean {
        require(depth in 0..255)
        val ok=enqueue(0,16,S9Protocol.event(0,4,255,0,depth),"颤音",3)!=null;pump();return ok
    }
    fun parameter(opcode:Int,payload:ByteArray,label:String,target:Int=4,
                  rejected:((S9ExecutionResult)->Unit)?=null,
                  completed:((S9ExecutionResult)->Unit)?=null):Ticket? {
        val ticket=enqueue(1,opcode,payload,label,target,completed,rejected);pump();return ticket
    }
    fun pitchParameter(opcode:Int,value:Int):Boolean {
        require(opcode==32||opcode==33)
        require(if(opcode==32)value in 0..4 else value in 0..S9Constants.MAX_GLIDE)
        if(!canReserve(2))return false
        val target=if(opcode==32)3 else 4
        val config=enqueue(1,opcode,byteArrayOf(value.toByte()),if(opcode==32)"音色" else "Glide",target)?:return false
        val payload=ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put(1).put(target.toByte()).putShort(0).putInt(config.sequence.toInt()).array()
        val barrier=enqueue(1,40,payload,"音高配置屏障",3)?:run {fail("配置屏障无法排队");return false}
        pitchBarriers.add(barrier);pump();return true
    }
    fun pan(key:Int,position:Int):Boolean {
        require(position in 0..256)
        val gesture=hands[key]?:return false
        val payload=ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN).put(key.toByte()).putLong(gesture.press).array()
        return parameter(39,payload,"查询琴键 $key 实例",3) {result ->
            val id=result.instanceId
            if(id==null){show("实例已失效，Pan未提交")}
            else {
                val data=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putLong(id).putShort(result.generation.toShort()).putShort(position.toShort()).putInt(0).array()
                parameter(34,data,"琴键 $key Pan",4)
            }
        }!=null
    }
    fun fileCommand(opcode:Int,payload:ByteArray,label:String,target:Int=3,
                    rejected:((S9ExecutionResult)->Unit)?=null,
                    completed:((S9ExecutionResult)->Unit)?=null):Ticket? {
        if(queues[2].isNotEmpty()||inflight.keys.any{it.channel==2})return null
        val t=enqueue(2,opcode,payload,label,target,completed,rejected);pump();return t
    }
    fun result(message:S9Message) {
        if(session?.contentEquals(message.session)!=true)return
        val result=try {S9ExecutionResult.decode(message)}catch(_:IllegalArgumentException){show("执行反馈不合法，等待重试查询");return}
        val ticket=Ticket(result.channel,result.sequence)
        val p=inflight[ticket]?:return
        if(result.phase<p.phase)return
        // Duplicate receipt notifications are not progress and cannot renew a lease.
        if(result.phase>p.phase)p.lastSent=clock()
        // Only advancing file-check progress extends the inactivity timeout.
        // Repeated RECEIVED/ACCEPTED and an unchanged byte count do not.
        if(p.message.opcode==66 && result.phase==2 && result.diagnostic>p.progress) {
            p.progress=result.diagnostic;p.lastSent=clock();p.attempts=1
        }
        p.phase=result.phase;show("${p.label}：${result.description}")
        if(result.phase==6||result.phase==7) {
            inflight.remove(ticket)
            p.rejected?.invoke(result)
            if(p.message.channel==0) {fail("演奏命令被拒绝/取消，结束会话以核对并清理手机持音");return}
            if(ticket in pitchBarriers||p.message.opcode in listOf(32,33)) {fail("音高配置未确认，请重新连接后重设");return}
        } else if(result.phase>=p.target) {
            inflight.remove(ticket);pitchBarriers.remove(ticket);p.completed?.invoke(result)
        }
        pump()
    }
    fun tick() {
        val now=clock()
        // This also bounds an unsent OFF behind a blocked transport.
        val oldest=(inflight.values.toList()+queues.flatMap{it}).firstOrNull {
            now-it.created>=if(it.message.opcode==66)2400000L else if(it.message.channel==2)60000L else 12000L
        }
        if(oldest!=null){fail("${oldest.label}等待超时，结束会话清理手机持音");return}
        for(p in inflight.values.toList()) {
            val timeout=if(p.message.channel==2)10000 else 2000
            if(now-p.lastSent>=timeout) {
                if(p.attempts>=4){fail("执行反馈超时，会话已断开以清理持音");return}
                if(send(p.message)){p.attempts++;p.lastSent=now}
                else if(now-p.lastSent>=timeout*2){fail("发送持续阻塞，会话已断开");return}
            }
        }
        if(connected && now-lastApplicationSend>=S9Constants.KEEPALIVE_MS &&
            inflight.values.none{it.message.opcode==2} && queues[1].none{it.message.opcode==2}) {
            enqueue(1,2,byteArrayOf(),"会话保活",3)
        }
        pump()
    }
    private fun pump() {
        if(!connected)return
        while(inflight.size<4) {
            var selected=-1
            for(offset in 0..2)if(queues[(cursor+offset)%3].isNotEmpty()){selected=(cursor+offset)%3;break}
            if(selected<0)return
            val p=queues[selected].first()
            if(!send(p.message))return
            lastApplicationSend=clock()
            queues[selected].removeFirst();cursor=(selected+1)%3;p.lastSent=clock();p.attempts=1
            inflight[Ticket(p.message.channel,p.message.sequence)]=p
        }
    }
}
