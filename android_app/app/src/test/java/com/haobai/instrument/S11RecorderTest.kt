package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random
import java.util.zip.CRC32

class S11RecorderTest {
    private val sid=ByteArray(16){(it+1).toByte()}
    private fun crc(p:ByteArray)=CRC32().apply {update(p)}.value
    private fun info(file:ByteArray,phase:Int=5,flags:Int=1,id:Long=91):S11RecordInfo {
        val b=ByteBuffer.allocate(72).order(ByteOrder.LITTLE_ENDIAN)
        b.putLong(id).put(phase.toByte()).put(4).put(1).put(flags.toByte()).putInt(0)
        b.putLong(((file.size-512).coerceAtLeast(0)/4).toLong()).putLong(0)
        b.putLong(file.size.toLong()).putLong(0).putInt(crc(file).toInt()).putInt(0).putLong(100).putLong(2272)
        return S11RecordInfo.decode(S9Message(3,130,sid,1,b.array()))
    }
    private class Sink:S11Download.Sink {
        val bytes=ByteArrayOutputStream();var finished=false;var aborted=false
        override fun write(bytes:ByteArray){this.bytes.write(bytes)}
        override fun finish(){finished=true}
        override fun abort(){aborted=true}
    }
    private inner class Fixture {
        var now=1000L;val sent=ArrayList<S9Message>();val notices=ArrayList<String>()
        val client=S9ClientSession({sent.add(it);true},{throw AssertionError(it)},{notices.add(it)},{now})
        val download=S11Download(client,{notices.add(it)},{now})
        init {client.ready(sid)}
        fun ack(message:S9Message) {
            val p=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
            p.putInt(message.sequence.toInt()).put(message.channel.toByte()).put(3).putShort(0)
                .putInt(0).putInt(0).putLong(0).putShort(0).putShort(0).putInt(0).putInt(0)
            client.result(S9Message(3,128,sid,1,p.array()))
        }
        fun lastRequest()=sent.last{it.opcode==83}
        fun data(file:ByteArray,offset:Long,count:Int,id:Long=91,session:ByteArray=sid,checksum:Long?=null):S9Message {
            val bytes=file.copyOfRange(offset.toInt(),offset.toInt()+count)
            val p=ByteBuffer.allocate(32+count).order(ByteOrder.LITTLE_ENDIAN)
            p.putLong(id).putLong(offset).putLong(file.size.toLong()).putInt((checksum?:crc(bytes)).toInt())
                .put(1).put(0).putShort(0).put(bytes)
            return S9Message(3,129,session,1,p.array())
        }
    }
    @Test fun requestRangesAndNoAckImpliesSaved() {
        val m=S9Message(2,80,sid,1,S11Protocol.start(77,3));assertEquals(0,S9RequestRules.error(m))
        val bad=m.payload.clone();bad[9]=1;assertEquals(-4,S9RequestRules.error(m.copy(payload=bad)))
        assertEquals(0,S9RequestRules.error(S9Message(1,86,sid,2,S11Protocol.field(32))))
        assertEquals(0,S9RequestRules.error(S9Message(1,86,sid,2,S11Protocol.field(0))))
        val short=S9Message(2,83,sid,3,ByteArray(1));assertEquals(-4,S9RequestRules.error(short))
        val file=ByteArray(1024){it.toByte()}
        assertFalse(info(file,1,0).downloadable(1));assertFalse(info(file,4,0).downloadable(1))
        assertTrue(info(file).downloadable(1))
        try {info(file,4,1);fail("VERIFY_PENDING must not carry VERIFIED")}catch(_:IllegalArgumentException){}
    }
    @Test fun downloadChecksOrderDuplicatesBothAckOrdersAndFullCrc() {
        val file=ByteArray(9600){((it*37+it/11) and 255).toByte()};val f=Fixture();val sink=Sink()
        assertTrue(f.download.start(info(file),1,sink));var chunks=0
        while(f.download.active) {
            val req=f.lastRequest();val b=ByteBuffer.wrap(req.payload).order(ByteOrder.LITTLE_ENDIAN)
            val offset=b.getLong(8);val n=b.getShort(16).toInt() and 65535
            val data=f.data(file,offset,n)
            if(chunks%2==0) {f.download.data(data);f.download.data(data);f.ack(req)}
            else {f.ack(req);f.download.data(data)}
            chunks++
        }
        assertEquals(20,chunks);assertTrue(sink.finished);assertFalse(sink.aborted)
        assertArrayEquals(file,sink.bytes.toByteArray());assertEquals(file.size.toLong(),f.download.received)
    }
    @Test fun oldIdentitySessionAndAckWithoutDataDoNotAdvance() {
        val file=ByteArray(1024){it.toByte()};val f=Fixture();val sink=Sink()
        assertTrue(f.download.start(info(file),1,sink));val req=f.lastRequest();f.ack(req)
        assertEquals(0,sink.bytes.size());assertTrue(f.download.active)
        f.download.data(f.data(file,0,480,92));f.download.data(f.data(file,0,480,session=ByteArray(16){9}))
        assertEquals(0,sink.bytes.size());assertTrue(f.download.active)
        f.now+=10001;f.download.tick();assertEquals(2,f.sent.count{it.opcode==83})
        assertEquals(0,ByteBuffer.wrap(f.lastRequest().payload).order(ByteOrder.LITTLE_ENDIAN).getLong(8))
    }
    @Test fun cancelWhileFileAckPendingDefersAndInvalidatesLateData() {
        val file=ByteArray(1024);val f=Fixture();val sink=Sink()
        assertTrue(f.download.start(info(file),1,sink));val req=f.lastRequest()
        f.download.cancel();assertTrue(sink.aborted);assertFalse(f.download.active)
        f.download.data(f.data(file,0,480));assertEquals(0,sink.bytes.size())
        assertEquals(0,f.sent.count{it.opcode==84});f.ack(req);f.download.tick()
        assertEquals(1,f.sent.count{it.opcode==84})
    }
    @Test fun corruptChunkAndWholeFileDigestFailClosed() {
        val file=ByteArray(1024){it.toByte()};val f=Fixture();val sink=Sink()
        assertTrue(f.download.start(info(file),1,sink))
        f.download.data(f.data(file,0,480,checksum=0));assertTrue(sink.aborted);assertFalse(sink.finished)
        val g=Fixture();val wrong=info(file).copy(pcmCrc=123);val output=Sink()
        assertTrue(g.download.start(wrong,1,output))
        while(g.download.active) {
            val req=g.lastRequest();val b=ByteBuffer.wrap(req.payload).order(ByteOrder.LITTLE_ENDIAN)
            g.ack(req);g.download.data(g.data(file,b.getLong(8),b.getShort(16).toInt() and 65535))
        }
        assertTrue(output.aborted);assertFalse(output.finished)
    }
    @Test fun gapAndDuplicateConflictAreNotSilentlyAccepted() {
        val file=ByteArray(1024){it.toByte()};val f=Fixture();val sink=Sink()
        assertTrue(f.download.start(info(file),1,sink));f.download.data(f.data(file,1,480))
        assertTrue(sink.aborted);assertEquals(0,sink.bytes.size())
        val g=Fixture();val output=Sink();assertTrue(g.download.start(info(file),1,output))
        g.download.data(g.data(file,0,480));val changed=file.clone();changed[0]=42
        g.download.data(g.data(changed,0,480));assertTrue(output.aborted);assertFalse(output.finished)
    }
    @Test fun disconnectAbortsPartialAndNewDownloadStartsAtZero() {
        val file=ByteArray(1024);val f=Fixture();val sink=Sink();assertTrue(f.download.start(info(file),1,sink))
        f.download.data(f.data(file,0,480));f.client.disconnected();f.download.disconnected()
        assertTrue(sink.aborted);assertFalse(f.download.active)
        f.client.ready(ByteArray(16){(it+10).toByte()});val next=Sink()
        assertTrue(f.download.start(info(file),1,next));assertEquals(0,f.download.received)
        f.download.data(f.data(file,0,480));assertEquals(0,next.bytes.size())
    }
    @Test fun threeSeedsThreeThousandFragmentedNotifications() {
        var messages=0;var fragments=0
        for(seed in listOf(111,222,333)) {
            val random=Random(seed.toLong());val assembler=S9NotificationAssembler()
            for(i in 0 until 1000) {
                val n=1+random.nextInt(480);val bytes=ByteArray(n);random.nextBytes(bytes)
                val payload=ByteBuffer.allocate(32+n).order(ByteOrder.LITTLE_ENDIAN)
                    .putLong(99).putLong(i.toLong()*480).putLong(480000).putInt(crc(bytes).toInt())
                    .put(1).put(0).putShort(0).put(bytes).array()
                val message=S9Message(3,129,sid,(i+1).toLong(),payload)
                val pieces=S9Protocol.fragments(message,if(i%2==0)23 else 247)
                var got:S9Message?=null
                for(piece in pieces){got=assembler.push(piece,1000L+i*100);fragments++}
                assertNotNull(got);assertArrayEquals(payload,got!!.payload);messages++
            }
            assertEquals(0,assembler.discarded)
        }
        println("S11_APP_STATS messages=$messages fragments=$fragments seeds=3")
        assertEquals(3000,messages);assertTrue(fragments>=3000)
    }
    @org.junit.Test fun recordingIdsNeverReuseAfterRemoteStatusOrUnsignedBoundary() {
        val ids=S11RecordingIds(10)
        org.junit.Assert.assertEquals(11L,ids.next())
        ids.observeRemote(5);org.junit.Assert.assertEquals(12L,ids.next())
        ids.observeRemote(1000);org.junit.Assert.assertEquals(1001L,ids.next())
        ids.observeRemote(Long.MAX_VALUE);org.junit.Assert.assertEquals(Long.MIN_VALUE,ids.next())
        ids.observeRemote(-2L);org.junit.Assert.assertEquals(-1L,ids.next())
        try {ids.next();org.junit.Assert.fail("record ID wrapped") } catch(_:IllegalArgumentException) {}
    }
}
