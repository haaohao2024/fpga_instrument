package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class EnsembleProtocolTest {
    private fun invalid(f:()->Unit) {try {f();fail("Invalid input accepted")}catch(_:IllegalArgumentException){}}
    @Test fun configurationWireLayoutAndBoundaries() {
        assertArrayEquals(byteArrayOf(1,2,11,1,180.toByte(),0,2,0),EnsembleProtocol.start(2,11,1,180,2))
        assertArrayEquals(byteArrayOf(1,0,0,0,50,0,0,0),EnsembleProtocol.start(0,0,0,50,0))
        invalid{EnsembleProtocol.start(3,0,0,120,0)}
        invalid{EnsembleProtocol.start(2,12,0,120,0)}
        invalid{EnsembleProtocol.start(2,0,2,120,0)}
        invalid{EnsembleProtocol.start(2,0,0,49,0)}
        invalid{EnsembleProtocol.start(2,0,0,181,0)}
        invalid{EnsembleProtocol.start(2,0,0,120,3)}
        val sid=ByteArray(16){1}
        assertEquals(0,S9RequestRules.error(S9Message(1,104,sid,1,EnsembleProtocol.start(2,0,0,120,0))))
        for(op in listOf(105,106,41)) assertEquals(0,S9RequestRules.error(S9Message(1,op,sid,2,byteArrayOf())))
    }
    @Test fun nativeMetricsAreNotInferredFromSoftwareEvents() {
        val p=byteArrayOf(1,32,28,8,12,18,32,0,50,1,0,2,-1,-1,-1,-1)
        val v=VoiceMetrics.decode(p)
        assertEquals(28,v.allocated);assertEquals(8,v.gated);assertEquals(12,v.nonzero)
        assertEquals(18,v.peak);assertEquals(32,v.completed);assertEquals(306,v.cycles);assertEquals(0xffffffffL,v.frame)
        for(i in 0..15){
            if(i in listOf(0,1,2,3,4,5,6,7,10,11)) {
                val bad=p.clone();bad[i]=if(i==7)4 else 127
                invalid{VoiceMetrics.decode(bad)}
            }
        }
        invalid{VoiceMetrics.decode(ByteArray(15))}
    }
    @Test fun expandedCapacityComesFromHardwareAndRejectsOutOfRangeCounts() {
        for(cap in listOf(32,48,64)) {
            val p=byteArrayOf(1,cap.toByte(),cap.toByte(),cap.toByte(),cap.toByte(),cap.toByte(),cap.toByte(),0,50,1,0,2,0,0,0,0)
            val v=VoiceMetrics.decode(p)
            assertEquals(cap,v.capacity);assertEquals(cap,v.completed)
            assertTrue(v.description().contains("/$cap"))
            p[6]=(cap+1).toByte();invalid{VoiceMetrics.decode(p)}
        }
        val bad=byteArrayOf(1,33,0,0,0,0,0,0,50,1,0,2,0,0,0,0)
        invalid{VoiceMetrics.decode(bad)}
    }
    @Test fun ensembleInfoRetainsFaultAndUnsignedCounters() {
        val p=ByteArray(64);p[0]=1;p[1]=3;p[2]=2;p[3]=11;p[4]=1;p[32]=8;p[33]=16;p[35]=4
        val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN);b.putShort(6,180);b.putInt(16,-1);b.putInt(20,123);b.putInt(24,2)
        val v=EnsembleInfo.decode(p)
        assertEquals(0xffffffffL,v.generated);assertEquals(123L,v.observed);assertEquals(4,v.reason)
        assertTrue(v.description().contains("原因 4"))
        p[33]=17;invalid{EnsembleInfo.decode(p)}
    }
    @Test fun drumSelectionAndReleaseConfigurationUseExistingCommands() {
        val sent=mutableListOf<S9Message>();val c=S9ClientSession({sent+=it;true},{fail(it)},{}, {0L})
        c.ready(ByteArray(16){1});assertTrue(c.pitchParameter(32,5))
        assertEquals(32,sent.first().opcode);assertEquals(5,sent.first().payload[0].toInt())
        invalid{c.pitchParameter(32,6)}
    }
}
