package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S9NotificationTest {
    private val sid=ByteArray(16).also {it[0]=1;it[8]=2}
    private fun message(seq:Long,phase:Int=1,flags:Int=0):S9Message {
        val p=ByteArray(36)
        ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(11).put(1).put(phase.toByte()).putShort(0)
            putInt(100).putInt(7).putLong(0).putShort(0).putShort(0).putInt(0).putInt(flags)
        }
        return S9Message(3,128,sid,seq,p)
    }
    @Test fun receiveDoesNotMeanEffective() {
        assertNull(S9ExecutionResult.decode(message(1)).effectiveFrame)
        try {S9ExecutionResult.decode(message(1,4));fail("Missing frame evidence accepted")}
        catch(_:IllegalArgumentException) {}
        assertEquals(100L,S9ExecutionResult.decode(message(1,4,1)).effectiveFrame)
    }
    @Test fun mtu23StatusAndLostFrameResynchronization() {
        val a=S9NotificationAssembler()
        val first=S9Protocol.fragments(message(1),23)
        assertNull(a.push(first.first(),0))
        val second=S9Protocol.fragments(message(2,4,1),23)
        var decoded:S9Message?=null
        second.forEachIndexed {i,f->decoded=a.push(f,(i+1)*20L)}
        assertEquals(1L,a.discarded)
        assertEquals(2L,decoded!!.sequence)
        assertEquals(100L,S9ExecutionResult.decode(decoded!!).effectiveFrame)
    }
    @Test fun gapAndTimeoutCannotProducePartialSuccess() {
        val a=S9NotificationAssembler();val f=S9Protocol.fragments(message(1),23)
        a.push(f[0],0)
        try {a.push(f[2],10);fail("Gap accepted")}catch(_:IllegalArgumentException) {}
        try {a.push(f[1],300);fail("Expired prefix accepted")}catch(_:IllegalArgumentException) {}
        assertEquals(1L,a.discarded)
    }
    @Test fun loopAndEnsembleNoticesReachTheClientAtBothMtuSizes() {
        for(op in listOf(131,132))for(mtu in listOf(23,247)) {
            val a=S9NotificationAssembler();val m=S9Message(3,op,sid,7,ByteArray(64).also{it[0]=1})
            var decoded:S9Message?=null
            S9Protocol.fragments(m,mtu).forEachIndexed {i,f->decoded=a.push(f,i*10L)}
            assertEquals(op,decoded!!.opcode);assertArrayEquals(m.payload,decoded!!.payload);assertEquals(0L,a.discarded)
        }
    }
}
