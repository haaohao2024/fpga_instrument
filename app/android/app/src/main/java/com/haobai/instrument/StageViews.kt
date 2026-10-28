package com.haobai.instrument

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** Stage palette: a dark instrument panel in every system theme (Material tonal style). */
object StagePalette {
    const val GROUND=0xff16181d.toInt()
    const val RAISED=0xff2b2f3a.toInt()
    const val RAISED_ON=0xff3f4a7a.toInt()
    const val TEXT=0xffeceef2.toInt()
    const val MUTED=0xff8b929e.toInt()
    const val LED_ON=0xffffb547.toInt()
    const val LED_REC=0xffff4d4d.toInt()
    const val LED_GO=0xff5ad38a.toInt()
    const val LCD=0xff0c1410.toInt()
    const val LCD_TEXT=0xffc9ffd9.toInt()
}

/** Keyboard range C1..C7 (MIDI 24..96); white keys are the layout columns. */
object KeyRange {
    const val LOW=24
    const val HIGH=96
    val whites:List<Int> = (LOW..HIGH).filter{!isBlack(it)}
    fun isBlack(n:Int)=n%12 in intArrayOf(1,3,6,8,10)
    fun whiteIndex(n:Int)=whites.indexOf(if(isBlack(n))n-1 else n).coerceAtLeast(0)
    fun name(n:Int)=listOf("C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B")[n%12]+(n/12-1)
    fun clampStart(index:Int,visible:Int)=max(0,min(index,whites.size-visible))
}

fun Context.dp(v:Float)=TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP,v,resources.displayMetrics)

/** Electronic-keyboard style toggle: a status dot (LED) and a label on a tonal surface. */
class PanelButton(context:Context,label:String,private val led:Int?=null,private val blink:Boolean=false,action:()->Unit):TextView(context) {
    var on=false; set(value){field=value;refresh()}
    var label=label; set(value){field=value;refresh()}
    private val shape=GradientDrawable().apply {cornerRadius=context.dp(12f)}
    private val ticker=object:Runnable{override fun run(){if(on&&blink)refresh();postDelayed(this,500)}}
    init {
        background=shape;setTextColor(StagePalette.TEXT);textSize=13f;gravity=Gravity.CENTER_VERTICAL
        val h=context.dp(10f).toInt();val v=context.dp(7f).toInt();setPadding(h,v,h,v)
        isAllCaps=false;setSingleLine(true)
        setOnClickListener{if(isEnabled)action()}
        refresh()
    }
    override fun onAttachedToWindow(){super.onAttachedToWindow();if(blink)post(ticker)}
    override fun onDetachedFromWindow(){removeCallbacks(ticker);super.onDetachedFromWindow()}
    override fun setEnabled(enabled:Boolean){super.setEnabled(enabled);alpha=if(enabled)1f else 0.4f}
    private fun refresh() {
        shape.setColor(if(on&&led==null)StagePalette.RAISED_ON else StagePalette.RAISED)
        if(led==null){text=label;return}
        val dim=blink&&on&&(SystemClock.uptimeMillis()/500)%2L==1L
        val color=if(on&&!dim)led else 0xff3a3e47.toInt()
        val s=android.text.SpannableString("● $label")
        s.setSpan(android.text.style.ForegroundColorSpan(color),0,1,0)
        text=s
    }
}

/** Title above a row of panel controls. */
fun Context.panelGroup(title:String,showTitle:Boolean,vararg children:View):LinearLayout = LinearLayout(this).apply {
    orientation=LinearLayout.VERTICAL
    if(showTitle)addView(TextView(context).apply{text=title;textSize=10f;letterSpacing=0.12f;setTextColor(StagePalette.MUTED)})
    addView(LinearLayout(context).apply {
        orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL
        children.forEach {addView(it,LinearLayout.LayoutParams(-2,-2).apply{marginEnd=context.dp(6f).toInt()})}
    })
}

