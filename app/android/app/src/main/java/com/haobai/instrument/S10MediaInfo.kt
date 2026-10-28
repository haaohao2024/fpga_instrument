package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Optional Stage10 INFO fields. These report the device DIGITAL media path,
 * not successful phone system routing, RF quality or wireless latency. */
data class S10MediaInfo(val state: Int, val error: Int, val sourceRate: Int,
                       val busReady: Boolean, val epochLow: Long, val faults: Long) {
    fun description(): String {
        // Pipeline PLAY means transport is running; the DAC may still be
        // pre-filling/fading. Do not label this acknowledgement as audible.
        val phase=listOf("停止", "启动中", "传输中", "正在停止")[state]
        val rate=when(sourceRate){44100->"44.1→48 kHz";48000->"48 kHz";else->"等待SBC格式"}
        return "伴奏数字链：$phase，$rate" + (if(error!=0) "，错误码$error" else "") +
               (if(!busReady) "，SPI未就绪" else "")
    }
    companion object {
        fun parse(info: ByteArray): S10MediaInfo? {
            require(info.size==64 && info.copyOfRange(0,4).contentEquals("S9IN".toByteArray()) && info[4]==1.toByte())
            val b=ByteBuffer.wrap(info).order(ByteOrder.LITTLE_ENDIAN)
            require(S9Protocol.crc(info,0,60)==(b.getInt(60).toLong() and 0xffffffffL))
            if((b.getInt(44) and 16)==0) return null
            fun u8(i:Int)=info[i].toInt() and 255
            require(u8(48) in 0..3 && u8(50) in 0..2 && u8(51) in 0..1)
            return S10MediaInfo(u8(48),u8(49),when(u8(50)){1->44100;2->48000;else->0},
                u8(51)==1,b.getInt(52).toLong() and 0xffffffffL,b.getInt(56).toLong() and 0xffffffffL)
        }
    }
}
