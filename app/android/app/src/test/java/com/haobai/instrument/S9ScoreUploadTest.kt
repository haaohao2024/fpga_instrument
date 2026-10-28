package com.haobai.instrument
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class S9ScoreUploadTest {
    private class File: S9ScoreUpload.Source {
        val bytes=ByteArray(1536){(it*37+11).toByte()};var closed=false
        override val length=bytes.size;override val crc=S9Protocol.crc(bytes)
        override fun read(offset:Int,count:Int)=bytes.copyOfRange(offset,offset+count)
        override fun close(){closed=true}
    }
    @Test fun stopAckChunksAndSavedAreDistinct() {
        val sent=ArrayList<S9Message>();val text=ArrayList<String>();val sid=ByteArray(16){(it+1).toByte()}
        val c=S9ClientSession({sent.add(it);true},{fail(it)},{},{0});c.ready(sid)
        val u=S9ScoreUpload(c,{text.add(it)});val f=File();assertTrue(u.start(f));assertEquals(38,sent.single().opcode)
        fun ack(m:S9Message,phase:Int,flags:Int=0) {
            val b=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
            b.putInt(m.sequence.toInt()).put(m.channel.toByte()).put(phase.toByte()).putShort(0)
            b.putInt(0).putInt(0).putLong(0).putShort(0).putShort(0).putInt(0).putInt(flags)
            c.result(S9Message(3,128,sid,1,b.array()))
        }
        ack(sent[0],2);assertEquals(1,sent.size);ack(sent[0],3);assertEquals(64,sent.last().opcode)
        ack(sent.last(),3)
        var offset=0
        while(sent.last().opcode==65) {
            val m=sent.last();val b=ByteBuffer.wrap(m.payload).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(offset.toLong(),b.long);val crc=b.int.toLong() and 0xffffffffL
            val bytes=m.payload.copyOfRange(12,m.payload.size)
            assertArrayEquals(f.bytes.copyOfRange(offset,offset+bytes.size),bytes);assertEquals(S9Protocol.crc(bytes),crc)
            offset+=bytes.size;ack(m,3)
        }
        assertEquals(1536,offset);assertEquals(66,sent.last().opcode);assertTrue(u.active)
        ack(sent.last(),3);assertTrue(u.active);assertFalse(f.closed)
        ack(sent.last(),4,4);assertFalse(u.active);assertTrue(f.closed);assertTrue(text.last().contains("确认保存"))
    }
    @Test fun cancelBeforeStopDoesNotStartFileWrite() {
        val sent=ArrayList<S9Message>();val sid=ByteArray(16){(it+1).toByte()}
        val c=S9ClientSession({sent.add(it);true},{},{},{0});c.ready(sid)
        val u=S9ScoreUpload(c,{});val f=File();u.start(f);u.cancel()
        val b=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN).putInt(1).put(1).put(3).putShort(0)
        u.run {c.result(S9Message(3,128,sid,1,b.array()))}
        assertEquals(1,sent.size);assertFalse(u.active);assertTrue(f.closed)
    }
}
