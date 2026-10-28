import Foundation

/// Uses ordinary phone-note identities; never sends PCM or writes oscillator state.
public final class SpectrumTest {
    public static let sizes = [1, 8, 16, 32, 48]
    public enum State: Equatable {
        case idle, preparing(Int), submitted(Int)
    }
    public private(set) var state: State = .idle
    public var changed: ((State)->Void)?
    private let client: ClientSession
    private var generation = 0
    private var native48 = false
    public init(client: ClientSession) { self.client = client }
    public static func notes(_ count: Int) -> [Int] { sizes.contains(count) ? Array(48..<(48+count)) : [] }
    public static func frequency(_ note: Int) -> Double { 440 * pow(2, Double(note-69)/12) }
    public static func nativeCommand(_ count: Int) throws -> [UInt8] {
        try require(count == 0 || sizes.contains(count), "测试路数无效")
        return [count == 0 ? 2 : 1, UInt8(count), 0, 0, 0, 0, 0, 0]
    }
    private func update(_ value: State) { state=value;changed?(value) }
    public func stop() {
        generation += 1;client.releaseAll()
        if native48 {
            _=client.command(opcode:86,payload:try! Self.nativeCommand(0),label:"停止48路测试",target:4)
        }
        native48=false;update(.idle)
    }
    public func disconnected() { generation += 1;native48=false;update(.idle) }
    @discardableResult public func start(_ count: Int) -> Bool {
        guard state == .idle, Self.sizes.contains(count), client.connected, client.pitchReady else { return false }
        generation += 1;let token=generation
        client.releaseAll();update(.preparing(count))
        // Bypass effects so harmonics/modulation do not masquerade as oscillators.
        let effects = try! Commands.effects([8,11520,12288,576,192,71583,24576,16384,6144,4096,4096])
        let ticket=client.command(opcode:35,payload:effects,label:"测试：旁路效果器",target:4,completed:{[weak self] _ in
            guard let self=self, self.generation==token else { return }
            let p=try! Commands.event(id:0,kind:4,key:255,note:0,value:0)
            let vibrato=self.client.command(channel:0,opcode:16,payload:p,label:"测试：关闭颤音",target:3,completed:{[weak self] _ in
                guard let self=self, self.generation==token else { return }
                if !self.client.pitchParameter(opcode:32,value:0,completed:{[weak self] _ in
                    guard let self=self, self.generation==token else { return }
                    if count==48 {
                        self.native48=true
                        let ticket=self.client.command(opcode:86,payload:try! Self.nativeCommand(48),label:"启动48路测试",target:4,completed:{[weak self] _ in
                            guard let self=self, self.generation==token else { return }
                            self.update(.submitted(48))
                        },rejected:{[weak self] _ in if self?.generation==token { self?.stop() }})
                        if ticket==nil { self.stop() }
                        return
                    }
                    var confirmed=0
                    for (key,note) in Self.notes(count).enumerated() {
                        let accepted=self.client.press(key:key,note:note,pressure:96,completed:{[weak self] _ in
                            guard let self=self, self.generation==token else { return }
                            confirmed += 1
                            if confirmed==count { self.update(.submitted(count)) }
                        })
                        if !accepted { self.stop();return }
                    }
                }) { self.stop() }
            },rejected:{[weak self] _ in if self?.generation==token { self?.stop() }})
            if vibrato==nil { self.stop() }
        },rejected:{[weak self] _ in if self?.generation==token { self?.stop() }})
        if ticket==nil { stop();return false }
        return true
    }
}