/** Labeled slider; `commit` fires when the finger lifts. */
fun Context.panelSlider(title:String,max:Int,value:Int,widthDp:Float,format:(Int)->String,commit:(Int)->Unit):LinearLayout = LinearLayout(this).apply {
    orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL
    addView(TextView(context).apply{text=title;textSize=12f;setTextColor(StagePalette.MUTED)})
    val readout=TextView(context).apply{text=format(value);textSize=11f;typeface=Typeface.MONOSPACE;setTextColor(StagePalette.TEXT);minWidth=context.dp(30f).toInt()}
    addView(SeekBar(context).apply {
        this.max=max;progress=value
        progressTintList=android.content.res.ColorStateList.valueOf(StagePalette.LED_ON)
        thumbTintList=android.content.res.ColorStateList.valueOf(StagePalette.LED_ON)
        setOnSeekBarChangeListener(object:SeekBar.OnSeekBarChangeListener{
            override fun onProgressChanged(s:SeekBar?,p:Int,user:Boolean){readout.text=format(p)}
            override fun onStartTrackingTouch(s:SeekBar?){}
            override fun onStopTrackingTouch(s:SeekBar?){commit(s?.progress?:0)}
        })
    },LinearLayout.LayoutParams(context.dp(widthDp).toInt(),-2))
    addView(readout)
}

/** Multi-touch piano. Touches only play; moving off a key releases it.
 * The visible window moves with the overview strip or octave buttons. */
class PianoStageView(context:Context,private val down:(Int)->Boolean,private val up:(Int)->Unit):View(context) {
    var startWhite=KeyRange.whiteIndex(48); set(v){if(v!=field){touches.cancel();field=v;invalidate()}}
    var visibleWhites=14; set(v){if(v!=field){touches.cancel();field=v;invalidate()}}
    var enabledForPlay=false; set(v){field=v;if(!v)touches.cancel();invalidate()}
    var guideNote:Int?=null; set(v){field=v;invalidate()}
    var litNotes:Set<Int> = emptySet(); set(v){field=v;invalidate()}
    private val pressed=HashSet<Int>()
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG)
    private val touches=S9TouchKeys({n->down(n).also{if(it){pressed.add(n);invalidate()}}},{n->pressed.remove(n);up(n);invalidate()})
    fun cancel()=touches.cancel()
    private val whiteW get()=width/visibleWhites.toFloat()
    private fun rect(n:Int):RectF {
        val x=(KeyRange.whiteIndex(n)-startWhite)*whiteW
        return if(KeyRange.isBlack(n)){val w=whiteW*0.6f;RectF(x+whiteW-w/2,0f,x+whiteW+w/2,height*0.62f)} else RectF(x,0f,x+whiteW,height.toFloat())
    }
    private fun visible():IntRange {
        val lo=KeyRange.whites[min(startWhite,KeyRange.whites.size-1)]
        val hi=KeyRange.whites[min(startWhite+visibleWhites-1,KeyRange.whites.size-1)]
        return max(KeyRange.LOW,lo-1)..min(KeyRange.HIGH,hi+1)
    }
    private fun noteAt(x:Float,y:Float):Int {
        if(x<0||y<0||x>=width||y>=height)return -1
        visible().filter(KeyRange::isBlack).firstOrNull{rect(it).contains(x,y)}?.let{return it}
        return visible().filterNot(KeyRange::isBlack).firstOrNull{rect(it).contains(x,y)}?:-1
    }
    override fun onDraw(c:Canvas) {
        c.drawColor(Color.BLACK)
        val held=pressed+litNotes
        val dim=255  // keys stay opaque; the disabled look is one overlay drawn last
        val pulse=((sin(SystemClock.uptimeMillis()*2*Math.PI/800)+1)/2).toFloat()
        val r=context.dp(6f)
        for(n in visible().filterNot(KeyRange::isBlack)) {
            val k=rect(n).apply{inset(0.5f,0f)}
            paint.color=when{n in held->0xffc2c2bd.toInt();n==guideNote->Color.rgb(255,(217-25*pulse).toInt(),(138-50*pulse).toInt());else->0xfff7f7f5.toInt()}
            paint.alpha=dim;c.drawRoundRect(k,r,r,paint);c.drawRect(k.left,k.top,k.right,k.bottom-r,paint)
            if(n%12==0){paint.color=0xff3a3a36.toInt();paint.alpha=dim;paint.textSize=context.dp(11f);paint.typeface=Typeface.MONOSPACE;c.drawText(KeyRange.name(n),k.left+context.dp(4f),k.bottom-context.dp(8f),paint)}
        }
        for(n in visible().filter(KeyRange::isBlack)) {
            val k=rect(n)
            paint.color=when{n in held->0xff4d4f57.toInt();n==guideNote->Color.rgb((184-38*pulse).toInt(),(134-25*pulse).toInt(),47);else->0xff1a1b1f.toInt()}
            paint.alpha=dim;c.drawRoundRect(k,r*0.7f,r*0.7f,paint);c.drawRect(k.left,k.top,k.right,k.bottom-r,paint)
        }
        if(!enabledForPlay){paint.color=Color.BLACK;paint.alpha=110;c.drawRect(0f,0f,width.toFloat(),height.toFloat(),paint)}
        if(guideNote!=null)postInvalidateDelayed(33)
    }
    override fun onTouchEvent(e:MotionEvent):Boolean {
        parent.requestDisallowInterceptTouchEvent(true)
        if(!enabledForPlay)return true
        when(e.actionMasked) {
            MotionEvent.ACTION_DOWN,MotionEvent.ACTION_POINTER_DOWN->{val i=e.actionIndex;touches.press(e.getPointerId(i),noteAt(e.getX(i),e.getY(i)))}
            MotionEvent.ACTION_MOVE->for(i in 0 until e.pointerCount)touches.move(e.getPointerId(i),noteAt(e.getX(i),e.getY(i)))
            MotionEvent.ACTION_UP,MotionEvent.ACTION_POINTER_UP->touches.release(e.getPointerId(e.actionIndex))
            MotionEvent.ACTION_CANCEL->cancel()
        }
        return true
    }
}

