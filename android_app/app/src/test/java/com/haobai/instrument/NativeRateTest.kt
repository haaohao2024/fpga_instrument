package com.haobai.instrument
import org.junit.Test
import org.junit.Assert.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
class NativeRateTest {
 @Test fun oldAndNewLoopHaveSameDuration() {
  fun info(version:Byte, samples:Long):String { val p=ByteArray(64);p[0]=version;p[1]=2;p[2]=1;ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN).putLong(24,samples);return EnsembleProtocol.loopDescription(p) }
  assertEquals(info(1,480000),info(2,960000))
  assertEquals(info(1,480000),info(3,1280000))
 }
 @Test(expected=IllegalArgumentException::class) fun unknownRateIsNotGuessed(){val p=ByteArray(64);p[0]=4;EnsembleProtocol.loopDescription(p)}
}
