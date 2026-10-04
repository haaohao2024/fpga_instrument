package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S9ClientSessionTest {
    private class Fixture {
        var now=0L;var writable=true
        val sent=ArrayList<S9Message>();val failures=ArrayList<String>();val notices=ArrayList<String>()
        val sid=ByteArray(16){(it+1).toByte()}
        val client=S9ClientSession({if(writable){sent.add(it);true}else false},{failures.add(it)},{notices.add(it)},{now})
        init {client.ready(sid)}
        fun result(m:S9Message,phase:Int=3,error:Int=0,flags:Int=0):S9Message {
            val b=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
            b.putInt(m.sequence.toInt()).put(m.channel.toByte()).put(phase.toByte()).putShort(error.toShort())
            b.putInt(123).putInt(1).putLong(0).putShort(0).putShort(0).putInt(0).putInt(flags)
            return S9Message(3,128,sid,1,b.array())
        }
    }
    @Test fun multiKeyReleaseOldSessionAndFeedbackPhases() {
        val f=Fixture();for(k in 0..3)assertTrue(f.client.press(k,60+k,100))
        assertEquals(4,f.sent.size);f.client.releaseAll();assertTrue(f.client.heldKeys.isEmpty())
        val on=f.sent.toList()
        on.forEach {m ->
            f.client.result(f.result(m,1));assertEquals(4,f.sent.size)
        }
        on.forEach {f.client.result(f.result(it))}
        assertEquals(8,f.sent.size)
        for(k in 0..3) {
            val a=ByteBuffer.wrap(on[k].payload).order(ByteOrder.LITTLE_ENDIAN)
            val b=ByteBuffer.wrap(f.sent[k+4].payload).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(a.long,b.long);assertEquals(2,b.get().toInt());assertEquals(k,b.get().toInt())
        }
        f.sent.drop(4).forEach {f.client.result(f.result(it))};assertEquals(0,f.client.pendingCount)
        f.client.ready(ByteArray(16){(it+11).toByte()})
        assertTrue(f.client.press(0,62,100));f.client.result(f.result(on[0]));assertEquals(1,f.client.pendingCount)
    }
    @Test fun repeatsExactCommandAndRejectTerminatesForCleanup() {
        val f=Fixture();assertTrue(f.client.press(2,70,88));val original=f.sent.single()
        f.now=2000;f.client.tick();assertEquals(2,f.sent.count{it.opcode==16})
        assertArrayEquals(S9Protocol.encode(original),S9Protocol.encode(f.sent.last{it.opcode==16}))
        f.client.result(f.result(original,7,-9));assertFalse(f.client.connected)
        assertEquals(1,f.failures.size);assertTrue(f.client.heldKeys.isEmpty())
    }
    @Test fun offReservationAndUnsentDeadline() {
        val f=Fixture();f.writable=false
        for(k in 0..31)assertTrue(f.client.press(k,60,100))
        repeat(64){f.client.vibrato(it)}
        assertEquals(64,f.client.pendingCount)
        f.client.releaseAll();assertEquals(96,f.client.pendingCount);assertTrue(f.failures.isEmpty())
        f.now=12000;f.client.tick();assertEquals(1,f.failures.size);assertFalse(f.client.connected)
    }
    @Test fun pitchBarrierAndNoNarrowingBeforeValidation() {
        val f=Fixture();assertTrue(f.client.pitchParameter(32,4));assertFalse(f.client.press(0,60,100))
        val config=f.sent[0];val barrier=f.sent[1]
        f.client.result(f.result(config));assertFalse(f.client.pitchReady)
        f.client.result(f.result(barrier));assertTrue(f.client.pitchReady);assertTrue(f.client.press(0,60,100))
        try {f.client.pitchParameter(32,256);fail("wrapped invalid timbre")}catch(_:IllegalArgumentException){}
    }
    @Test fun repeatedReceiptDoesNotKeepCommandAliveAndFileRejectionIsDelivered() {
        val f=Fixture();f.client.press(0,60,100);val m=f.sent.single()
        repeat(13){f.now=it*1000L;f.client.result(f.result(m,1));f.client.tick()}
        assertFalse(f.client.connected);assertEquals(1,f.failures.size)
        val g=Fixture();var rejected=0
        g.client.fileCommand(67,byteArrayOf(),"取消上传",rejected={rejected++})
        g.client.result(g.result(g.sent.single(),7,-8));assertEquals(1,rejected);assertTrue(g.client.connected)
    }
    @Test fun idleHeartbeatIsBoundedAndAcknowledgedIndependently() {
        val f=Fixture();f.now=100;f.client.tick();val h=f.sent.single()
        assertEquals(2,h.opcode);assertEquals(1,h.channel)
        f.now=200;f.client.tick();assertEquals(1,f.sent.size)
        f.client.result(f.result(h));f.now=201;f.client.tick();assertEquals(2,f.sent.size)
        assertEquals(h.sequence+1,f.sent.last().sequence)
    }
    @Test fun longCommitRequiresAdvancingCheckedBytesNotRepeatedReceipt() {
        val f=Fixture();f.client.fileCommand(66,byteArrayOf(),"保存",4);val commit=f.sent.single()
        for(i in 1..80){
            f.now=i*1000L
            val r=f.result(commit,2);ByteBuffer.wrap(r.payload).order(ByteOrder.LITTLE_ENDIAN).putInt(28,i*512)
            f.client.result(r);f.client.tick()
            f.sent.filter{it.opcode==2}.toList().forEach{f.client.result(f.result(it))}
        }
        assertTrue(f.client.connected);assertTrue(f.failures.isEmpty())
        // A duplicate progress cursor cannot defeat the absolute deadline.
        f.now=2400000;f.client.tick();assertFalse(f.client.connected)
    }
}
