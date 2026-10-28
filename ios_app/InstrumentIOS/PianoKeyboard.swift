import SwiftUI
import UIKit

/// Keyboard geometry shared by the playing surface and the overview strip.
/// Range C1..C7 (MIDI 24..96); only white keys count as layout columns.
struct KeyLayout {
    static let low=24, high=96
    static let whites: [Int]=(low...high).filter{ !isBlack($0) }
    static func isBlack(_ n: Int) -> Bool { [1,3,6,8,10].contains(n%12) }
    static func whiteIndex(_ n: Int) -> Int { whites.firstIndex(of:isBlack(n) ? n-1 : n) ?? 0 }
    static func name(_ n: Int) -> String { ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"][n%12]+"\(n/12-1)" }
    /// First visible white key, clamped so the window stays inside the range.
    static func clampStart(_ whiteIndex: Int,visibleWhites: Int) -> Int { max(0,min(whiteIndex,whites.count-visibleWhites)) }
}

/// Multi-touch keyboard. Touches only play; moving off a key releases it.
/// Scrolling is done by the overview strip or octave buttons, never by dragging keys.
struct PianoKeyboard: UIViewRepresentable {
    var startWhite: Int
    var visibleWhites: Int
    var enabled: Bool
    var guideNote: Int?
    var litNotes: Set<Int>
    var down: (Int)->Bool
    var up: (Int)->Void
    func makeUIView(context: Context) -> PianoSurface { let v=PianoSurface();v.isMultipleTouchEnabled=true;v.isOpaque=true;return v }
    func updateUIView(_ v: PianoSurface,context: Context) {
        v.down=down;v.up=up
        if v.startWhite != startWhite || v.visibleWhites != visibleWhites { v.releaseAll() }
        v.startWhite=startWhite;v.visibleWhites=visibleWhites;v.enabled=enabled;v.guideNote=guideNote;v.litNotes=litNotes
        v.setNeedsDisplay()
    }
    static func dismantleUIView(_ v: PianoSurface,coordinator: Void) { v.releaseAll() }
}

final class PianoSurface: UIView {
    var down: ((Int)->Bool)?, up: ((Int)->Void)?
    var startWhite=0, visibleWhites=14
    var enabled=false { didSet { if !enabled && oldValue { releaseAll() } } }
    var guideNote: Int?=nil { didSet { if guideNote != oldValue { updatePulse() } } }
    /// Notes shown as held by something other than this surface (physical keys, score playback).
    var litNotes: Set<Int>=[]
    private var held: [ObjectIdentifier:Int]=[:]
    private var pulse: CADisplayLink?
    private var pulsePhase: CGFloat=0

