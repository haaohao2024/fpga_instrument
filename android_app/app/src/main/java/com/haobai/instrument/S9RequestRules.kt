package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Outgoing semantic checks; the codec separately checks framing and CRC. */
object S9RequestRules {
    fun error(m:S9Message):Int {
        val p=m.payload;val n=p.size;val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN)
        fun u8(i:Int)=p[i].toInt() and 255
        fun u16(i:Int)=b.getShort(i).toInt() and 65535
        fun u32(i:Int)=b.getInt(i).toLong() and 0xffffffffL
        fun zero(from:Int,to:Int)=p.sliceArray(from until to).all {it==0.toByte()}
        fun range(ok:Boolean)=if(ok) 0 else -4
        S11Protocol.requestError(m)?.let {return it}
        if(m.channel==0) {
            if(m.opcode!=16 || n==0 || n%16!=0 || n>144)return -2
            for(i in 0 until n step 16) {
                val press=b.getLong(i);val kind=u8(i+8);val key=u8(i+9);val note=u8(i+10);val value=u8(i+11)
                if(!zero(i+12,i+16)||kind !in 1..4||note>127)return -4
                if(kind==4) {if(press!=0L||key!=255||note!=0)return -4}
                else {
                    if(press==0L||key>=32)return -4
                    if(kind==1&&value==0)return -4
                    if(kind==2&&(note!=0||value!=0))return -4
                }
            }
            return 0
        }
        if(m.channel==1)return when(m.opcode) {
            1,2,3 -> if(n==0)0 else -1
            4 -> range(n==5&&u8(0)<=2&&u32(1)!=0L)
            40 -> range(n==8&&u8(0)<=1&&u8(1) in 3..5&&zero(2,4)&&u32(4)!=0L)
            32 -> range(n==1&&u8(0)<=S9Constants.MAX_TIMBRE)
            33 -> range(n==1&&u8(0)<=S9Constants.MAX_GLIDE)
            34 -> range(n==16&&b.getLong(0)!=0L&&u16(10)<=S9Constants.MAX_PAN&&zero(12,16))
            36 -> range(n==8&&u16(0)<=S9Constants.UNITY_GAIN&&u16(2)<=S9Constants.UNITY_GAIN&&u8(4)<=3&&zero(5,8))
            37 -> if(n!=8)-1 else range(p.all {(it.toInt() and 255) in S9Constants.KEYMAP_MIN..S9Constants.KEYMAP_MAX})
            39 -> range(n==9&&u8(0)<32&&b.getLong(1)!=0L)
            38 -> range(n==8&&zero(2,8)&&((u8(0)==1&&u8(1)<=3)||(u8(0)==6&&u8(1)<=1)||(u8(0) in 3..5&&u8(1)==0)))
            35 -> if(n!=44)-1 else try {S9Protocol.effects(LongArray(11){u32(it*4)});0}catch(_:IllegalArgumentException){-4}
            else -> -2
        }
        if(m.channel==2)return when(m.opcode) {
            64 -> range(n==16&&u32(0) in 1024..S9Constants.MAX_SCORE_BYTES.toLong()&&u32(0)%512==0L&&zero(8,16))
            65 -> {
                if(n !in 13..512||b.getLong(0)<0||b.getLong(0)>S9Constants.MAX_SCORE_BYTES||n-12>S9Constants.MAX_SCORE_BYTES-b.getLong(0))-4
                else if(S9Protocol.crc(p,12,n-12)!=u32(8))-3 else 0
            }
            66,67 -> if(n==0)0 else -1
            else -> -2
        }
        return -2
    }
}
