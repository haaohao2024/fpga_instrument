import SwiftUI

/// Panel colors for the stage. The instrument panel is deliberately dark in
/// both system themes, like the front of an electronic keyboard.
enum Panel {
    static let ground=Color(red:0.086,green:0.094,blue:0.114)
    static let raised=Color(red:0.125,green:0.137,blue:0.165)
    static let text=Color(red:0.925,green:0.933,blue:0.949)
    static let muted=Color(red:0.545,green:0.573,blue:0.62)
    static let ledOn=Color(red:1.0,green:0.71,blue:0.28)
    static let ledRec=Color(red:1.0,green:0.30,blue:0.30)
    static let ledGo=Color(red:0.35,green:0.83,blue:0.54)
    static let lcdGround=Color(red:0.047,green:0.078,blue:0.063)
    static let lcdText=Color(red:0.62,green:0.89,blue:0.71)
}

extension View {
    /// Liquid Glass on iOS 26 (Xcode 26 SDK); translucent material otherwise.
    @ViewBuilder func panelSurface(cornerRadius: CGFloat=12, tint: Color?=nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)).interactive() } ?? Glass.regular.interactive(),
                             in: RoundedRectangle(cornerRadius:cornerRadius,style:.continuous))
        } else {
            classicSurface(cornerRadius:cornerRadius,tint:tint)
        }
        #else
        classicSurface(cornerRadius:cornerRadius,tint:tint)
        #endif
    }
    private func classicSurface(cornerRadius: CGFloat,tint: Color?) -> some View {
        self.background(
            RoundedRectangle(cornerRadius:cornerRadius,style:.continuous)
                .fill(tint.map { $0.opacity(0.28) } ?? Panel.raised.opacity(0.85))
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:cornerRadius,style:.continuous))
        )
        .overlay(RoundedRectangle(cornerRadius:cornerRadius,style:.continuous).stroke(Color.white.opacity(0.10),lineWidth:1))
    }
}

/// An electronic-keyboard style button: label plus an optional status LED.
struct PanelButton: View {
    let title: String
    var detail: String?=nil
    var led: Color?=nil
    var isOn=false
    var blinking=false
    var compact=false
    let action: ()->Void
    @State private var blinkPhase=false
    var body: some View {
        Button(action:action) {
            HStack(spacing:6) {
                if let led=led {
                    Circle().fill(isOn ? led : Color(white:0.24))
                        .frame(width:7,height:7)
                        .shadow(color:isOn ? led : .clear,radius:4)
                        .opacity(isOn && blinking && blinkPhase ? 0.25 : 1)
                }
                Text(title).font(.system(size:compact ? 12 : 13,weight:.medium)).lineLimit(1)
                if let detail=detail { Text(detail).font(.system(size:11,design:.monospaced)).foregroundColor(Panel.muted).lineLimit(1) }
            }
            .foregroundColor(Panel.text)
            .padding(.horizontal,compact ? 9 : 11).padding(.vertical,compact ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panelSurface(cornerRadius:compact ? 10 : 12,tint:isOn && led == nil ? Panel.ledOn : nil)
        .onReceive(Timer.publish(every:0.5,on:.main,in:.common).autoconnect()) { _ in if blinking { blinkPhase.toggle() } }
    }
}

/// A labeled horizontal slider sized for the panel.
struct PanelSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double=1
    var format: (Double)->String={ "\(Int($0))" }
    var width: CGFloat=96
    var onCommit: ()->Void={}
    var body: some View {
        HStack(spacing:6) {
            Text(title).font(.system(size:12)).foregroundColor(Panel.muted)
            Slider(value:$value,in:range,step:step,onEditingChanged:{ editing in if !editing { onCommit() } })
                .frame(width:width).tint(Panel.ledOn)
            Text(format(value)).font(.system(size:11,design:.monospaced)).foregroundColor(Panel.text).frame(minWidth:26,alignment:.leading)
        }
    }
}

struct PanelGroup<Content: View>: View {
    let title: String
    var showTitle=true
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if showTitle { Text(title).font(.system(size:10,weight:.medium)).tracking(1.2).foregroundColor(Panel.muted) }
            HStack(spacing:6) { content }
        }
    }
}
