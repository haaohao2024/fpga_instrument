package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S9ProtocolTest {
    private fun unhex(text: String): ByteArray = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun invalid(action: () -> Unit) {
        try { action(); fail("Invalid input accepted") } catch (_: IllegalArgumentException) { }
    }
    private fun fixtures(): List<Pair<S9Message, ByteArray>> =
        javaClass.classLoader!!.getResourceAsStream("golden_messages.tsv")!!.bufferedReader().readLines().drop(1).map {
            val p = it.split('\t')
            val raw = unhex(p[4])
            S9Message(p[1].toInt(), p[2].toInt(), raw.copyOfRange(8,24), p[0].toLong(), unhex(p[3])) to raw
        }

    @Test fun independentGoldenEncodingAndDecoding() {
        val fixtures = fixtures()
        assertEquals(21, fixtures.size)
        fixtures.forEach { (message, expected) ->
            assertArrayEquals(expected, S9Protocol.encode(message))
            val decoded = S9Protocol.decode(expected)
            assertEquals(message.channel, decoded.channel)
            assertEquals(message.opcode, decoded.opcode)
            assertEquals(message.sequence, decoded.sequence)
            assertArrayEquals(message.session, decoded.session)
            assertArrayEquals(message.payload, decoded.payload)
        }
        assertEquals(0xcbf43926L, S9Protocol.crc("123456789".toByteArray()))
    }

    @Test fun mtu23And247FragmentHeadersAndCoverage() {
        fixtures().forEach { (message, expected) ->
            listOf(23,247).forEach { mtu ->
                var offset = 0
                val actual = ArrayList<Byte>()
                S9Protocol.fragments(message, mtu).forEach { fragment ->
                    assertTrue(fragment.size <= mtu - 3)
                    val b = ByteBuffer.wrap(fragment).order(ByteOrder.LITTLE_ENDIAN)
                    assertEquals(message.sequence, b.int.toLong() and 0xffffffffL)
                    assertEquals(offset, b.short.toInt() and 65535)
                    assertEquals(fragment.size - 8, b.short.toInt() and 65535)
                    actual.addAll(fragment.drop(8)); offset += fragment.size - 8
                }
                assertArrayEquals(expected, actual.toByteArray())
            }
        }
    }

    @Test fun malformedAndTruncatedMessagesAreRejected() {
        fixtures().forEach { (_, raw) ->
            for (size in raw.indices) invalid { S9Protocol.decode(raw.copyOf(size)) }
            val wrong = raw.clone(); wrong[wrong.lastIndex] = (wrong.last().toInt() xor 1).toByte()
            invalid { S9Protocol.decode(wrong) }
        }
        val base = fixtures().first().first
        invalid { S9Protocol.encode(base.copy(sequence=0)) }
        invalid { S9Protocol.encode(base.copy(sequence=0x100000000L)) }
        invalid { S9Protocol.encode(base.copy(session=ByteArray(16))) }
    }

    @Test fun parameterAndGestureLimits() {
        assertEquals(16, S9Protocol.event(-1L,1,31,127,255).size)
        invalid { S9Protocol.event(0,1,0,60,100) }
        invalid { S9Protocol.event(1,2,0,60,0) }
        invalid { S9Protocol.event(1,1,32,60,100) }
        invalid { S9Protocol.gain(32769,0,false,false) }
        assertEquals(8, S9Protocol.gain(32768,32768,true,true).size)
        invalid { S9Protocol.keymap(listOf(60,62,64,65,67,69,71,104)) }
        val fx=longArrayOf(127,16383,24576,576,192,71583,28672,28672,8192,8192,8192)
        assertEquals(44,S9Protocol.effects(fx).size)
        fx[3]=96; invalid { S9Protocol.effects(fx) }
    }
}
