package com.haobai.instrument

import org.junit.Assert.*
import org.junit.Test

class S9RequestRulesTest {
    private fun raw(s:String)=s.chunked(2).map{it.toInt(16).toByte()}.toByteArray()
    @Test fun independentSharedSpecificationBoundaries() {
        val lines=javaClass.classLoader!!.getResourceAsStream("semantic_ranges.tsv")!!.bufferedReader().readLines().drop(1)
        assertEquals(1062,lines.size)
        lines.forEachIndexed {index,line ->
            val p=line.split('\t');val message=S9Protocol.decode(raw(p[1]))
            assertEquals("Vector $index",p[0].toInt(),S9RequestRules.error(message))
        }
    }
    @Test fun allGoldenRequestsIncludingFileCommands() {
        val lines=javaClass.classLoader!!.getResourceAsStream("golden_messages.tsv")!!.bufferedReader().readLines().drop(1)
        assertEquals(21,lines.size)
        lines.forEach {line ->assertEquals(0,S9RequestRules.error(S9Protocol.decode(raw(line.split('\t')[4]))))}
    }
}
