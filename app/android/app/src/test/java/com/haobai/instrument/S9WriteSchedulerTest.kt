package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S9WriteSchedulerTest {
    private val sid=ByteArray(16).also {it[0]=1;it[8]=1}
    @Test fun fileFragmentsCannotBlockControlAndEachChannelIsOrdered() {
        val q=S9WriteScheduler()
        assertTrue(q.enqueue(S9Message(2,65,sid,1,ByteArray(512)),23))
        assertFalse(q.enqueue(S9Message(2,65,sid,2,ByteArray(512)),23))
        assertTrue(q.enqueue(S9Message(0,16,sid,1,S9Protocol.event(1,1,0,60,100)),23))
        assertTrue(q.enqueue(S9Message(1,32,sid,1,byteArrayOf(4)),23))
        val lastOffsets=IntArray(3){-1};val first=ArrayList<Int>();var time=0L
        while(q.size!=0) {
            val f=q.next(time)!!
            if(first.size<4) first.add(f.channel)
            val b=ByteBuffer.wrap(f.bytes).order(ByteOrder.LITTLE_ENDIAN)
            val offset=b.getShort(4).toInt() and 65535
            assertTrue(offset>lastOffsets[f.channel]);lastOffsets[f.channel]=offset
            assertSame(f,q.next(time+1)) // retries keep the exact selected fragment
            q.acknowledged();time+=20
        }
        assertEquals(listOf(0,0,1,2),first)
    }
    @Test fun stalledWriteAndDisconnectClear() {
        val q=S9WriteScheduler();q.enqueue(S9Message(0,16,sid,1,S9Protocol.event(1,1,0,60,100)),23)
        val first=q.next(10)
        assertSame(first,q.next(3009))
        try {q.next(3010);fail("Stalled GATT accepted")}catch(_:IllegalStateException){}
        q.clear();assertEquals(0,q.size);assertNull(q.next(4000))
    }
}
