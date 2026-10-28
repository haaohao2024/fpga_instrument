package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Receiver for server STATUS notifications only. Lost messages are counted, never applied. */
class S9NotificationAssembler {
    private val bytes = ByteArray(S9Constants.MAX_MESSAGE)
    private var sequence = 0L
    private var used = 0
    private var started = 0L
    private var progressed = 0L
    var discarded = 0L
        private set

    fun reset() { sequence=0; used=0; started=0; progressed=0 }

    fun push(fragment: ByteArray, nowMs: Long): S9Message? {
        require(fragment.size >= 9)
        val b = ByteBuffer.wrap(fragment).order(ByteOrder.LITTLE_ENDIAN)
        val seq = b.int.toLong() and 0xffffffffL
        val offset = b.short.toInt() and 65535
        val count = b.short.toInt() and 65535
        require(seq != 0L && count > 0 && count + 8 == fragment.size && offset + count <= bytes.size)
        if (sequence != 0L && (nowMs-progressed >= 250 || nowMs-started >= 3000)) {
            discarded++; reset()
        }
        if (sequence != 0L && sequence != seq) {
            require(offset == 0)
            discarded++; reset()
        }
        if (sequence == 0L) {
            require(offset == 0)
            sequence=seq; started=nowMs; progressed=nowMs
        }
        require(offset <= used)
        if (offset < used) {
            require(offset + count <= used && bytes.copyOfRange(offset,offset+count).contentEquals(fragment.copyOfRange(8,fragment.size)))
        } else {
            fragment.copyInto(bytes,offset,8,fragment.size)
            used += count; progressed=nowMs
        }
        if (used < 32) return null
        val total = (ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getShort(28).toInt() and 65535) + 36
        require(total <= bytes.size && used <= total)
        if (used != total) return null
        val msg = S9Protocol.decode(bytes.copyOf(used))
        require(msg.channel == S9Constants.CH_STATUS && msg.opcode in listOf(S9Constants.OP_RESULT,S11Protocol.DOWNLOAD_DATA,S11Protocol.RECORD_INFO,131,132) && msg.sequence == sequence)
        reset()
        return msg
    }
}
