package com.haobai.instrument

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SampleRateMeterTest {
    private val ns=1_000_000_000L
    private val start=3_600L*ns

    /** Feeds one stats sample per second at 128 kHz and returns the last reading. */
    private fun feed(meter:SampleRateMeter,seconds:Int,firstFrame:Long,firstTime:Long):SampleRateMeter.Reading? {
        var reading:SampleRateMeter.Reading?=null
        for(second in 0..seconds) reading=meter.add(firstFrame+128_000L*second,firstTime+second*ns)
        return reading
    }

    @Test fun steady128kReads128k() {
        val meter=SampleRateMeter()
        val reading=feed(meter,6,1_000L,start)
        assertNotNull(reading)
        assertEquals(128_000.0,reading!!.hertz,1.0)
        assertEquals(5.0,reading.windowNanos/1e9,0.001)
        assertEquals("实测合成采样率：128.0 kHz（±1%，5 秒平均）",reading.summary())
    }

    @Test fun frameWrapKeepsCounting() {
        val meter=SampleRateMeter()
        // Start just below 2^32 so the counter rolls over during the window.
        val reading=feed(meter,6,0xFFFF0000L,start)
        assertNotNull(reading)
        assertEquals(128_000.0,reading!!.hertz,1.0)
    }

    @Test fun shortWindowGivesNoReading() {
        val meter=SampleRateMeter()
        // Five samples one second apart span only four seconds.
        assertNull(feed(meter,4,1_000L,start))
        assertNull(meter.reading)
    }

    @Test fun fpgaRestartClearsHistory() {
        val meter=SampleRateMeter()
        assertNotNull(feed(meter,6,1_000L,start))

        // The counter jumps back to a small value: the board restarted.
        assertNull(meter.add(16L,start+7*ns))
        assertNull(meter.reading)

        // Measuring continues from the restart without a stale window.
        val reading=feed(meter,6,16L,start+7*ns)
        assertNotNull(reading)
        assertEquals(128_000.0,reading!!.hertz,1.0)
    }

    @Test fun zeroOrNegativeTimeGapIsIgnored() {
        val meter=SampleRateMeter()
        assertNull(meter.add(1_000L,start))
        assertNull(meter.add(129_000L,start))        // same clock value
        assertNull(meter.add(257_000L,start-ns))     // clock ran backwards
        assertNull(meter.reading)

        // The history is intact: a normal run still measures.
        val reading=feed(meter,6,129_000L,start+ns)
        assertNotNull(reading)
        assertEquals(128_000.0,reading!!.hertz,1.0)
    }

    @Test fun outOfRangeRateResets() {
        val meter=SampleRateMeter()
        var reading:SampleRateMeter.Reading?=null
        // 100 Hz is far below any real synthesis rate, so it must not be shown.
        for(second in 0..6) reading=meter.add(1_000L+100*second,start+second*ns)
        assertNull(reading)
        assertNull(meter.reading)
    }
}
