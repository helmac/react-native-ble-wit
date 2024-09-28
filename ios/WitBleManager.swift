import Foundation
import CoreBluetooth
import WitSDK


@objc(WitBleManager)
class WitBleManager: RCTEventEmitter, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    static var shared:WitBleManager?
    static var sharedManager:CBCentralManager?
    
    private var hasListeners:Bool = false
    
    private var manager: CBCentralManager?
    private var scanTimer: Timer?
    
    private var peripherals: Dictionary<String, Peripheral>
    private var connectCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var readCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var readRSSICallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var readDescriptorCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var writeDescriptorCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var retrieveServicesCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var getDataCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var writeCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var writeQueue: Array<Any>
    private var notificationCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    private var stopNotificationCallbacks: Dictionary<String, [RCTResponseSenderBlock]>
    
    private var connectedPeripherals: Set<String>
    
    private var retrieveServicesLatches: Dictionary<String, Set<CBService>>
    private var characteristicsLatches: Dictionary<String, Set<CBCharacteristic>>
    
    private let serialQueue = DispatchQueue(label: "WitBleManager.serialQueue")
    
    private var exactAdvertisingName: [String]
    
    static var verboseLogging = false
    
    // 服务uuid
    var uuidService: Dictionary<String, String?>
    
    // 发送特征值uuid
    var uuidSend: Dictionary<String, String?>
    
    // 读取特征值uuid
    var uuidRead: Dictionary<String, String?>
    
    //发送数据特征(连接到设备之后可以把需要用到的特征保存起来，方便使用)
    var sendCharacteristic: Dictionary<String, CBCharacteristic>

    var bwt901bleRecordObserver: DeviceDataObserver?
    
    private override init() {
        peripherals = [:]
        connectCallbacks = [:]
        readCallbacks = [:]
        readRSSICallbacks = [:]
        readDescriptorCallbacks = [:]
        writeDescriptorCallbacks = [:]
        retrieveServicesCallbacks = [:]
        getDataCallbacks = [:]
        writeCallbacks = [:]
        writeQueue = []
        notificationCallbacks = [:]
        stopNotificationCallbacks = [:]
        retrieveServicesLatches = [:]
        characteristicsLatches = [:]
        exactAdvertisingName = []
        connectedPeripherals = []
        uuidService = [:]
        uuidSend = [:]
        uuidRead = [:]
        sendCharacteristic = [:]
        
        super.init()
        
        NSLog("WitBleManager created");
        
        WitBleManager.shared = self
        bwt901bleRecordObserver = DeviceDataObserver(manager: self)
        
        NotificationCenter.default.addObserver(self, selector: #selector(bridgeReloading), name: NSNotification.Name(rawValue: "RCTBridgeWillReloadNotification"), object: nil)
    }
    
    @objc override static func requiresMainQueueSetup() -> Bool { return true }
    
    @objc override func supportedEvents() -> [String]! {
        return ["WitBleManagerDidUpdateValueForCharacteristic", "WitBleManagerDeviceDataOnRecord", "WitBleManagerStopScan", "WitBleManagerDiscoverPeripheral", "WitBleManagerConnectPeripheral", "WitBleManagerDisconnectPeripheral", "WitBleManagerDidUpdateState", "WitBleManagerCentralManagerWillRestoreState", "WitBleManagerDidUpdateNotificationStateFor"]
    }
    
    @objc override func startObserving() {
        hasListeners = true
    }
    
    @objc override func stopObserving() {
        hasListeners = false
    }
    
    @objc func bridgeReloading() {
        if let manager = manager {
            if let scanTimer = self.scanTimer {
                scanTimer.invalidate()
                self.scanTimer = nil
                manager.stopScan()
            }
            
            manager.delegate = nil
        }
        
        serialQueue.sync {
            for p in peripherals.values {
                p.instance.delegate = nil
            }
        }
        
        peripherals = [:]
    }
    
    // Helper method to find a peripheral by UUID
    func findPeripheral(byUUID uuid: String) -> Peripheral? {
        var foundPeripheral: Peripheral? = nil
        
        serialQueue.sync {
            if let peripheral = peripherals[uuid] {
                foundPeripheral = peripheral;
            }
        }
        
        return foundPeripheral
    }
    
    // Helper method to insert callback in different queues
    func insertCallback(_ callback: @escaping RCTResponseSenderBlock, intoDictionary dictionary: inout Dictionary<String, [RCTResponseSenderBlock]>, withKey key: String) {
        serialQueue.sync {
            var peripheralCallbacks = dictionary[key] ?? [RCTResponseSenderBlock]()
            peripheralCallbacks.append(callback)
            dictionary[key] = peripheralCallbacks
        }
    }
    
    // Helper method to call the callbacks for a specific peripheral and clear the queue
    func invokeAndClearDictionary(_ dictionary: inout Dictionary<String, [RCTResponseSenderBlock]>, withKey key: String, usingParameters parameters: [Any]) {
        serialQueue.sync {
            invokeAndClearDictionary_THREAD_UNSAFE(&dictionary, withKey: key, usingParameters: parameters)
        }
    }

    func invokeAndClearDictionary_THREAD_UNSAFE(_ dictionary: inout Dictionary<String, [RCTResponseSenderBlock]>, withKey key: String, usingParameters parameters: [Any]) {
        if let peripheralCallbacks = dictionary[key] {
            for callback in peripheralCallbacks {
                callback(parameters)
            }
            
            dictionary.removeValue(forKey: key)
        }
    }
    
    @objc func getContext(_ peripheralUUIDString: String, serviceUUIDString: String, characteristicUUIDString: String, prop: CBCharacteristicProperties, callback: @escaping RCTResponseSenderBlock) -> BLECommandContext? {
        let serviceUUID = CBUUID(string: serviceUUIDString)
        let characteristicUUID = CBUUID(string: characteristicUUIDString)
        
        guard let peripheral = peripherals[peripheralUUIDString] else {
            let error = String(format: "Could not find peripheral with UUID %@", peripheralUUIDString)
            NSLog(error)
            callback([error])
            return nil
        }
        
        guard let service = Helper.findService(fromUUID: serviceUUID, peripheral: peripheral.instance) else {
            let error = String(format: "Could not find service with UUID %@ on peripheral with UUID %@",
                               serviceUUIDString,
                               peripheral.instance.uuidAsString())
            NSLog(error)
            callback([error])
            return nil
        }
        
        var characteristic = Helper.findCharacteristic(fromUUID: characteristicUUID, service: service, prop: prop)
        
        // Special handling for INDICATE. If characteristic with notify is not found, check for indicate.
        if prop == CBCharacteristicProperties.notify && characteristic == nil {
            characteristic = Helper.findCharacteristic(fromUUID: characteristicUUID, service: service, prop: CBCharacteristicProperties.indicate)
        }
        
        // As a last resort, try to find ANY characteristic with this UUID, even if it doesn't have the correct properties
        if characteristic == nil {
            characteristic = Helper.findCharacteristic(fromUUID: characteristicUUID, service: service)
        }
        
        guard let finalCharacteristic = characteristic else {
            let error = String(format: "Could not find characteristic with UUID %@ on service with UUID %@ on peripheral with UUID %@",
                               characteristicUUIDString,
                               serviceUUIDString,
                               peripheral.instance.uuidAsString())
            NSLog(error)
            callback([error])
            return nil
        }
        
        let context = BLECommandContext()
        context.peripheral = peripheral
        context.service = service
        context.characteristic = finalCharacteristic
        return context
    }
    
    
    @objc public func start(_ options: NSDictionary,
                            callback: RCTResponseSenderBlock) {
        if WitBleManager.verboseLogging {
            NSLog("WitBleManager initialized")
        }
        var initOptions = [String: Any]()
        
        if let showAlert = options["showAlert"] as? Bool {
            initOptions[CBCentralManagerOptionShowPowerAlertKey] = showAlert
        }
        
        if let verboseLogging = options["verboseLogging"] as? Bool {
            WitBleManager.verboseLogging = verboseLogging
        }
        
        var queue: DispatchQueue
        if let queueIdentifierKey = options["queueIdentifierKey"] as? String {
            queue = DispatchQueue(label: queueIdentifierKey, qos: DispatchQoS.background)
        } else {
            queue = DispatchQueue.main
        }
        
        if let restoreIdentifierKey = options["restoreIdentifierKey"] as? String {
            initOptions[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifierKey
            
            if let sharedManager = WitBleManager.sharedManager {
                manager = sharedManager
                manager?.delegate = self
            } else {
                manager = CBCentralManager(delegate: self, queue: queue, options: initOptions)
                WitBleManager.sharedManager = manager
            }
        } else {
            manager = CBCentralManager(delegate: self, queue: queue, options: initOptions)
            WitBleManager.sharedManager = manager
        }
        
        callback([])
    }
    
    @objc public func scan(_ serviceUUIDStrings: [Any],
                           timeoutSeconds: NSNumber,
                           allowDuplicates: Bool,
                           scanningOptions: NSDictionary,
                           callback:RCTResponseSenderBlock) {
        if Int(truncating: timeoutSeconds) > 0 {
            NSLog("scan with timeout \(timeoutSeconds)")
        } else {
            NSLog("scan")
        }
        
        // Clear the peripherals before scanning again, otherwise cannot connect again after disconnection
        // Only clear peripherals that are not connected - otherwise connections fail silently (without any
        // onDisconnect* callback).
        serialQueue.sync {
            let disconnectedPeripherals = peripherals.filter({ $0.value.instance.state != .connected && $0.value.instance.state != .connecting })
            disconnectedPeripherals.forEach { (uuid, peripheral) in
                peripheral.instance.delegate = nil
                peripherals.removeValue(forKey: uuid)
            }
        }
        
        var serviceUUIDs = [CBUUID]()
        if let serviceUUIDStrings = serviceUUIDStrings as? [String] {
            serviceUUIDs = serviceUUIDStrings.map { CBUUID(string: $0) }
        }
        
        var options: [String: Any]?
        if allowDuplicates {
            options = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        }
        
        exactAdvertisingName.removeAll()
        if let names = scanningOptions["exactAdvertisingName"] as? [String] {
            exactAdvertisingName.append(contentsOf: names)
        }
        
        manager?.scanForPeripherals(withServices: serviceUUIDs, options: options)
        
        if timeoutSeconds.doubleValue > 0 {
            if let scanTimer = scanTimer {
                scanTimer.invalidate()
                self.scanTimer = nil
            }
            DispatchQueue.main.async {
                self.scanTimer = Timer.scheduledTimer(timeInterval: timeoutSeconds.doubleValue, target: self, selector: #selector(self.stopTimer), userInfo: nil, repeats: false)
            }
        }
        
        callback([])
    }
    
    @objc func stopTimer() {
        NSLog("Stop scan");
        scanTimer = nil;
        manager?.stopScan()
        if hasListeners {
            sendEvent(withName: "WitBleManagerStopScan", body: ["status": 10])
        }
    }
    
    
    @objc public func stopScan(_ callback: @escaping RCTResponseSenderBlock) {
        if let scanTimer = self.scanTimer {
            scanTimer.invalidate()
            self.scanTimer = nil
        }
        
        manager?.stopScan()
        
        if hasListeners {
            sendEvent(withName: "WitBleManagerStopScan", body: ["status": 0])
        }
        
        callback([])
    }
    
    
    public func onRecord(_ bwt901ble: Bwt901ble) {
        self.sendEvent(withName: "WitBleManagerDeviceDataOnRecord", body: [
            "peripheral": bwt901ble.bluetoothBLE?.peripheral.uuidAsString() ?? "",
            "deviceData": self.getDeviceData(bwt901ble.bluetoothBLE?.peripheral.uuidAsString() ?? ""),
        ])
    }
    
    @objc func connect(_ peripheralUUID: String,
                       options: NSDictionary,
                       callback: @escaping RCTResponseSenderBlock) {
        
        if let peripheral = peripherals[peripheralUUID] {
            // Found the peripheral, connect to it
            NSLog("Connecting to peripheral with UUID: \(peripheralUUID)")
            
            insertCallback(callback, intoDictionary: &connectCallbacks, withKey: peripheral.instance.uuidAsString())
            manager?.connect(peripheral.instance)
            do {
                try peripheral.bwt901ble?.openDevice()

                if (peripheral.bwt901ble != nil && self.bwt901bleRecordObserver != nil) {
                    peripheral.bwt901ble?.registerListenKeyUpdateObserver(obj: self.bwt901bleRecordObserver!)
                }
            }
            catch {
                NSLog("Bwt901ble can't be open \(error)")
            }
        } else {
            // Try to retrieve the peripheral
            NSLog("Retrieving peripheral with UUID: \(peripheralUUID)")
            
            if let uuid = UUID(uuidString: peripheralUUID) {
                let peripheralArray = manager?.retrievePeripherals(withIdentifiers: [uuid])
                if let retrievedPeripheral = peripheralArray?.first {
                    serialQueue.sync {
                        peripherals[retrievedPeripheral.uuidAsString()] = Peripheral(peripheral:retrievedPeripheral, sendCharacteristic: sendCharacteristic[retrievedPeripheral.uuidAsString()], bwt901bleRecordObserver: self.bwt901bleRecordObserver!)
                    }
                    NSLog("Successfully retrieved and connecting to peripheral with UUID: \(peripheralUUID)")
                    
                    // Connect to the retrieved peripheral
                    insertCallback(callback, intoDictionary: &connectCallbacks, withKey: retrievedPeripheral.uuidAsString())
                    manager?.connect(retrievedPeripheral, options: nil)
                    do {
                        try peripherals[retrievedPeripheral.uuidAsString()]?.bwt901ble?.openDevice()
                    }
                    catch {
                        NSLog("Bwt901ble can't be open \(error)")
                    }
                } else {
                    let error = "Could not find peripheral \(peripheralUUID)."
                    NSLog(error)
                    callback([error, NSNull()])
                }
            } else {
                let error = "Wrong UUID format \(peripheralUUID)"
                callback([error, NSNull()])
            }
        }
    }
    
    @objc func disconnect(_ peripheralUUID: String,
                          force: Bool,
                          callback: @escaping RCTResponseSenderBlock) {
        if let peripheral = peripherals[peripheralUUID] {
            NSLog("Disconnecting from peripheral with UUID: \(peripheralUUID)")
            
            peripherals[peripheralUUID]?.bwt901ble?.closeDevice()
            
            
            if let services = peripheral.instance.services {
                for service in services {
                    if let characteristics = service.characteristics {
                        for characteristic in characteristics {
                            if characteristic.isNotifying {
                                NSLog("Remove notification from: \(characteristic.uuid)")
                                peripheral.instance.setNotifyValue(false, for: characteristic)
                            }
                        }
                    }
                }
            }
            
            manager?.cancelPeripheralConnection(peripheral.instance)
            callback([])
            
        } else {
            let error = "Could not find peripheral \(peripheralUUID)."
            NSLog(error)
            callback([error])
        }
    }
    
    @objc func retrieveServices(_ peripheralUUID: String,
                                services: [String],
                                callback: @escaping RCTResponseSenderBlock) {
        NSLog("retrieveServices \(services)")
        
        if let peripheral = peripherals[peripheralUUID], peripheral.instance.state == .connected {
            insertCallback(callback, intoDictionary: &retrieveServicesCallbacks, withKey: peripheral.instance.uuidAsString())
            
            var uuids: [CBUUID] = []
            for string in services {
                let uuid = CBUUID(string: string)
                uuids.append(uuid)
            }
            
            if !uuids.isEmpty {
                peripheral.instance.discoverServices(uuids)
            } else {
                peripheral.instance.discoverServices(nil)
            }
            
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }
    
    func getDeviceData(_ peripheralUUID: String) -> [String:String?] {
        if let peripheral = peripherals[peripheralUUID], peripheral.instance.state == .connected {
            var s: [String:String?] = [:]
            s["version"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.VersionNumber)
            s["AccX"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AccX)
            s["AccY"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AccY)
            s["AccZ"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AccZ)
            s["GyroX"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.GyroX)
            s["GyroY"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.GyroY)
            s["GyroZ"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.GyroZ)
            s["AngleX"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AngleX)
            s["AngleY"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AngleY)
            s["AngleZ"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.AngleZ)
            s["MagX"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.MagX)
            s["MagY"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.MagY)
            s["MagZ"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.MagZ)
            s["ElectricQuantityPercentage"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.ElectricQuantityPercentage)
            s["Temperature"] = peripheral.bwt901ble?.getDeviceData(WitSensorKey.Temperature)
            NSLog("getData \(s)")
            
            return s
        } else {
            return [:]
        }
    }
    
    @objc func getData(_ peripheralUUID: String,
                                callback: @escaping RCTResponseSenderBlock) {
        NSLog("retrieveData")
        
        if let peripheral = peripherals[peripheralUUID], peripheral.instance.state == .connected {
            var deviceDataObj = getDeviceData(peripheralUUID)

            NSLog("getData \(deviceDataObj)")
            callback([NSNull(), deviceDataObj])
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }
    
    @objc func readRSSI(_ peripheralUUID: String,
                        callback: @escaping RCTResponseSenderBlock) {
        NSLog("readRSSI")
        
        if let peripheral = peripherals[peripheralUUID], peripheral.instance.state == .connected {
            insertCallback(callback, intoDictionary: &readRSSICallbacks, withKey: peripheral.instance.uuidAsString())
            peripheral.instance.readRSSI()
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }
    
    @objc func readDescriptor(_ peripheralUUID: String,
                              serviceUUID: String,
                              characteristicUUID: String,
                              descriptorUUID: String,
                              callback: @escaping RCTResponseSenderBlock) {
        NSLog("readDescriptor")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.read, callback: callback) else {
            return
        }
        
        let peripheral = context.peripheral
        let characteristic = context.characteristic
        
        guard let descriptor = Helper.findDescriptor(fromUUID: CBUUID(string: descriptorUUID), characteristic: characteristic!) else {
            let error = "Could not find descriptor with UUID \(descriptorUUID) on characteristic with UUID \(String(describing: characteristic?.uuid.uuidString)) on peripheral with UUID \(peripheralUUID)"
            NSLog(error)
            callback([error])
            return
        }
        
        if let peripheral = peripheral?.instance {
            let key = Helper.key(forPeripheral: peripheral, andCharacteristic: characteristic!, andDescriptor: descriptor)
            insertCallback(callback, intoDictionary: &readDescriptorCallbacks, withKey: key)
            
        }
        
        peripheral?.instance.readValue(for: descriptor)
    }
    
    @objc func writeDescriptor(_ peripheralUUID: String,
                              serviceUUID: String,
                              characteristicUUID: String,
                              descriptorUUID: String,
                              message: [UInt8],
                              callback: @escaping RCTResponseSenderBlock) {
        NSLog("writeDescriptor")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.read, callback: callback) else {
            return
        }
        
        let peripheral = context.peripheral
        let characteristic = context.characteristic
        
        guard let descriptor = Helper.findDescriptor(fromUUID: CBUUID(string: descriptorUUID), characteristic: characteristic!) else {
            let error = "Could not find descriptor with UUID \(descriptorUUID) on characteristic with UUID \(String(describing: characteristic?.uuid.uuidString)) on peripheral with UUID \(peripheralUUID)"
            NSLog(error)
            callback([error])
            return
        }
        
        if let peripheral = peripheral?.instance {
            let key = Helper.key(forPeripheral: peripheral, andCharacteristic: characteristic!, andDescriptor: descriptor)
            insertCallback(callback, intoDictionary: &writeDescriptorCallbacks, withKey: key)
            
        }
        
        let dataMessage = Data(message)
        peripheral?.instance.writeValue(dataMessage, for: descriptor)
    }
    
    @objc func getDiscoveredPeripherals(_ callback: @escaping RCTResponseSenderBlock) {
        NSLog("Get discovered peripherals")
        var discoveredPeripherals: [[String: Any]] = []
        
        serialQueue.sync {
            for (_, peripheral) in peripherals {
                discoveredPeripherals.append(peripheral.advertisingInfo())
            }
        }
        
        callback([NSNull(), discoveredPeripherals])
    }
    
    @objc func getConnectedPeripherals(_ serviceUUIDStrings: [String],
                                       callback: @escaping RCTResponseSenderBlock) {
        NSLog("Get connected peripherals")
        var serviceUUIDs: [CBUUID] = []
        
        for uuidString in serviceUUIDStrings {
            serviceUUIDs.append(CBUUID(string: uuidString))
        }
        
        var connectedPeripherals: [Peripheral] = []
        
        if serviceUUIDs.isEmpty {
            serialQueue.sync {
                connectedPeripherals = peripherals.filter({ $0.value.instance.state == .connected }).map({ p in
                    p.value
                })
            }
        } else {
            let connectedCBPeripherals: [CBPeripheral] = manager?.retrieveConnectedPeripherals(withServices: serviceUUIDs) ?? []
            
            serialQueue.sync {
                for ph in connectedCBPeripherals {
                    if let peripheral = peripherals[ph.uuidAsString()] {
                        connectedPeripherals.append(peripheral)
                    } else {
                        peripherals[ph.uuidAsString()] = Peripheral(peripheral: ph, sendCharacteristic: sendCharacteristic[ph.uuidAsString()], bwt901bleRecordObserver: self.bwt901bleRecordObserver!)
                    }
                }
            }
        }
        
        var foundedPeripherals: [[String: Any]] = []
        
        for peripheral in connectedPeripherals {
            foundedPeripherals.append(peripheral.advertisingInfo())
        }
        
        callback([NSNull(), foundedPeripherals])
    }
    
    @objc func isPeripheralConnected(_ peripheralUUID: String,
                                     callback: @escaping RCTResponseSenderBlock) {
        
        if let peripheral = peripherals[peripheralUUID] {
            callback([NSNull(), peripheral.instance.state == .connected])
        } else {
            callback(["Peripheral not found"])
        }
    }
    
    @objc func isScanning(_ callback: @escaping RCTResponseSenderBlock) {
        if let manager = manager {
            callback([NSNull(), manager.isScanning])
        } else {
            callback(["CBCentralManager not found"])
        }
    }
    
    @objc func checkState(_ callback: @escaping RCTResponseSenderBlock) {
        if let manager = manager {
            centralManagerDidUpdateState(manager)
            
            let stateName = Helper.centralManagerStateToString(manager.state)
            callback([stateName])
        }
    }
    
    @objc func write(_ peripheralUUID: String,
                     serviceUUID: String,
                     characteristicUUID: String,
                     message: [UInt8],
                     maxByteSize: Int,
                     callback: @escaping RCTResponseSenderBlock) {
        NSLog("write")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.write, callback: callback) else {
            return
        }
        
        let dataMessage = Data(message)
        
        if let peripheral = context.peripheral, let characteristic = context.characteristic {
            let key = Helper.key(forPeripheral:peripheral.instance, andCharacteristic: characteristic)
            insertCallback(callback, intoDictionary: &writeCallbacks, withKey: key)
            
            if WitBleManager.verboseLogging {
                NSLog("Message to write(\(dataMessage.count)): \(dataMessage.hexadecimalString())")
            }
            
            if dataMessage.count > maxByteSize {
                var count = 0
                var offset = 0
                while count < dataMessage.count, (dataMessage.count - count) > maxByteSize {
                    let splitMessage = dataMessage.subdata(in: offset..<offset + maxByteSize)
                    writeQueue.append(splitMessage)
                    count += maxByteSize
                    offset += maxByteSize
                }
                
                if count < dataMessage.count {
                    let splitMessage = dataMessage.subdata(in: offset..<dataMessage.count)
                    writeQueue.append(splitMessage)
                }
                
                if WitBleManager.verboseLogging {
                    NSLog("Queued splitted message: \(writeQueue.count)")
                }
                
                if case let firstMessage as Data = writeQueue.removeFirst() {
                    peripheral.instance.writeValue(firstMessage, for: characteristic, type: .withResponse)
                }
            } else {
                peripheral.instance.writeValue(dataMessage, for: characteristic, type: .withResponse)
            }
        }
    }
    
    @objc func writeWithoutResponse(_ peripheralUUID: String,
                                    serviceUUID: String,
                                    characteristicUUID: String,
                                    message: [UInt8],
                                    maxByteSize: Int,
                                    queueSleepTime: Int,
                                    callback: @escaping RCTResponseSenderBlock) {
        NSLog("writeWithoutResponse")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.writeWithoutResponse, callback: callback) else {
            return
        }
        
        let dataMessage = Data(message)
        
        if WitBleManager.verboseLogging {
            NSLog("Message to write(\(dataMessage.count)): \(dataMessage.hexadecimalString())")
        }
        
        if dataMessage.count > maxByteSize {
            var offset = 0
            let peripheral = context.peripheral
            guard let characteristic = context.characteristic else { return }
            
            repeat {
                let thisChunkSize = min(maxByteSize, dataMessage.count - offset)
                let chunk = dataMessage.subdata(in: offset..<offset + thisChunkSize)
                
                offset += thisChunkSize
                peripheral?.instance.writeValue(chunk, for: characteristic, type: .withoutResponse)
                
                let sleepTimeSeconds = TimeInterval(queueSleepTime) / 1000
                Thread.sleep(forTimeInterval: sleepTimeSeconds)
            } while offset < dataMessage.count
            
            callback([])
        } else {
            let peripheral = context.peripheral
            guard let characteristic = context.characteristic else { return }
            
            peripheral?.instance.writeValue(dataMessage, for: characteristic, type: .withoutResponse)
            callback([])
        }
    }
    
    @objc func read(_ peripheralUUID: String,
                    serviceUUID: String,
                    characteristicUUID: String,
                    callback: @escaping RCTResponseSenderBlock) {
        NSLog("read")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.read, callback: callback) else {
            return
        }
        
        let peripheral = context.peripheral
        let characteristic = context.characteristic
        
        let key = Helper.key(forPeripheral:peripheral!.instance as CBPeripheral, andCharacteristic: characteristic!)
        insertCallback(callback, intoDictionary: &readCallbacks, withKey: key)
        
        peripheral?.instance.readValue(for: characteristic!)  // callback sends value
    }
    
    @objc func startNotification(_ peripheralUUID: String,
                                 serviceUUID: String,
                                 characteristicUUID: String,
                                 callback: @escaping RCTResponseSenderBlock) {
        NSLog("startNotification")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.notify, callback: callback) else {
            return
        }
        
        guard let peripheral = context.peripheral else { return }
        guard let characteristic = context.characteristic else { return }
        
        let key = Helper.key(forPeripheral: (peripheral.instance as CBPeripheral?)!, andCharacteristic: characteristic)
        insertCallback(callback, intoDictionary: &notificationCallbacks, withKey: key)
        
        peripheral.instance.setNotifyValue(true, for: characteristic)
    }
    
    @objc func stopNotification(_ peripheralUUID: String,
                                serviceUUID: String,
                                characteristicUUID: String,
                                callback: @escaping RCTResponseSenderBlock) {
        NSLog("stopNotification")
        
        guard let context = getContext(peripheralUUID, serviceUUIDString: serviceUUID, characteristicUUIDString: characteristicUUID, prop: CBCharacteristicProperties.notify, callback: callback) else {
            return
        }
        
        let peripheral = context.peripheral
        guard let characteristic = context.characteristic else { return }
        
        if characteristic.isNotifying {
            let key = Helper.key(forPeripheral: (peripheral?.instance as CBPeripheral?)!, andCharacteristic: characteristic)
            insertCallback(callback, intoDictionary: &stopNotificationCallbacks, withKey: key)
            peripheral?.instance.setNotifyValue(false, for: characteristic)
            NSLog("Characteristic stopped notifying")
        } else {
            NSLog("Characteristic is not notifying")
            callback([])
        }
    }
    
    @objc func getMaximumWriteValueLengthForWithoutResponse(_ peripheralUUID: String,
                                                            callback: @escaping RCTResponseSenderBlock) {
        NSLog("getMaximumWriteValueLengthForWithoutResponse")
        
        guard let peripheral = peripherals[peripheralUUID] else {
            callback(["Peripheral not found or not connected"])
            return
        }
        
        if peripheral.instance.state == .connected {
            let max = NSNumber(value: peripheral.instance.maximumWriteValueLength(for: .withoutResponse))
            callback([NSNull(), max])
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }
    
    @objc func getMaximumWriteValueLengthForWithResponse(_ peripheralUUID: String,
                                                         callback: @escaping RCTResponseSenderBlock) {
        NSLog("getMaximumWriteValueLengthForWithResponse")
        
        guard let peripheral = peripherals[peripheralUUID] else {
            callback(["Peripheral not found or not connected"])
            return
        }
        
        if peripheral.instance.state == .connected {
            let max = NSNumber(value: peripheral.instance.maximumWriteValueLength(for: .withResponse))
            callback([NSNull(), max])
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], restoredPeripherals.count > 0 {
            serialQueue.sync {
                var data = [[String: Any]]()
                for peripheral in restoredPeripherals {
                    let p = Peripheral(peripheral:peripheral, sendCharacteristic: sendCharacteristic[peripheral.uuidAsString()], bwt901bleRecordObserver: self.bwt901bleRecordObserver!)
                    peripherals[peripheral.uuidAsString()] = p
                    data.append(p.advertisingInfo())
                    peripheral.delegate = self
                }
                
                NotificationCenter.default.post(name: Notification.Name("WitBleManagerCentralManagerWillRestoreState"), object: nil, userInfo: ["peripherals": data])
            }
        }
    }
    
    
    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        NSLog("Peripheral Connected: \(peripheral.uuidAsString() )")
        peripheral.delegate = self
        
        /*
         The state of the peripheral isn't necessarily updated until a small
         delay after didConnectPeripheral is called and in the meantime
         didFailToConnectPeripheral may be called
         */
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: 0.002, repeats: false) { timer in
                // didFailToConnectPeripheral should have been called already if not connected by now
                self.invokeAndClearDictionary(&self.connectCallbacks, withKey: peripheral.uuidAsString(), usingParameters: [NSNull()])
                
                if self.hasListeners {
                    self.connectedPeripherals.insert(peripheral.uuidAsString())
                    self.sendEvent(withName: "WitBleManagerConnectPeripheral", body: ["peripheral": peripheral.uuidAsString()])
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let errorStr = "Peripheral connection failure: \(peripheral.uuidAsString() ) (\(error?.localizedDescription ?? "")"
        NSLog(errorStr)
        
        invokeAndClearDictionary(&connectCallbacks, withKey: peripheral.uuidAsString(), usingParameters: [errorStr])
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral:
                        CBPeripheral, error: Error?) {
        let peripheralUUIDString:String = peripheral.uuidAsString()
        NSLog("Peripheral Disconnected: \(peripheralUUIDString)")
        
        if let error = error {
            NSLog("Error: \(error)")
        }
        
        let errorStr = "Peripheral did disconnect: \(peripheralUUIDString)"
        
        invokeAndClearDictionary(&connectCallbacks, withKey: peripheralUUIDString, usingParameters: [errorStr])
        invokeAndClearDictionary(&readRSSICallbacks, withKey: peripheralUUIDString, usingParameters: [errorStr])
        invokeAndClearDictionary(&retrieveServicesCallbacks, withKey: peripheralUUIDString, usingParameters: [errorStr])
        
        
        for key in readCallbacks.keys {
            if let keyString = key as String?, keyString.hasPrefix(peripheralUUIDString) {
                invokeAndClearDictionary(&readCallbacks, withKey: key, usingParameters: [errorStr])
            }
        }
        
        for key in writeCallbacks.keys {
            if let keyString = key as String?, keyString.hasPrefix(peripheralUUIDString) {
                invokeAndClearDictionary(&writeCallbacks, withKey: key, usingParameters: [errorStr])
            }
        }
        
        for key in notificationCallbacks.keys {
            if let keyString = key as String?, keyString.hasPrefix(peripheralUUIDString) {
                invokeAndClearDictionary(&notificationCallbacks, withKey: key, usingParameters: [errorStr])
            }
        }
        
        for key in readDescriptorCallbacks.keys {
            if let keyString = key as String?, keyString.hasPrefix(peripheralUUIDString) {
                invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [errorStr])
            }
        }
        
        for key in stopNotificationCallbacks.keys {
            if let keyString = key as String?, keyString.hasPrefix(peripheralUUIDString) {
                invokeAndClearDictionary(&stopNotificationCallbacks, withKey: key, usingParameters: [errorStr])
            }
        }
        
        if hasListeners {
            connectedPeripherals.remove(peripheralUUIDString)
            if let e:Error = error {
                sendEvent(withName: "WitBleManagerDisconnectPeripheral", body: ["peripheral": peripheralUUIDString, "domain": e._domain, "code": e._code, "description": e.localizedDescription])
            } else {
                sendEvent(withName: "WitBleManagerDisconnectPeripheral", body: ["peripheral": peripheralUUIDString])
            }
        }
    }
    
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName = Helper.centralManagerStateToString(central.state)
        if hasListeners {
            sendEvent(withName: "WitBleManagerDidUpdateState", body: ["state": stateName])
        }
        if stateName == "off" {
            for peripheralUUID in connectedPeripherals {
                if let peripheral = peripherals[peripheralUUID] {
                    if peripheral.instance.state == .disconnected {
                        self.centralManager(manager!, didDisconnectPeripheral:peripheral.instance, error: nil)
                    }
                }
            }
        }
    }
    
    func handleDiscoveredPeripheral(_ peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi : NSNumber) {
        if WitBleManager.verboseLogging {
            NSLog("Discover peripheral: \(peripheral.name ?? "NO NAME")");
        }
        
        var cp: Peripheral? = nil
        serialQueue.sync {
            if let p = peripherals[peripheral.uuidAsString()] {
                cp = p
                cp?.setRSSI(rssi)
                cp?.setAdvertisementData(advertisementData)
            } else {
                cp = Peripheral(peripheral:peripheral, rssi:rssi, advertisementData:advertisementData, sendCharacteristic: sendCharacteristic[peripheral.uuidAsString()], bwt901bleRecordObserver: self.bwt901bleRecordObserver!)
                peripherals[peripheral.uuidAsString()] = cp
            }
        }
        
        if (hasListeners) {
            sendEvent(withName: "WitBleManagerDiscoverPeripheral", body: cp?.advertisingInfo())
        }
    }
        
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard peripheral.name != nil , peripheral.name!.contains("WT") else {
            return
        }
        
        if exactAdvertisingName.count > 0 {
            if let peripheralName = peripheral.name {
                if exactAdvertisingName.contains(peripheralName) {
                    handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
                } else {
                    if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                        if exactAdvertisingName.contains(localName) {
                            handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
                        }
                    }
                }
            }
        } else {
            handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
        }
        
        
    }
        
