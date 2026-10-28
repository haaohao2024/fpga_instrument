package com.haobai.instrument

/** Bounded local timing metadata. It never logs payload, identity, address or keys. */
class S9GattTrace(private val clock:()->Long) {
    private val lines=ArrayDeque<String>()
    private var origin=clock()
    private var active="none"
    private var since=0L
    fun mark(kind:String,detail:String="") {
        if(lines.size==1024)lines.removeFirst()
        lines.addLast("${clock()-origin}ms $kind $detail".trimEnd())
    }
    fun begin(kind:String){active=kind;since=clock();mark("operation_start",kind)}
    fun end(status:Int){mark("operation_callback","$active status=$status elapsed=${clock()-since}ms");active="none"}
    fun pending()="$active elapsed=${if(active=="none")0L else clock()-since}ms"
    fun snapshot()="GATT timing metadata; no packet contents or keys\n"+lines.joinToString("\n")
}
