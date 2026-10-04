package com.haobai.instrument

/** Pointer ownership is separate from note identity. A pointer moving outside its
 * key releases it; two pointers never create ambiguous owners of the same key. */
class S9TouchKeys(private val down:(Int)->Boolean,private val up:(Int)->Unit) {
    private val pointers=HashMap<Int,Int>()
    fun press(pointer:Int,key:Int) {
        release(pointer)
        if(key>=0 && key !in pointers.values && down(key))pointers[pointer]=key
    }
    fun move(pointer:Int,key:Int) {if(pointers[pointer]!=key)release(pointer)}
    fun release(pointer:Int) {pointers.remove(pointer)?.let(up)}
    fun cancel() {pointers.keys.toList().forEach(::release)}
}