//    func peripheral(_ peripheral: CBPeripheral,
//                    didDiscoverServices error: Error?) {
//        if let error = error {
//            NSLog("Error: \(error)")
//            return
//        }
//        if WitBleManager.verboseLogging {
//            NSLog("Services Discover")
//        }
//        
//        // 遍历所有的服务
//        for service in peripheral.services! {
//            // 如果是指定的服务器ID则开始寻找特征值
//            // print("SERVICE UUID ID:\(service.uuid.uuidString.uppercased())")
//            // 如果是低功耗单模蓝牙
//            if service.uuid.uuidString.uppercased() == BLEUUID.UUID_SERVICE.uppercased() {
//                self.uuidService[peripheral.uuidAsString()] = BLEUUID.UUID_SERVICE
//                self.uuidRead[peripheral.uuidAsString()] = BLEUUID.UUID_READ
//                self.uuidSend[peripheral.uuidAsString()] = BLEUUID.UUID_SEND
//                peripheral.discoverCharacteristics(nil, for: service )
//            }
//            
//            // 如果是双模蓝牙
//            if service.uuid.uuidString == DualUUID.UUID_SERVICE {
//                self.uuidService[peripheral.uuidAsString()] = DualUUID.UUID_SERVICE
//                self.uuidRead[peripheral.uuidAsString()] = DualUUID.UUID_READ
//                self.uuidSend[peripheral.uuidAsString()] = DualUUID.UUID_SEND
//                peripheral.discoverCharacteristics(nil, for: service )
//            }
//        }
//        
//        var servicesForPeripheral = Set<CBService>()
//        servicesForPeripheral.formUnion(peripheral.services ?? [])
//        retrieveServicesLatches[peripheral.uuidAsString()] = servicesForPeripheral
//        
//        if let services = peripheral.services {
//            for service in services {
//                if WitBleManager.verboseLogging {
//                    NSLog("Service \(service.uuid.uuidString) \(service.description)")
//                }
//                peripheral.discoverIncludedServices(nil, for: service) // discover included services
//                peripheral.discoverCharacteristics(nil, for: service) // discover characteristics for service
//            }
//        }
//    }
//    
//    func peripheral(_ peripheral: CBPeripheral,
//                    didDiscoverIncludedServicesFor service: CBService,
//                    error: Error?) {
//        if let error = error {
//            NSLog("Error: \(error)")
//            return
//        }
//        peripheral.discoverCharacteristics(nil, for: service) // discover characteristics for included service
//    }
//        
//    func peripheral(_ peripheral: CBPeripheral,
//                    didDiscoverCharacteristicsFor service: CBService,
//                    error: Error?) {
//        if let error = error {
//            NSLog("Error: \(error)")
//            return
//        }
//        if WitBleManager.verboseLogging {
//            NSLog("Characteristics For Service Discover")
//        }
//        
//        for  characteristic in service.characteristics! {
//            print("找到设备特征值UUID：\(characteristic.uuid.description)")
//            switch characteristic.uuid.description.uppercased() {
//                case self.uuidRead[peripheral.uuidAsString()]:
//                    // 订阅特征值，订阅成功后后续所有的值变化都会自动通知
//                    peripheral.setNotifyValue(true, for: characteristic)
//                    break
//                case "******":
//                    // 读区特征值，只能读到一次
//                    peripheral.readValue(for:characteristic)
//                    break
//                case self.uuidSend[peripheral.uuidAsString()]:
//                    // 拿到写特征值
//                sendCharacteristic[peripheral.uuidAsString()] = characteristic
//                    break
//                default:
//                    // print("扫描到其他特征")
//                    break
//            }
//            
//        }
//        
//        var characteristicsForService = Set<CBCharacteristic>()
//        characteristicsForService.formUnion(service.characteristics ?? [])
//        characteristicsLatches[service.uuid.uuidString] = characteristicsForService
//        
//        if let characteristics = service.characteristics {
//            for characteristic in characteristics {
//                peripheral.discoverDescriptors(for: characteristic)
//            }
//        }
//    }
//    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            NSLog("Error: \(error)")
            return
        }
        let peripheralUUIDString:String = peripheral.uuidAsString()
        let serviceUUIDString:String = (characteristic.service?.uuid.uuidString)!
        
        if WitBleManager.verboseLogging {
            NSLog("Descriptor For Characteristic Discover \(serviceUUIDString) \(characteristic.uuid.uuidString)")
        }
        
        if var servicesLatch = retrieveServicesLatches[peripheralUUIDString], var characteristicsLatch = characteristicsLatches[serviceUUIDString] {
            
            characteristicsLatch.remove(characteristic)
            characteristicsLatches[serviceUUIDString] = characteristicsLatch
            
            if characteristicsLatch.isEmpty {
                // All characteristics for this service have been checked
                servicesLatch.remove(characteristic.service!)
                retrieveServicesLatches[peripheralUUIDString] = servicesLatch
                
                if servicesLatch.isEmpty {
                    // All characteristics and services have been checked
                    if let peripheral = peripherals[peripheral.uuidAsString()] {
                        invokeAndClearDictionary(&retrieveServicesCallbacks, withKey: peripheralUUIDString, usingParameters: [NSNull(), peripheral.servicesInfo()])
                    }
                    characteristicsLatches.removeValue(forKey: serviceUUIDString)
                    retrieveServicesLatches.removeValue(forKey: peripheralUUIDString)
                }
            }
            
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber,
                    error: Error?) {
        if WitBleManager.verboseLogging {
            print("didReadRSSI \(RSSI)")
        }
        
        if let error = error {
            invokeAndClearDictionary(&readRSSICallbacks, withKey: peripheral.uuidAsString(), usingParameters: [error.localizedDescription, RSSI])
        } else {
            invokeAndClearDictionary(&readRSSICallbacks, withKey: peripheral.uuidAsString(), usingParameters: [NSNull(), RSSI])
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        let key = Helper.key(forPeripheral: peripheral, andCharacteristic: descriptor.characteristic!, andDescriptor: descriptor)
        
        if let error = error {
            NSLog("Error reading descriptor value for \(descriptor.uuid) on characteristic \(descriptor.characteristic!.uuid) :\(error)")
            invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [error.localizedDescription, NSNull()])
            return
        }
        
        if let descriptorValue = descriptor.value as? Data {
            NSLog("Read value [descriptor: \(descriptor.uuid), characteristic: \(descriptor.characteristic!.uuid)]: (\(descriptorValue.count)) \(descriptorValue.hexadecimalString())")
        } else {
            NSLog("Read value [descriptor: \(descriptor.uuid), characteristic: \(descriptor.characteristic!.uuid)]: \(String(describing: descriptor.value))")
        }
        
        if readDescriptorCallbacks[key] != nil {
            // The most future proof way of doing this that I could find, other option would be running strcmp on CBUUID strings
            // https://developer.apple.com/documentation/corebluetooth/cbuuid/characteristic_descriptors
            if let descriptorValue = descriptor.value as? Data {
                if (WitBleManager.verboseLogging) {
                    NSLog("Descriptor value is Data")
                }
                invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [NSNull(), descriptorValue.toArray()])
            } else if let descriptorValue = descriptor.value as? NSNumber {
                if (WitBleManager.verboseLogging) {
                    NSLog("Descriptor value is NSNumber")
                }
                var value = descriptorValue.uint64Value
                let byteData = Data(bytes: &value, count: MemoryLayout.size(ofValue: value))
                invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [NSNull(), byteData.toArray()])
            } else if let descriptorValue = descriptor.value as? String {
                if (WitBleManager.verboseLogging) {
                    NSLog("Descriptor value is String")
                }
                if let byteData = descriptorValue.data(using: .utf8) {
                    invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [NSNull(), byteData.toArray()])
                }
            } else {
                NSLog("Unrecognized type of descriptor: (UUID: \(descriptor.uuid), value type: \(type(of: descriptor.value)), value: \(String(describing: descriptor.value)))")
                if let descriptorValue = descriptor.value as? Data {
                    invokeAndClearDictionary(&readDescriptorCallbacks, withKey: key, usingParameters: [NSNull(), descriptorValue.toArray()])
                }
            }
        }
    }
    
