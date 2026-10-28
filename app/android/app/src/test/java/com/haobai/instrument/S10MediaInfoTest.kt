package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S10MediaInfoTest {
    private fun info(feature: Boolean=true, state: Int=2, rate: Int=2, ready:Int=1):ByteArray {
        val v=ByteArray(64);"S9IN".toByteArray().copyInto(v);v[4]=1
        val b=ByteBuffer.wrap(v).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(44,if(feature)31 else 15);v[48]=state.toByte();v[50]=rate.toByte();v[51]=ready.toByte()
        b.putInt(52,-1);b.putInt(56,-2);b.putInt(60,S9Protocol.crc(v,0,60).toInt());return v
    }
    @Test fun compatibleOldDevice(){assertNull(S10MediaInfo.parse(info(false)))}
    @Test fun statesAndRates(){
        for(s in 0..3)for(r in 0..2)for(ready in 0..1){
            val x=S10MediaInfo.parse(info(state=s,rate=r,ready=ready))!!
            assertEquals(s,x.state);assertEquals(ready==1,x.busReady)
            assertEquals(listOf(0,44100,48000)[r],x.sourceRate)
            assertEquals(4294967295L,x.epochLow);assertEquals(4294967294L,x.faults)
            assertTrue(x.description().startsWith("伴奏数字链："))
            if(s==2)assertTrue(x.description().contains("传输中"))
        }
    }
    @Test fun errorIsDigitalNotWireless(){val v=info();v[49]=8;val b=ByteBuffer.wrap(v).order(ByteOrder.LITTLE_ENDIAN);b.putInt(60,S9Protocol.crc(v,0,60).toInt());assertTrue(S10MediaInfo.parse(v)!!.description().contains("错误码8"))}
    @Test fun corruptCRCRejected(){val v=info();v[52]=0;try{S10MediaInfo.parse(v);fail()}catch(_:IllegalArgumentException){}}
    @Test fun illegalKnownFieldsRejected(){
        for(v in listOf(info(state=4),info(rate=3),info(ready=2))){try{S10MediaInfo.parse(v);fail()}catch(_:IllegalArgumentException){}}
    }
}
