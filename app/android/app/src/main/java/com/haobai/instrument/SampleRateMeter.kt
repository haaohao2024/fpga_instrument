package com.haobai.instrument

/**
 * Turns the FPGA frame counter into a measured synthesis sample rate.
 *
 * Every hardware-stats result carries the 32-bit `frame` counter, which the FPGA
 * increments once per finished synthesis frame — that is, once per output audio
 * sample. Pairing the counter with the phone's monotonic clock gives
 * Δframe ÷ Δtime, so the number comes from the board itself instead of repeating
 * a label.
 *
 * Bluetooth notifications arrive with tens of milliseconds of jitter, so the
 * window is at least five seconds wide and slides forward one sample at a time.
 */
class SampleRateMeter(private val windowNanos:Long=MINIMUM_WINDOW_NANOS) {
    /** One measurement: the rate plus what it was measured over. */
    data class Reading(val hertz:Double,val windowNanos:Long,val samples:Int) {
        val kilohertz:Double get()=hertz/1000.0

        /** The line shown on the test page. */
        fun summary():String = String.format(
            java.util.Locale.US,"实测合成采样率：%.1f kHz（±1%%，%.0f 秒平均）",kilohertz,windowNanos/1e9
        )
    }

    private val frames=ArrayDeque<Long>()
    private val times=ArrayDeque<Long>()

    var reading:Reading?=null
        private set

    /** Forgets every sample; the next reading needs a fresh five-second window. */
    fun reset() {
        frames.clear();times.clear();reading=null
    }

    /**
     * Feeds one stats sample. [timeNanos] must come from a monotonic clock
     * (`SystemClock.elapsedRealtimeNanos()`), never from the wall clock, which the
     * system can step while we measure.
     *
     * @return the new reading, or null while the window is still too short or the
     * sample had to be discarded.
     */
    fun add(frame:Long,timeNanos:Long):Reading? {
        val f=frame and 0xffffffffL
        if(frames.isEmpty()) {
            frames.addLast(f);times.addLast(timeNanos);return null
        }
        val lastTime=times.last()
        // A zero or negative gap carries no information; drop the sample instead
        // of dividing by zero.
        if(timeNanos<=lastTime) return null
        // Wrapping subtraction keeps a genuine 32-bit rollover continuous.
        if(((f-frames.last()) and 0xffffffffL)>RESET_STEP) {
            reset();frames.addLast(f);times.addLast(timeNanos);return null
        }
        frames.addLast(f);times.addLast(timeNanos)
        // Drop the oldest sample while the next one is still outside the window,
        // so the measured span is never shorter than requested.
        val cutoff=if(timeNanos>windowNanos) timeNanos-windowNanos else 0L
        while(frames.size>2&&times.elementAt(1)<=cutoff) {
            frames.removeFirst();times.removeFirst()
        }
        val elapsed=timeNanos-times.first()
        if(elapsed<windowNanos||frames.size<2) {
            reading=null;return null
        }
        val delta=(frames.last()-frames.first()) and 0xffffffffL
        val hertz=delta*1_000_000_000.0/elapsed.toDouble()
        if(hertz<MINIMUM_HERTZ||hertz>MAXIMUM_HERTZ) {
            // Not a real audio rate: the history is suspect, start over.
            reset();return null
        }
        val new=Reading(hertz,elapsed,frames.size)
        reading=new
        return new
    }

    companion object {
        /** A shorter window would make the reading jump around. */
        const val MINIMUM_WINDOW_NANOS=5_000_000_000L
        const val MINIMUM_HERTZ=1_000.0
        const val MAXIMUM_HERTZ=1_000_000.0

        /** A counter step larger than half the range means the FPGA restarted, not
         * that it wrapped: a real wrap is a tiny step (about 9.3 h at 128 kHz),
         * while 2³¹ frames is already 4.6 h. */
        const val RESET_STEP=0x80000000L

        /** Why the number can be trusted; shown as small print under the line. */
        const val PROVENANCE="由 FPGA 帧计数与手机时钟测得，非标注值"
    }
}
