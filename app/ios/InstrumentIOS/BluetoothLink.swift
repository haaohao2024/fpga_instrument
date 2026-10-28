import Foundation
import Combine
import CoreBluetooth
import InstrumentCore

final class BluetoothLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device: Identifiable { let id: UUID;let name: String;let rssi: Int;let peripheral: CBPeripheral }
    @Published private(set) var devices: [Device]=[]
    @Published private(set) var status="打开蓝牙后扫描乐器"
    @Published private(set) var scanning=false
    @Published private(set) var ready=false
    var onReady: (([UInt8])->Void)?, onMessage: ((Message)->Void)?, onDisconnected: (()->Void)?
    private var central: CBCentralManager!
    private var active: CBPeripheral?, chars: [CBUUID:CBCharacteristic]=[:]
    private var closing=false, subscribed=false, pendingRead=false
    private var session: [UInt8]?, lastNotice: UInt32=0, generation=0, scanGeneration=0, operation=0
    private var connectedAt: UInt64=0, busy: CBUUID?
    private let writer=WriteScheduler(), assembler=NotificationAssembler()
    private var trace: [String]=[]
    private let service=CBUUID(string:ProtocolID.service), info=CBUUID(string:ProtocolID.info), notice=CBUUID(string:ProtocolID.status)
    private let channels=ProtocolID.channels.map{CBUUID(string:$0)}
    static var now: UInt64 { UInt64(ProcessInfo.processInfo.systemUptime*1000) }
    override init() { super.init();central=CBCentralManager(delegate:self,queue:.main) }
    func diagnostics() -> String { "FPGA iOS R88 · iOS 15兼容\n"+trace.joined(separator:"\n") }
    private func mark(_ text: String) { trace.append("\(Self.now) \(text)");if trace.count>200 { trace.removeFirst(trace.count-200) } }
    private func later(_ ms: Int, _ action: @escaping ()->Void) {
        let g=generation;DispatchQueue.main.asyncAfter(deadline:.now()+Double(ms)/1000){[weak self] in guard let self=self,self.generation==g else{return};action()}
    }
    func scan() {
        guard central.state == .poweredOn else { status="请开启手机蓝牙并允许本App访问蓝牙";return }
        stopScan();devices=[];scanning=true;let token=scanGeneration
        status="正在扫描乐器";central.scanForPeripherals(withServices:[service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        DispatchQueue.main.asyncAfter(deadline:.now()+10){[weak self] in
            guard let self=self,self.scanning,self.scanGeneration==token else{return}
            self.stopScan();if self.active==nil { self.status=self.devices.isEmpty ? "扫描结束，未发现乐器" : "请选择下方设备连接" }
        }
    }
    func stopScan() { scanGeneration+=1;scanning=false;central.stopScan() }
    func connect(_ device: Device) {
        guard active==nil else { status="请先断开当前设备，等待断开完成";return }
        stopScan();generation+=1;closing=false;active=device.peripheral;device.peripheral.delegate=self
        chars=[:];session=nil;ready=false;subscribed=false;busy=nil;pendingRead=false;lastNotice=0;writer.clear();assembler.reset()
        connectedAt=Self.now;status="正在连接并建立加密会话";mark("connect")
        central.connect(device.peripheral,options:nil)
        later(20000){[weak self] in if let self=self,!self.ready { self.disconnect("连接或初始化超时，请重试") } }
    }
    func disconnect(_ reason: String="已断开，手机持音由设备清理") {
        generation+=1;ready=false;session=nil;writer.clear();assembler.reset();busy=nil;pendingRead=false;subscribed=false
        onDisconnected?();status=reason;mark("disconnect \(reason)")
        if let p=active { closing=true;central.cancelPeripheralConnection(p) }
    }
    func requestInfo() { guard active != nil,!closing else{return};pendingRead=true;pump() }
    func send(_ m: Message) -> Bool {
        guard ready,session==m.session,(0...2).contains(m.channel),RequestRules.error(m)==0,let p=active else{return false}
        do {
            let maximum=min(244,p.maximumWriteValueLength(for:.withResponse))
            guard try writer.enqueue(m,maxWrite:maximum) else{return false};pump();return true
        } catch { disconnect("蓝牙写入分包失败：\(error.localizedDescription)");return false }
    }
    private func begin(_ uuid: CBUUID, _ kind: String, timeout: Int=3000) {
        busy=uuid;operation+=1;let serial=operation;mark(kind)
        later(timeout){[weak self] in if let self=self,self.operation==serial,self.busy != nil { self.disconnect("蓝牙操作超时：\(kind)") } }
    }
    private func pump() {
        guard let p=active,!closing,subscribed,busy==nil else{return}
        if pendingRead {
            guard let c=chars[info] else{return};pendingRead=false;begin(info,"读取设备状态");p.readValue(for:c);return
        }
        do {
            guard let f=try writer.next(now:Self.now),let c=chars[channels[f.channel]] else{return}
            begin(c.uuid,"写入通道 \(f.channel)，分包 \(f.bytes.count) 字节")
            p.writeValue(Data(f.bytes),for:c,type:.withResponse)
        } catch { disconnect(error.localizedDescription) }
    }
    private func subscribe() {
        guard let p=active,!closing,let c=chars[notice] else{return}
        begin(notice,"订阅加密状态通知",timeout:15000);p.setNotifyValue(true,for:c)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if active==nil { status="蓝牙已开启，可以扫描乐器" }
        case .unauthorized: disconnect("蓝牙权限未允许，请到iPhone设置中开启")
        case .poweredOff: stopScan();disconnect("手机蓝牙已关闭")
        case .unsupported: disconnect("当前设备不支持所需蓝牙功能")
        default: status="蓝牙正在准备"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard scanning,!devices.contains(where:{$0.id==peripheral.identifier}) else{return}
        let name=(advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "FPGA 乐器"
        devices.append(Device(id:peripheral.identifier,name:name,rssi:RSSI.intValue,peripheral:peripheral))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral===active,!closing else{return};mark("connected");status="正在发现乐器服务";peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral===active else{return};active=nil;closing=false;disconnect("连接失败：\(error?.localizedDescription ?? "未知原因")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral===active else{return};let wasClosing=closing;active=nil;closing=false
        if !wasClosing { disconnect("连接已中断：\(error?.localizedDescription ?? "设备断开")") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral===active,!closing else{return}
        guard error==nil,let s=peripheral.services?.first(where:{$0.uuid==service}) else { disconnect("没有找到乐器服务");return }
        peripheral.discoverCharacteristics([info,notice]+channels,for:s)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral===active,!closing else{return}
        guard error==nil,let list=service.characteristics else { disconnect("无法发现蓝牙特征");return }
        chars=Dictionary(uniqueKeysWithValues:list.map{($0.uuid,$0)})
        guard ([info,notice]+channels).allSatisfy({chars[$0] != nil}),chars[info]!.properties.contains(.read),chars[notice]!.properties.contains(.notify),channels.allSatisfy({chars[$0]!.properties.contains(.write)}) else { disconnect("设备缺少必需的读写或通知能力");return }
        status="正在订阅状态，首次连接可能出现系统配对提示";subscribe()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral===active,!closing,characteristic.uuid==notice else{return};busy=nil;operation+=1
        if error==nil && characteristic.isNotifying { subscribed=true;requestInfo() }
        else if Self.now-connectedAt<15000 { status="等待加密配对，请确认系统提示";later(1000){[weak self] in self?.subscribe()} }
        else { disconnect("状态通知订阅失败：\(error?.localizedDescription ?? "未开启通知")") }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral===active,!closing,busy==characteristic.uuid else{return};busy=nil;operation+=1
        if let error=error { disconnect("蓝牙写入失败：\(error.localizedDescription)");return }
        do { try writer.acknowledged();pump() } catch { disconnect(error.localizedDescription) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral===active,!closing else{return}
        if characteristic.uuid==info {
            guard busy==info else{return};busy=nil;operation+=1
            guard error==nil,let value=characteristic.value else { disconnect("读取设备状态失败：\(error?.localizedDescription ?? "无内容")");return }
            do {
                let parsed=try DeviceInfo(Array(value))
                if parsed.ready {
                    if !ready { session=parsed.session;ready=true;status="设备已连接并就绪";mark("session ready");onReady?(parsed.session) }
                    else if session != parsed.session { disconnect("设备会话已变更，请重新连接");return }
                } else if ready { disconnect("设备会话已失效，请重新连接");return }
                else { status="蓝牙已连接，等待板内通信就绪";later(100){[weak self] in self?.requestInfo()} }
                pump()
            } catch { disconnect(error.localizedDescription) }
        } else if characteristic.uuid==notice {
            guard error==nil,let data=characteristic.value else{return}
            do {
                guard let m=try assembler.push(Array(data),now:Self.now),session==m.session,m.sequence>lastNotice else{return}
                lastNotice=m.sequence;mark("notice opcode=\(m.opcode) bytes=\(m.payload.count)");onMessage?(m)
            } catch { assembler.reset();mark("通知校验失败：\(error.localizedDescription)") }
        }
    }
}
