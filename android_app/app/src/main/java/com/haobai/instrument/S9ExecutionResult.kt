package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class S9ExecutionResult(val sequence:Long,val channel:Int,val phase:Int,val error:Int,
                             val effectiveFrame:Long?,val configVersion:Long,val instanceId:Long?,
                             val generation:Int,val value:Int,val diagnostic:Long,val saved:Boolean) {
    val description:String get() = when(phase) {
        S9Constants.PHASE_RECEIVED -> "MCU已接收（未执行）"
        S9Constants.PHASE_ACCEPTED -> if(channel==2) "文件服务已接受（未保存）" else "FPGA已接受（待提交）"
        S9Constants.PHASE_COMMITTED -> "已提交（尚未确认采样生效）"
        S9Constants.PHASE_EFFECTIVE -> if(saved) "曲谱已校验并保存" else "采样帧 $effectiveFrame 生效"
        S9Constants.PHASE_TARGET_REACHED -> "增益已到达目标"
        S9Constants.PHASE_CANCELLED -> "已取消"
        S9Constants.PHASE_REJECTED -> "已拒绝：$error"
        else -> error("Unknown phase")
    }
    companion object {
        fun decode(message:S9Message):S9ExecutionResult {
            require(message.channel==3 && message.opcode==128 && message.payload.size==36)
            val b=ByteBuffer.wrap(message.payload).order(ByteOrder.LITTLE_ENDIAN)
            val seq=b.int.toLong() and 0xffffffffL
            val channel=b.get().toInt() and 255
            val phase=b.get().toInt() and 255
            val err=b.short.toInt()
            val frame=b.int.toLong() and 0xffffffffL
            val version=b.int.toLong() and 0xffffffffL
            val id=b.long;val generation=b.short.toInt() and 65535;val value=b.short.toInt() and 65535
            val diagnostic=b.int.toLong() and 0xffffffffL;val flags=b.int
            require(seq!=0L && channel in 0..2 && phase in 1..7 && err in -13..0 && flags and 7.inv()==0)
            val saved=flags and 4!=0
            require(!saved || (channel==2 && phase==4 && err==0))
            if(phase==4 && !saved) require(flags and 1!=0)
            if(phase==7) require(err<0)
            if(flags and 2!=0) require(id!=0L)
            return S9ExecutionResult(seq,channel,phase,err,if(flags and 1!=0) frame else null,
                version,if(flags and 2!=0) id else null,generation,value,diagnostic,saved)
        }
    }
}
