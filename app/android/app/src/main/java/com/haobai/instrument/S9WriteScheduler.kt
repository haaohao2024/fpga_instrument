package com.haobai.instrument

/** The real GATT write queue. Channels stay ordered; FILE cannot monopolize the link. */
class S9WriteScheduler {
    data class Fragment(val channel:Int,val bytes:ByteArray)
    private val queues=List(3){ArrayDeque<Fragment>()}
    private val rotation=intArrayOf(0,0,1,2)
    private var cursor=0
    private var active:Fragment?=null
    private var activeSince=0L
    val size:Int get()=queues.sumOf{it.size}+(if(active!=null) 1 else 0)

    fun enqueue(message:S9Message,mtu:Int):Boolean {
        require(message.channel in 0..2)
        val frames=S9Protocol.fragments(message,mtu)
        val own=queues[message.channel].size+(if(active?.channel==message.channel) 1 else 0)
        if(size+frames.size>96 || (message.channel==2 && own+frames.size>64)) return false
        frames.forEach {queues[message.channel].addLast(Fragment(message.channel,it))}
        return true
    }
    fun next(nowMs:Long):Fragment? {
        active?.let {
            check(nowMs-activeSince<3000) {"GATT write stalled"}
            return it
        }
        repeat(rotation.size) {
            val channel=rotation[cursor];cursor=(cursor+1)%rotation.size
            if(queues[channel].isNotEmpty()) {
                val next=queues[channel].removeFirst();active=next;activeSince=nowMs;return next
            }
        }
        return null
    }
    fun acknowledged() {check(active!=null);active=null}
    fun clear() {queues.forEach{it.clear()};active=null;cursor=0;activeSince=0}
}
