package com.haobai.instrument

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Real Android GATT transport. All application state changes run on the main looper. */
@SuppressLint("MissingPermission")
class BleInstrumentLink(private val context: Context, private val listener: Listener) {
    interface Listener {
        fun status(text: String)
        fun discovered(device: BluetoothDevice, displayName: String)
        fun ready(session: ByteArray)
        fun result(message: S9Message)
        fun disconnected()
        fun mediaStatus(info: S10MediaInfo?) {}
    }
    private val handler=Handler(Looper.getMainLooper())
    private val adapter=(context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private var gatt: BluetoothGatt?=null
    private var generation=0L
    private var mtu=23
    private var subscribed=false
    private var busy=false
    private var operationSerial=0L
    private var ready=false
    private var session: ByteArray?=null
    private var pendingRead=false
    private var connectionStarted=0L
    private val outgoing=S9WriteScheduler()
    private val notifications=S9NotificationAssembler()
    private var lastNotification=0L
    private var scanGeneration=0L
    private var scanning=false
    private val seen=HashSet<String>()
    private val uuidService=UUID.fromString(S9Constants.UUID_SERVICE)
    private val uuidInfo=UUID.fromString(S9Constants.UUID_INFO)
    private val uuidStatus=UUID.fromString(S9Constants.UUID_STATUS)
    private val uuidCcc=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private val channels=listOf(S9Constants.UUID_RT,S9Constants.UUID_CFG,S9Constants.UUID_FILE).map(UUID::fromString)

    fun missingPermissions(): Array<String> {
        val needed=if(Build.VERSION.SDK_INT>=31) arrayOf(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT)
                   else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return needed.filter { context.checkSelfPermission(it)!=PackageManager.PERMISSION_GRANTED }.toTypedArray()
    }
    fun scan() {
        if(missingPermissions().isNotEmpty()) { listener.status("需要蓝牙权限");return }
        if(adapter==null || !adapter.isEnabled) { listener.status("请开启手机蓝牙");return }
        stopScan();seen.clear();val token=++scanGeneration
        val scanner=adapter.bluetoothLeScanner?:run {listener.status("手机BLE扫描器不可用");return}
        val filters=listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(uuidService)).build())
        scanning=true
        scanner.startScan(filters,ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback)
        listener.status("正在扫描乐器（10秒）")
        handler.postDelayed({if(token==scanGeneration) {stopScan();listener.status("扫描结束")}},10000)
    }
    private val scanCallback=object: ScanCallback() {
        override fun onScanResult(type: Int, result: ScanResult) {
            handler.post {
                if(scanning && seen.add(result.device.address)) listener.discovered(result.device,result.scanRecord?.deviceName?:"FPGA 乐器")
            }
        }
        override fun onScanFailed(error: Int) { handler.post {listener.status("扫描失败：$error")} }
    }
    fun stopScan() {
        scanGeneration++
        scanning=false
        if(missingPermissions().isEmpty()) adapter?.bluetoothLeScanner?.stopScan(scanCallback)
    }
    fun connect(device: BluetoothDevice) {
        if(missingPermissions().isNotEmpty()) {listener.status("需要蓝牙权限");return}
        stopScan();close();val token=++generation
        mtu=23;connectionStarted=SystemClock.elapsedRealtime();listener.status("正在连接并建立加密会话")
        gatt=device.connectGatt(context,false,callbacks(token),BluetoothDevice.TRANSPORT_LE)
        handler.postDelayed({if(token==generation && !ready) fail("连接/初始化超时")},20000)
    }
    fun close() {
        generation++; ready=false;session=null;subscribed=false;busy=false;pendingRead=false
        outgoing.clear();notifications.reset();lastNotification=0
        val old=gatt;gatt=null
        if(missingPermissions().isEmpty()) {old?.disconnect();old?.close()}
        listener.disconnected()
    }
    private fun fail(text: String) {close();listener.status(text)}
    private fun beginOperation() {
        busy=true
        val operation=++operationSerial
        val connectionGeneration=generation
        handler.postDelayed({
            if(connectionGeneration==generation && operation==operationSerial && busy)
                fail("GATT操作回调超时，结束会话清理手机持音")
        },3000)
    }
    fun send(message: S9Message): Boolean {
        if(!ready || session?.contentEquals(message.session)!=true || message.channel !in 0..2) return false
        if(S9RequestRules.error(message)!=0) {listener.status("命令参数不合法，尚未发送");return false}
        if(!outgoing.enqueue(message,mtu)) return false
        pump();return true // queued locally, NOT execution acknowledgement
    }
    fun requestInfo() {pendingRead=true;pump()}
    private fun pump() {
        val connection=gatt?:return
        if(busy || !subscribed) return
        val service=connection.getService(uuidService)?:return
        if(pendingRead) {
            pendingRead=false;beginOperation()
            if(!connection.readCharacteristic(service.getCharacteristic(uuidInfo))) fail("无法读取设备状态")
        } else if(outgoing.size!=0) {
            val fragment=try {outgoing.next(SystemClock.elapsedRealtime())} catch(_:IllegalStateException) {fail("GATT写入超时，结束会话清理手机持音");return}
            if(fragment==null) return
            val (channel,bytes)=fragment
            val ch=service.getCharacteristic(channels[channel])?:run {fail("缺少控制特征");return}
            beginOperation()
            val ok=if(Build.VERSION.SDK_INT>=33) connection.writeCharacteristic(ch,bytes,BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)==BluetoothStatusCodes.SUCCESS
                   else {ch.writeType=BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;ch.value=bytes;connection.writeCharacteristic(ch)}
            if(!ok) {busy=false;handler.postDelayed({pump()},20)}
        }
    }
    private fun subscribe(connection: BluetoothGatt) {
        val characteristic=connection.getService(uuidService)?.getCharacteristic(uuidStatus)
        val descriptor=characteristic?.getDescriptor(uuidCcc)
        if(characteristic==null || descriptor==null || !connection.setCharacteristicNotification(characteristic,true)) {fail("设备缺少状态通知服务");return}
        val ok=if(Build.VERSION.SDK_INT>=33) connection.writeDescriptor(descriptor,BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)==BluetoothStatusCodes.SUCCESS
               else {descriptor.value=BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;connection.writeDescriptor(descriptor)}
        if(!ok) handler.postDelayed({if(connection===gatt) subscribe(connection)},100)
    }
    private fun readInfo(value: ByteArray) {
        try {
            require(value.size==64 && value.copyOfRange(0,4).contentEquals("S9IN".toByteArray()) && value[4]==1.toByte())
            val b=ByteBuffer.wrap(value).order(ByteOrder.LITTLE_ENDIAN)
            require(S9Protocol.crc(value,0,60)==(b.getInt(60).toLong() and 0xffffffffL))
            require((b.getShort(24).toInt() and 65535)==548 && (b.getShort(26).toInt() and 65535)==192)
            listener.mediaStatus(S10MediaInfo.parse(value))
            val sid=value.copyOfRange(8,24)
            if(value[5].toInt()==S9Constants.LINK_READY) {
                require(b.getLong(8)!=0L && b.getLong(16)!=0L)
                if(!ready) {session=sid;ready=true;listener.status("已连接；等待命令执行反馈");listener.ready(sid.clone())}
                else require(session!!.contentEquals(sid))
            } else {
                if(ready) {fail("设备会话失效，请重新连接");return}
                listener.status("BLE已连接，FPGA会话尚未就绪")
                val token=generation
                handler.postDelayed({if(token==generation) requestInfo()},100)
            }
        } catch(_:IllegalArgumentException) {fail("设备INFO格式/CRC/会话不符")}
    }
    private fun changed(value: ByteArray) {
        try {
            val message=notifications.push(value,SystemClock.elapsedRealtime())?:return
            if(session?.contentEquals(message.session)!=true || message.sequence<=lastNotification) return
            require((message.opcode==S9Constants.OP_RESULT && message.payload.size==36) ||
                (message.opcode==S11Protocol.RECORD_INFO && message.payload.size==72) ||
                (message.opcode==S11Protocol.DOWNLOAD_DATA && message.payload.size in 33..512))
            lastNotification=message.sequence;listener.result(message)
        } catch(_:IllegalArgumentException) {
            notifications.reset();listener.status("状态通知损坏；需查询命令结果")
        }
    }
    private fun callbacks(token: Long)=object: BluetoothGattCallback() {
        private fun post(c:BluetoothGatt,action:()->Unit) {handler.post {if(token==generation && c===gatt) action()}}
        override fun onConnectionStateChange(c:BluetoothGatt,status:Int,newState:Int)=post(c) {
            if(status!=BluetoothGatt.GATT_SUCCESS || newState==BluetoothProfile.STATE_DISCONNECTED) fail("蓝牙已断开；手机持音由设备清理")
            else if(newState==BluetoothProfile.STATE_CONNECTED) {if(!c.requestMtu(247)) c.discoverServices()}
        }
        override fun onMtuChanged(c:BluetoothGatt,value:Int,status:Int)=post(c) {
            if(status==BluetoothGatt.GATT_SUCCESS) mtu=value.coerceIn(23,247)
            if(!c.discoverServices()) fail("无法发现服务")
        }
        override fun onServicesDiscovered(c:BluetoothGatt,status:Int)=post(c) {
            if(status!=BluetoothGatt.GATT_SUCCESS || c.getService(uuidService)==null) fail("设备不支持阶段9协议") else subscribe(c)
        }
        override fun onDescriptorWrite(c:BluetoothGatt,d:BluetoothGattDescriptor,status:Int)=post(c) {
            if(status==BluetoothGatt.GATT_SUCCESS) {subscribed=true;requestInfo()}
            else if(SystemClock.elapsedRealtime()-connectionStarted<15000) {
                listener.status("等待蓝牙加密/配对确认")
                handler.postDelayed({if(token==generation && c===gatt) subscribe(c)},1000)
            } else fail("无法订阅加密状态通知")
        }
        override fun onCharacteristicRead(c:BluetoothGatt,ch:BluetoothGattCharacteristic,value:ByteArray,status:Int) {
            val copy=value.clone()
            post(c) {busy=false;if(status==BluetoothGatt.GATT_SUCCESS && ch.uuid==uuidInfo) readInfo(copy) else fail("读取INFO失败：$status");pump()}
        }
        @Deprecated("API26-32 callback")
        override fun onCharacteristicRead(c:BluetoothGatt,ch:BluetoothGattCharacteristic,status:Int) {
            if(Build.VERSION.SDK_INT<33) onCharacteristicRead(c,ch,ch.value?:ByteArray(0),status)
        }
        override fun onCharacteristicWrite(c:BluetoothGatt,ch:BluetoothGattCharacteristic,status:Int)=post(c) {
            busy=false
            if(status==BluetoothGatt.GATT_SUCCESS) {outgoing.acknowledged();pump()}
            else if(status==17 || status==BluetoothGatt.GATT_CONNECTION_CONGESTED) handler.postDelayed({if(token==generation) pump()},20)
            else fail("写入失败：$status；未宣称命令执行")
        }
        override fun onCharacteristicChanged(c:BluetoothGatt,ch:BluetoothGattCharacteristic,value:ByteArray) {
            val copy=value.clone();post(c) {if(ch.uuid==uuidStatus) changed(copy)}
        }
        @Deprecated("API26-32 callback")
        override fun onCharacteristicChanged(c:BluetoothGatt,ch:BluetoothGattCharacteristic) {
            if(Build.VERSION.SDK_INT<33) onCharacteristicChanged(c,ch,ch.value?:ByteArray(0))
        }
    }
}
