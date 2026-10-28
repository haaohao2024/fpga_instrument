package com.haobai.instrument
import java.nio.ByteBuffer
import java.nio.ByteOrder

object EnsembleProtocol {
    fun start(level:Int,root:Int,minor:Int,bpm:Int,style:Int):ByteArray {
        require(level in 0..2&&root in 0..11&&minor in 0..1&&bpm in 50..180&&style in 0..2)
        return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put(1).put(level.toByte()).put(root.toByte()).put(minor.toByte()).putShort(bpm.toShort()).put(style.toByte()).put(0).array()
    }
    fun loopDescription(p:ByteArray):String {
        require(p.size==64&&p[0].toInt() in 1..3)
        val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN)
        val state=listOf("空闲","录第一层","循环播放","录下一层","等待尾音","已停止","正在切换","错误").getOrNull(p[1].toInt() and 255)?:"未知"
        val layers=p[2].toInt() and 255;require(layers<=4)
        return "$state · $layers/4层 · 循环长度 ${"%.2f".format(b.getLong(24)/(if(p[0].toInt()==3)128000.0 else if(p[0].toInt()==2)96000.0 else 48000.0))} 秒 · ${b.getInt(32)} 条事件"
    }
}
data class VoiceMetrics(val allocated:Int,val gated:Int,val nonzero:Int,val peak:Int,val completed:Int,val faults:Int,val cycles:Int,val frame:Long,val capacity:Int=32) {
    fun description()="FPGA：已分配 $allocated/$capacity，按住 $gated，非零贡献 $nonzero（近512帧峰值 $peak）\n每帧实际完成 $completed 个声部，计算 $cycles 拍；状态 ${if(faults==0)"正常" else "异常 $faults"}"
    companion object {
        fun decode(p:ByteArray):VoiceMetrics {
            require(p.size==16);fun u(i:Int)=p[i].toInt() and 255
            val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN)
            require(u(0)==1&&u(1) in listOf(32,48,64)&&(2..6).all{u(it)<=u(1)}&&u(7)<=3&&(b.getShort(10).toInt() and 65535)==512)
            val cycles=b.getShort(8).toInt() and 65535;require(cycles in 1..511)
            return VoiceMetrics(u(2),u(3),u(4),u(5),u(6),u(7),cycles,b.getInt(12).toLong() and 0xffffffffL,u(1))
        }
    }
}
data class EnsembleInfo(val state:Int,val level:Int,val root:Int,val minor:Int,val bpm:Int,val generated:Long,val observed:Long,val skipped:Long,val human:Int,val slots:Int,val reason:Int) {
    fun description():String {
        val s=listOf("未运行","准备中","运行中","已停止并报告异常").getOrNull(state)?:"未知"
        return "智能合奏：$s · ${listOf("基础","标准","丰富")[level]} · $bpm BPM\n已观察 $observed 次起音，生成 $generated 条事件；现场按住 $human，伴奏含尾音占槽峰值 $slots/16，省略可选起音 $skipped${if(reason!=0)"，原因 $reason" else ""}"
    }
    companion object {
        fun decode(p:ByteArray):EnsembleInfo {
            require(p.size==64);fun u(i:Int)=p[i].toInt() and 255
            require(u(0)==1&&u(1)<=3&&u(2)<=2&&u(3)<=11&&u(4)<=1&&u(32)<=48&&u(33)<=16)
            val b=ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN);fun n(i:Int)=b.getInt(i).toLong() and 0xffffffffL
            return EnsembleInfo(u(1),u(2),u(3),u(4),b.getShort(6).toInt() and 65535,n(16),n(20),n(24),u(32),u(33),u(35))
        }
    }
}