    private var whiteWidth: CGFloat { bounds.width/CGFloat(max(visibleWhites,1)) }
    private func rect(_ n: Int) -> CGRect {
        let x=CGFloat(KeyLayout.whiteIndex(n)-startWhite)*whiteWidth
        if KeyLayout.isBlack(n) { let w=whiteWidth*0.6;return CGRect(x:x+whiteWidth-w/2,y:0,width:w,height:bounds.height*0.62) }
        return CGRect(x:x,y:0,width:whiteWidth,height:bounds.height)
    }
    private var visibleNotes: [Int] {
        let lo=KeyLayout.whites[min(startWhite,KeyLayout.whites.count-1)]
        let hi=KeyLayout.whites[min(startWhite+visibleWhites-1,KeyLayout.whites.count-1)]
        return Array(max(KeyLayout.low,lo-1)...min(KeyLayout.high,hi+1))
    }
    private func note(at p: CGPoint) -> Int? {
        guard bounds.contains(p) else { return nil }
        for n in visibleNotes where KeyLayout.isBlack(n) { if rect(n).contains(p) { return n } }
        for n in visibleNotes where !KeyLayout.isBlack(n) { if rect(n).contains(p) { return n } }
        return nil
    }
    func releaseAll() { let notes=Array(held.values);held=[:];notes.forEach{ up?($0) };setNeedsDisplay() }

    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard enabled else { return }
        for t in touches {
            if let n=note(at:t.location(in:self)), !held.values.contains(n), down?(n)==true { held[ObjectIdentifier(t)]=n }
        }
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>,with event: UIEvent?) {
        for t in touches {
            let id=ObjectIdentifier(t)
            if let n=held[id], note(at:t.location(in:self)) != n { held.removeValue(forKey:id);up?(n) }
        }
        setNeedsDisplay()
    }
    private func ended(_ touches: Set<UITouch>) { for t in touches { if let n=held.removeValue(forKey:ObjectIdentifier(t)) { up?(n) } };setNeedsDisplay() }
    override func touchesEnded(_ touches: Set<UITouch>,with event: UIEvent?) { ended(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>,with event: UIEvent?) { ended(touches) }

    private func updatePulse() {
        if guideNote != nil && pulse == nil {
            let link=CADisplayLink(target:self,selector:#selector(step(_:)));link.preferredFramesPerSecond=30;link.add(to:.main,forMode:.common);pulse=link
        } else if guideNote == nil { pulse?.invalidate();pulse=nil }
        setNeedsDisplay()
    }
    @objc private func step(_ link: CADisplayLink) { pulsePhase=CGFloat((sin(link.timestamp*2*Double.pi/0.8)+1)/2);setNeedsDisplay() }
    override func removeFromSuperview() { pulse?.invalidate();pulse=nil;super.removeFromSuperview() }

    override func draw(_ dirty: CGRect) {
        guard let c=UIGraphicsGetCurrentContext() else { return }
        c.setFillColor(UIColor.black.cgColor);c.fill(bounds)
        let pressed=Set(held.values).union(litNotes)
        let dim: CGFloat=enabled ? 1 : 0.55
        for n in visibleNotes where !KeyLayout.isBlack(n) {
            let r=rect(n).insetBy(dx:0.5,dy:0)
            var color=UIColor(red:0.97,green:0.97,blue:0.96,alpha:1)
            if n==guideNote { color=UIColor(red:1,green:0.85-0.1*pulsePhase,blue:0.54-0.2*pulsePhase,alpha:1) }
            // Pressed: the key's own color under a gray filter.
            if pressed.contains(n) { color=UIColor(red:0.76,green:0.76,blue:0.74,alpha:1) }
            c.setFillColor(color.withAlphaComponent(dim).cgColor)
            c.addPath(UIBezierPath(roundedRect:r,byRoundingCorners:[.bottomLeft,.bottomRight],cornerRadii:CGSize(width:6,height:6)).cgPath);c.fillPath()
            if n%12==0 {
                (KeyLayout.name(n) as NSString).draw(at:CGPoint(x:r.minX+4,y:r.maxY-20),
                    withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:11,weight:.semibold),.foregroundColor:UIColor(white:0.25,alpha:1)])
            }
        }
        for n in visibleNotes where KeyLayout.isBlack(n) {
            let r=rect(n)
            var color=UIColor(red:0.10,green:0.105,blue:0.12,alpha:1)
            if n==guideNote { color=UIColor(red:0.72-0.15*pulsePhase,green:0.53-0.1*pulsePhase,blue:0.18,alpha:1) }
            if pressed.contains(n) { color=UIColor(red:0.30,green:0.31,blue:0.34,alpha:1) }
            c.setFillColor(color.withAlphaComponent(dim).cgColor)
            c.addPath(UIBezierPath(roundedRect:r,byRoundingCorners:[.bottomLeft,.bottomRight],cornerRadii:CGSize(width:4,height:4)).cgPath);c.fillPath()
        }
    }
}

/// Overview of the whole C1..C7 range; dragging moves the visible window.
struct KeyboardOverview: View {
    @Binding var startWhite: Int
    let visibleWhites: Int
    var guideNote: Int?
    var body: some View {
        GeometryReader { g in
            let per=g.size.width/CGFloat(KeyLayout.whites.count)
            ZStack(alignment:.topLeading) {
                Canvas { ctx,size in
                    for i in 0..<KeyLayout.whites.count {
                        ctx.fill(Path(CGRect(x:CGFloat(i)*per+0.5,y:4,width:per-1,height:size.height-8)),with:.color(Color(white:0.85)))
                    }
                    for n in KeyLayout.low...KeyLayout.high where KeyLayout.isBlack(n) {
                        let x=CGFloat(KeyLayout.whiteIndex(n)+1)*per-per*0.3
                        ctx.fill(Path(CGRect(x:x,y:4,width:per*0.6,height:(size.height-8)*0.6)),with:.color(Color(white:0.11)))
                    }
                }
                RoundedRectangle(cornerRadius:5).stroke(Panel.ledOn,lineWidth:2)
                    .background(RoundedRectangle(cornerRadius:5).fill(Panel.ledOn.opacity(0.12)))
                    .frame(width:per*CGFloat(visibleWhites),height:g.size.height-2)
                    .offset(x:per*CGFloat(startWhite),y:1)
                if let n=guideNote {
                    Circle().fill(Panel.ledOn).frame(width:6,height:6).shadow(color:Panel.ledOn,radius:3)
                        .offset(x:per*(CGFloat(KeyLayout.whiteIndex(n))+(KeyLayout.isBlack(n) ? 1 : 0.5))-3,y:3)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { v in
                let center=Int((v.location.x/per).rounded())-visibleWhites/2
                startWhite=KeyLayout.clampStart(center,visibleWhites:visibleWhites)
            })
        }
        .background(RoundedRectangle(cornerRadius:8).fill(Color(red:0.055,green:0.063,blue:0.078)))
        .clipShape(RoundedRectangle(cornerRadius:8))
        .accessibilityLabel("全键盘缩略条，拖动选择显示范围")
    }
}