//    func peripheral(_ peripheral: CBPeripheral,
//                    didUpdateValueFor characteristic: CBCharacteristic,
//                    error: Error?) {
//        let key = Helper.key(forPeripheral: peripheral, andCharacteristic: characteristic)
//        
//        if let error = error {
//            NSLog("Error \(characteristic.uuid) :\(error)")
//            invokeAndClearDictionary(&readCallbacks, withKey: key, usingParameters: [error.localizedDescription, NSNull()])
//            return
//        }
//        
//        if WitBleManager.verboseLogging, let value = characteristic.value {
//            NSLog("Read value [\(characteristic.uuid)]: \( value.hexadecimalString())")
//        }
//        
//        serialQueue.sync {
//            if readCallbacks[key] != nil {
//                invokeAndClearDictionary_THREAD_UNSAFE(&readCallbacks, withKey: key, usingParameters: [NSNull(), characteristic.value!.toArray()])
//            } else {
//                if hasListeners {
//                    sendEvent(withName: "WitBleManagerDidUpdateValueForCharacteristic", body: [
//                        "peripheral": peripheral.uuidAsString(),
//                        "characteristic": characteristic.uuid.uuidString.lowercased(),
//                        "service": characteristic.service!.uuid.uuidString.lowercased(),
//                        "value": characteristic.value!.toArray()
//                    ])
//                }
//            }
//        }
//    }
//    
//    func peripheral(_ peripheral: CBPeripheral,
//                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
//                    error: Error?) {
//        if let error = error {
//            NSLog("Error in didUpdateNotificationStateForCharacteristic: \(error)")
//            
//            if hasListeners {
//                sendEvent(withName: "WitBleManagerDidUpdateNotificationStateFor", body: [
//                    "peripheral": peripheral.uuidAsString(),
//                    "characteristic": characteristic.uuid.uuidString.lowercased(),
//                    "isNotifying": false,
//                    "domain": error._domain,
//                    "code": error._code
//                ])
//            }
//        } else {
//            if hasListeners {
//                sendEvent(withName: "WitBleManagerDidUpdateNotificationStateFor", body: [
//                    "peripheral": peripheral.uuidAsString(),
//                    "characteristic": characteristic.uuid.uuidString.lowercased(),
//                    "isNotifying": characteristic.isNotifying
//                ])
//            }
//        }
//        
//        let key = Helper.key(forPeripheral: peripheral, andCharacteristic: characteristic)
//        
//        if let error = error {
//            if notificationCallbacks[key] != nil {
//                invokeAndClearDictionary(&notificationCallbacks, withKey: key, usingParameters: [error])
//            }
//            if stopNotificationCallbacks[key] != nil {
//                invokeAndClearDictionary(&stopNotificationCallbacks, withKey: key, usingParameters: [error])
//            }
//        } else {
//            if characteristic.isNotifying {
//                if WitBleManager.verboseLogging {
//                    NSLog("Notification began on \(characteristic.uuid)")
//                }
//                if notificationCallbacks[key] != nil {
//                    invokeAndClearDictionary(&notificationCallbacks, withKey: key, usingParameters: [])
//                }
//            } else {
//                // Notification has stopped
//                if WitBleManager.verboseLogging {
//                    NSLog("Notification ended on \(characteristic.uuid)")
//                }
//                if stopNotificationCallbacks[key] != nil {
//                    invokeAndClearDictionary(&stopNotificationCallbacks, withKey: key, usingParameters: [])
//                }
//            }
//        }
//        
//        switch characteristic.uuid.uuidString.uppercased() {
//            case self.uuidRead[peripheral.uuidAsString()]:
//                let bytes:[UInt8]? = characteristic.value?.dataToBytes()
//                if bytes != nil {
//                    // 调用要接收数据的对象
//                    findPeripheral(byUUID: peripheral.uuidAsString())?.invokeDataRecevied(data: bytes ?? [UInt8]())
//                }
//                break
//            default:
//                print("收到了其他数据特征数据: \(characteristic.uuid.uuidString)")
//                break
//        }
//    }
//    
//    func peripheral(_ peripheral: CBPeripheral,
//                    didWriteValueFor descriptor: CBDescriptor,
//                    error: Error?) {
//        NSLog("didWrite descriptor")
//        
//        let key = Helper.key(forPeripheral: peripheral, andCharacteristic: descriptor.characteristic!, andDescriptor: descriptor)
//        let callbacks = writeDescriptorCallbacks[key]
//        if callbacks != nil {
//            if let error = error {
//                NSLog("\(error)")
//                invokeAndClearDictionary(&writeDescriptorCallbacks, withKey: key, usingParameters: [error.localizedDescription])
//            } else {
//                invokeAndClearDictionary(&writeDescriptorCallbacks, withKey: key, usingParameters: [])
//            }
//        }
//    }
//    
//    func peripheral(_ peripheral: CBPeripheral,
//                    didWriteValueFor characteristic: CBCharacteristic,
//                    error: Error?) {
//        NSLog("didWrite")
//        
//        let key = Helper.key(forPeripheral:peripheral, andCharacteristic: characteristic)
//        let peripheralWriteCallbacks = writeCallbacks[key]
//        
//        if peripheralWriteCallbacks != nil {
//            if let error = error {
//                NSLog("\(error)")
//                invokeAndClearDictionary(&writeCallbacks, withKey: key, usingParameters: [error.localizedDescription])
//            } else {
//                if writeQueue.isEmpty {
//                    invokeAndClearDictionary(&writeCallbacks, withKey: key, usingParameters: [])
//                } else {
//                    let message = writeQueue.removeFirst() as! Data
//                    NSLog("Message to write \(message.hexadecimalString())")
//                    peripheral.writeValue(message, for: characteristic, type: .withResponse)
//                }
//            }
//        }
//    }
    
    //  MARK: - 匹配对应服务UUID
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?){
        
        if error != nil {
            return
        }
        
        // 遍历所有的服务
        for service in peripheral.services! {
            // 如果是指定的服务器ID则开始寻找特征值
            // print("SERVICE UUID ID:\(service.uuid.uuidString.uppercased())")
            // 如果是低功耗单模蓝牙
            if service.uuid.uuidString.uppercased() == BLEUUID.UUID_SERVICE.uppercased() {
                self.uuidService[peripheral.uuidAsString()] = BLEUUID.UUID_SERVICE
                self.uuidRead[peripheral.uuidAsString()] = BLEUUID.UUID_READ
                self.uuidSend[peripheral.uuidAsString()] = BLEUUID.UUID_SEND
                peripheral.discoverCharacteristics(nil, for: service )
            }
            
            // 如果是双模蓝牙
            if service.uuid.uuidString == DualUUID.UUID_SERVICE {
                self.uuidService[peripheral.uuidAsString()] = DualUUID.UUID_SERVICE
                self.uuidRead[peripheral.uuidAsString()] = DualUUID.UUID_READ
                self.uuidSend[peripheral.uuidAsString()] = DualUUID.UUID_SEND
                peripheral.discoverCharacteristics(nil, for: service )
            }
        }
        
        var servicesForPeripheral = Set<CBService>()
        servicesForPeripheral.formUnion(peripheral.services ?? [])
        retrieveServicesLatches[peripheral.uuidAsString()] = servicesForPeripheral

        if let services = peripheral.services {
            for service in services {
                if WitBleManager.verboseLogging {
                    NSLog("Service \(service.uuid.uuidString) \(service.description)")
                }
                peripheral.discoverIncludedServices(nil, for: service) // discover included services
                peripheral.discoverCharacteristics(nil, for: service) // discover characteristics for service
            }
        }
    }
    
    //MARK: - 服务下的特征
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?){
        
        if (error != nil){
            return
        }
                        
        for  characteristic in service.characteristics! {
            print("找到设备特征值UUID：\(characteristic.uuid.description)")
            switch characteristic.uuid.description.uppercased() {
                case self.uuidRead[peripheral.uuidAsString()]:
                    // 订阅特征值，订阅成功后后续所有的值变化都会自动通知
                    peripheral.setNotifyValue(true, for: characteristic)
                    break
                case "******":
                    // 读区特征值，只能读到一次
                    peripheral.readValue(for:characteristic)
                    break
                case self.uuidSend[peripheral.uuidAsString()]:
                    // 拿到写特征值
                    sendCharacteristic[peripheral.uuidAsString()] = characteristic
                    findPeripheral(byUUID: peripheral.uuidAsString())?.setSendCharacteristic(sendCharacteristic: characteristic)
                    break
                default:
                    // print("扫描到其他特征")
                    break
            }
            
        }
        
        var characteristicsForService = Set<CBCharacteristic>()
        characteristicsForService.formUnion(service.characteristics ?? [])
        characteristicsLatches[service.uuid.uuidString] = characteristicsForService

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
    }
    
    //MARK: - 特征的订阅状体发生变化
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?){
        
        guard error == nil  else {
            return
        }
        
    }
    
    // MARK: - 获取外设发来的数据
    // 注意，所有的，不管是 read , notify 的特征的值都是在这里读取
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)-> (){
        
        if(error != nil){
            return
        }
                
        switch characteristic.uuid.uuidString.uppercased() {
            
        case self.uuidRead[peripheral.uuidAsString()]:
//            // 打印收到数据的时间戳
//            let dformatter = DateFormatter()
//            dformatter.dateFormat = "yyyyMMdd-HH.mm.ss"
//            let current = Date()
//            let dateString = dformatter.string(from: current) + ".\((CLongLong(round(current.timeIntervalSince1970*1000)) % 1000))"
//            print(dateString)
            
            // print("接收到了设备的数据: \(String(describing: characteristic.value?.dataToHex()))")
            let bytes:[UInt8]? = characteristic.value?.dataToBytes()
            if bytes != nil {
                // 调用要接收数据的对象
                findPeripheral(byUUID: peripheral.uuidAsString())?.invokeDataRecevied(data: bytes ?? [UInt8]())
            }
            break
        default:
            print("收到了其他数据特征数据: \(characteristic.uuid.uuidString)")
            break
        }

        let key = Helper.key(forPeripheral: peripheral, andCharacteristic: characteristic)
        
        if let error = error {
            NSLog("Error \(characteristic.uuid) :\(error)")
            invokeAndClearDictionary(&readCallbacks, withKey: key, usingParameters: [error.localizedDescription, NSNull()])
            return
        }
        
        if WitBleManager.verboseLogging, let value = characteristic.value {
            NSLog("Read value [\(characteristic.uuid)]: \( value.hexadecimalString())")
        }
        
        serialQueue.sync {
            if readCallbacks[key] != nil {
                invokeAndClearDictionary_THREAD_UNSAFE(&readCallbacks, withKey: key, usingParameters: [NSNull(), characteristic.value!.toArray()])
            } else {
                if hasListeners {
                    sendEvent(withName: "WitBleManagerDidUpdateValueForCharacteristic", body: [
                        "peripheral": peripheral.uuidAsString(),
                        "characteristic": characteristic.uuid.uuidString.lowercased(),
                        "service": characteristic.service!.uuid.uuidString.lowercased(),
                        "value": characteristic.value!.toArray(),
                    ])
                }
            }
        }        
    }
    
    
    
    //MARK: - 检测中心向外设写数据是否成功
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if(error != nil){
            print("发送数据失败!error信息: \(String(describing: error))")
        }
    }
    
    static func getCentralManager() -> CBCentralManager? {
        return sharedManager
    }
    
    static func getInstance() -> WitBleManager? {
        return shared
    }
    
    @objc func enableBluetooth(_ callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func getBondedPeripherals(_ callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func createBond(_ peripheralUUID: String,
                          devicePin: String,
                          callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func removeBond(_ peripheralUUID: String,
                          callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func removePeripheral(_ peripheralUUID: String,
                                callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func requestMTU(_ peripheralUUID: String,
                          mtu: Int,
                          callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func requestConnectionPriority(_ peripheralUUID: String,
                                         mtu: Int,
                                         callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func refreshCache(_ peripheralUUID: String,
                            callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func setName(_ name: String,
                       callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func getAssociatedPeripherals(_ callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func removeAssociatedPeripheral(_ peripheralUUID: String,
                                          callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc func supportsCompanion(_ callback: @escaping RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
    
    @objc public func companionScan(_ serviceUUIDs: [Any],
                                    callback:RCTResponseSenderBlock) {
        callback(["Not supported"])
    }
}

