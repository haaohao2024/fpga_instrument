package com.haobai.instrument
import org.junit.Assert.*
import org.junit.Test
class S9TouchKeysTest {
    @Test fun multiTouchCancelMoveAndDuplicatePointer() {
        val on=ArrayList<Int>();val off=ArrayList<Int>();val t=S9TouchKeys({on.add(it);true},{off.add(it)})
        t.press(10,0);t.press(11,1);t.press(12,1);assertEquals(listOf(0,1),on)
        t.move(10,0);assertTrue(off.isEmpty());t.move(10,-1);assertEquals(listOf(0),off)
        t.cancel();assertEquals(listOf(0,1),off);t.release(11);assertEquals(2,off.size)
        t.press(1,2);t.press(1,3);t.cancel();assertEquals(listOf(0,1,2,3),off)
    }
    @Test fun rejectedOnHasNoOff() {var off=0;val t=S9TouchKeys({false},{off++});t.press(0,0);t.cancel();assertEquals(0,off)}
}
