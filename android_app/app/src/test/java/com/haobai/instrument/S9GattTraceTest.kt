package com.haobai.instrument
import org.junit.Assert.*
import org.junit.Test
class S9GattTraceTest {
    @Test fun recordsTheExactUnreturnedOperationWithoutData(){
        var now=0L;val t=S9GattTrace{now};t.begin("WRITE_CFG seq=9 offset=0 bytes=44")
        now=781;t.end(0);assertEquals("none elapsed=0ms",t.pending())
        t.begin("READ_INFO");now=3781
        assertEquals("READ_INFO elapsed=3000ms",t.pending())
        assertTrue(t.snapshot().contains("781ms operation_callback WRITE_CFG seq=9 offset=0 bytes=44 status=0 elapsed=781ms"))
        repeat(2000){t.mark("notification","bytes=80")};assertEquals(1025,t.snapshot().lines().size)
    }
}
