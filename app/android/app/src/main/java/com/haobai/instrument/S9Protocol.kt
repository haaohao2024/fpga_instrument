package com.haobai.instrument

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

data class S9Message(val channel: Int, val opcode: Int, val session: ByteArray,
                     val sequence: Long, val payload: ByteArray)

object S9Protocol {
    private fun buffer(bytes: ByteArray) = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    fun crc(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset): Long =
        CRC32().apply { update(bytes, offset, length) }.value

    fun encode(message: S9Message): ByteArray {
        val m = message
        require(m.channel in 0..3 && m.opcode in 0..255)
        require(m.session.size == 16 && m.session.take(8).any { it != 0.toByte() } && m.session.drop(8).any { it != 0.toByte() })
        require(m.sequence in 1..0xffffffffL && m.payload.size <= S9Constants.MAX_PAYLOAD)
        val size = 36 + m.payload.size
        require(m.channel >= S9Constants.CH_FILE || size <= S9Constants.MAX_CONTROL_MESSAGE)
        val out = ByteArray(size)
        val b = buffer(out)
        b.put(byteArrayOf(83, 57, 65, 80))
        b.put(1).put(m.channel.toByte()).put(m.opcode.toByte()).put(0)
        b.put(m.session).putInt(m.sequence.toInt()).putShort(m.payload.size.toShort()).putShort(0)
        b.put(m.payload).putInt(crc(out, 0, size - 4).toInt())
        return out
    }

    fun decode(bytes: ByteArray): S9Message {
        require(bytes.size in 36..S9Constants.MAX_MESSAGE)
        require(bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(83, 57, 65, 80)))
        val b = buffer(bytes)
        val channel = bytes[5].toInt() and 255
        require(bytes[4] == 1.toByte() && channel in 0..3 && bytes[7] == 0.toByte())
        require(b.getShort(30) == 0.toShort())
        val size = b.getShort(28).toInt() and 65535
        require(size + 36 == bytes.size && (channel >= 2 || bytes.size <= 192))
        require(crc(bytes, 0, bytes.size - 4) == (b.getInt(bytes.size - 4).toLong() and 0xffffffffL))
        val sid = bytes.copyOfRange(8, 24)
        require(buffer(sid).getLong(0) != 0L && buffer(sid).getLong(8) != 0L)
        val seq = b.getInt(24).toLong() and 0xffffffffL
        require(seq != 0L)
        return S9Message(channel, bytes[6].toInt() and 255, sid, seq, bytes.copyOfRange(32, bytes.size - 4))
    }

    fun fragments(message: S9Message, mtu: Int): List<ByteArray> {
        require(mtu in 23..517)
        val raw = encode(message)
        val capacity = mtu - 3 - S9Constants.FRAGMENT_HEADER
        return (raw.indices step capacity).map { offset ->
            val count = minOf(capacity, raw.size - offset)
            ByteArray(8 + count).also { out ->
                buffer(out).putInt(message.sequence.toInt()).putShort(offset.toShort())
                    .putShort(count.toShort()).put(raw, offset, count)
            }
        }
    }

    fun event(pressId: Long, kind: Int, key: Int, note: Int, value: Int): ByteArray {
        require(kind in 1..4 && note in 0..127 && value in 0..255)
        if (kind == 4) require(pressId == 0L && key == 255 && note == 0)
        else {
            require(pressId != 0L && key in 0 until 32)
            if (kind == 1) require(value > 0)
            if (kind == 2) require(note == 0 && value == 0)
        }
        return ByteArray(16).also {
            buffer(it).putLong(pressId).put(kind.toByte()).put(key.toByte())
                .put(note.toByte()).put(value.toByte()).putInt(0)
        }
    }

    fun gain(local: Int, external: Int, muteLocal: Boolean, muteExternal: Boolean): ByteArray {
        require(local in 0..32768 && external in 0..32768)
        return ByteArray(8).also {
            buffer(it).putShort(local.toShort()).putShort(external.toShort())
                .put(((if (muteLocal) 1 else 0) or (if (muteExternal) 2 else 0)).toByte())
        }
    }

    fun keymap(notes: List<Int>): ByteArray {
        require(notes.size == 8 && notes.all { it in S9Constants.KEYMAP_MIN..S9Constants.KEYMAP_MAX })
        return notes.map { it.toByte() }.toByteArray()
    }

    fun effects(words: LongArray): ByteArray {
        require(words.size == 11 && words.all { it in 0..0xffffffffL })
        val w = words
        require(w[0] <= 127 && w[1] in 1..S9Constants.DELAY_MAX.toLong() && w[2] <= S9Constants.DELAY_FEEDBACK_MAX)
        require(w[3] in S9Constants.CHORUS_BASE_MIN.toLong()..S9Constants.CHORUS_BASE_MAX.toLong())
        require(w[4] <= S9Constants.CHORUS_DEPTH_MAX && w[3] >= w[4] + 2 && w[3] + w[4] <= S9Constants.CHORUS_ADDRESS_MAX)
        require(w[5] == 0L || w[5] in S9Constants.CHORUS_STEP_MIN.toLong()..S9Constants.CHORUS_STEP_MAX.toLong())
        require(w[6] <= S9Constants.FDN_COEFFICIENT_MAX && w[7] <= S9Constants.FDN_COEFFICIENT_MAX)
        require(w.slice(8..10).all { it <= S9Constants.WET_GAIN_MAX })
        return ByteArray(44).also { out -> buffer(out).apply { w.forEach { putInt(it.toInt()) } } }
    }
}
