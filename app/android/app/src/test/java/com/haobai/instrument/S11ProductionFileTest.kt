package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Actual production C/FatFs file notifications are supplied by the host
 * evidence runner. This is a client test, not a radio or live SD claim. */
class S11ProductionFileTest {
    private class Output:S11Download.Sink {
        val bytes=ByteArrayOutputStream();var finished=false;var aborted=false
        override fun write(bytes:ByteArray){this.bytes.write(bytes)}
        override fun finish(){finished=true}
        override fun abort(){aborted=true}
    }
    @Test fun actualCNotificationsSavedFileAndClientDownload() {
        val roots=System.getenv("S11_C_TRACE_ROOTS")?.split(File.pathSeparator)?.filter{it.isNotBlank()}
        assumeTrue("production C traces are supplied by the Stage11 final runner",!roots.isNullOrEmpty())
        var messages=0;var fragments=0;var files=0;var rejected=0
        for(root in roots!!) {
            val folder=File(root);val assembler=S9NotificationAssembler();val decoded=ArrayList<S9Message>()
            fun hex(s:String)=s.chunked(2).map{it.toInt(16).toByte()}.toByteArray()
            for(line in File(folder,"notifications_fragments.hex").readLines().filter{it.isNotBlank()}) {
                assembler.push(hex(line.trim()),1000L+fragments)?.let{decoded.add(it)};fragments++
            }
            assertEquals(0,assembler.discarded);assertTrue(decoded.isNotEmpty());messages+=decoded.size
            val first=decoded.first();val info=S11RecordInfo.decode(first);val sid=first.session
            val sent=ArrayList<S9Message>();var now=1000L
            val client=S9ClientSession({sent.add(it);true},{throw AssertionError(it)},{},{now})
            client.ready(sid)
            val download=S11Download(client,{},{now})
            fun ack(request:S9Message) {
                // Independent public RESULT contract; C DATA and INFO bytes
                // are replayed unchanged. RF command round trips are not tested.
                val p=ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN)
                p.putInt(request.sequence.toInt()).put(request.channel.toByte()).put(3).putShort(0)
                    .putInt(0).putInt(0).putLong(0).putShort(0).putShort(0).putInt(0).putInt(0)
                client.result(S9Message(3,128,sid,9000,p.array()))
            }
            for(kind in 1..2) {
                if(info.mask and kind==0)continue
                val sink=Output()
                if(!info.downloadable(kind)) {
                    assertFalse(download.start(info,kind,sink));assertTrue(sink.aborted);rejected++;continue
                }
                assertTrue(download.start(info,kind,sink))
                val blocks=decoded.drop(1).filter{it.opcode==129 && (it.payload[28].toInt() and 255)==kind}
                assertTrue(blocks.isNotEmpty())
                for((index,data) in blocks.withIndex()) {
                    val request=sent.last{it.opcode==83};val b=ByteBuffer.wrap(request.payload).order(ByteOrder.LITTLE_ENDIAN)
                    assertEquals(info.id,b.getLong(0));assertEquals(download.received,b.getLong(8))
                    if(index%2==0){download.data(data);download.data(data);ack(request)}
                    else {ack(request);download.data(data)}
                    now++
                }
                assertFalse(download.active);assertTrue(sink.finished);assertFalse(sink.aborted)
                val saved=File(folder,if(kind==1)"capture.wav" else "capture.evr").readBytes()
                assertArrayEquals(saved,sink.bytes.toByteArray());assertEquals(info.bytes(kind),download.received)
                files++
            }
        }
        assertTrue(files>=1)
        println("S11_C_FILE_STATS roots=${roots.size} messages=$messages fragments=$fragments downloaded_files=$files incomplete_rejections=$rejected")
    }
}