/** Whole-range overview; dragging moves the visible window. */
class KeyboardOverviewView(context:Context,private val moved:(Int)->Unit):View(context) {
    var startWhite=0; set(v){field=v;invalidate()}
    var visibleWhites=14; set(v){field=v;invalidate()}
    var guideNote:Int?=null; set(v){field=v;invalidate()}
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG)
    override fun onDraw(c:Canvas) {
        val per=width/KeyRange.whites.size.toFloat();val r=context.dp(8f)
        paint.style=Paint.Style.FILL;paint.color=0xff0e1014.toInt();c.drawRoundRect(0f,0f,width.toFloat(),height.toFloat(),r,r,paint)
        paint.color=0xffd8d8d2.toInt()
        for(i in KeyRange.whites.indices)c.drawRect(i*per+0.5f,4f,(i+1)*per-0.5f,height-4f,paint)
        paint.color=0xff1b1d22.toInt()
        for(n in KeyRange.LOW..KeyRange.HIGH)if(KeyRange.isBlack(n)){val x=(KeyRange.whiteIndex(n)+1)*per;c.drawRect(x-per*0.3f,4f,x+per*0.3f,4f+(height-8f)*0.6f,paint)}
        paint.color=StagePalette.LED_ON;paint.alpha=40
        val win=RectF(startWhite*per,1f,(startWhite+visibleWhites)*per,height-1f)
        c.drawRoundRect(win,context.dp(5f),context.dp(5f),paint)
        paint.alpha=255;paint.style=Paint.Style.STROKE;paint.strokeWidth=context.dp(2f);c.drawRoundRect(win,context.dp(5f),context.dp(5f),paint)
        guideNote?.let{n->paint.style=Paint.Style.FILL;val x=(KeyRange.whiteIndex(n)+if(KeyRange.isBlack(n))1f else 0.5f)*per;c.drawCircle(x,context.dp(5f),context.dp(3f),paint)}
    }
    override fun onTouchEvent(e:MotionEvent):Boolean {
        parent.requestDisallowInterceptTouchEvent(true)
        if(e.actionMasked==MotionEvent.ACTION_DOWN||e.actionMasked==MotionEvent.ACTION_MOVE) {
            val per=width/KeyRange.whites.size.toFloat()
            moved(KeyRange.clampStart((e.x/per).roundToInt()-visibleWhites/2,visibleWhites))
        }
        return true
    }
}
