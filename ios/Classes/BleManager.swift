import CoreBluetooth
import Flutter

class BleManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private static let escPosServiceUUID = CBUUID(string: "000018f0-0000-1000-8000-00805f9b34fb")
    private static let escPosTxCharUUID = CBUUID(string: "00002af1-0000-1000-8000-00805f9b34fb")

    private var centralManager: CBCentralManager?
    private var scanEventSink: FlutterEventSink?
    private var discoveredDevices: [[String: String]] = []
    private var scanTimer: Timer?

    // Per-device connection state, keyed by peripheral UUID string
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var txCharacteristics: [String: CBCharacteristic] = [:]
    private var notifyCharacteristics: [String: CBCharacteristic] = [:]
    private var mtuPayloads: [String: Int] = [:]
    private var canWriteWithoutResponses: [String: Bool] = [:]
    private var connectResults: [String: FlutterResult] = [:]
    private var writeResults: [String: FlutterResult] = [:]
    private var pendingWriteDatas: [String: Data] = [:]
    private var pendingWriteResults: [String: FlutterResult] = [:]
    private var connectTimers: [String: Timer] = [:]
    private var writeTimeoutWorkItems: [String: DispatchWorkItem] = [:]
    private var targetServiceUUIDs: [String: CBUUID] = [:]
    private var targetCharUUIDs: [String: CBUUID] = [:]

    /// Backstop timeout for a single BLE write. CoreBluetooth resolves a
    /// write only via `didWriteValueFor` (with-response) or
    /// `peripheralIsReady` (without-response, buffer-full path); if the
    /// printer stalls or vanishes without ever firing `didDisconnectPeripheral`,
    /// neither callback arrives and the FlutterResult would leak — hanging
    /// the Dart-side `await bleWrite` forever. This bounds that wait.
    private let writeTimeoutSeconds: TimeInterval = 8.0

    var connectionStateCallback: ((String, String) -> Void)?
    var incomingBytesCallback: ((String, Data) -> Void)?

    /// Continuations waiting for CBCentralManager to leave the `.unknown` state.
    /// Each is called with `true` when the state becomes `.poweredOn`, or
    /// `false` on any other resolved state / timeout.
    private var poweredOnContinuations: [(Bool) -> Void] = []

    // Lazy init to avoid triggering the BT permission dialog on plugin load
    private func ensureCentralManager() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    /// Waits for the CBCentralManager to reach `.poweredOn`.
    ///
    /// - If already `.poweredOn`, calls `completion(true)` synchronously.
    /// - If the state is `.unknown` (adapter still initialising), queues the
    ///   completion and resolves it once `centralManagerDidUpdateState` fires.
    /// - Falls back to `completion(false)` after [timeout] seconds.
    private func waitForPoweredOn(timeout: TimeInterval = 5.0,
                                  completion: @escaping (Bool) -> Void) {
        guard let cm = centralManager else {
            completion(false)
            return
        }

        if cm.state == .poweredOn {
            completion(true)
            return
        }

        // Already resolved to a non-poweredOn state — fail immediately.
        if cm.state != .unknown {
            completion(false)
            return
        }

        // State is .unknown — manager is still initialising, wait for update.
        var resolved = false
        let resolve: (Bool) -> Void = { isPoweredOn in
            guard !resolved else { return }
            resolved = true
            completion(isPoweredOn)
        }

        poweredOnContinuations.append(resolve)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            resolve(false)
        }
    }

    lazy var scanStreamHandler: FlutterStreamHandler = {
        return BleScanStreamHandler(manager: self)
    }()

    func setScanEventSink(_ sink: FlutterEventSink?) {
        scanEventSink = sink
    }

    func requestPermissions(result: @escaping FlutterResult) {
        ensureCentralManager()
        if #available(iOS 13.1, *) {
            switch CBCentralManager.authorization {
            case .allowedAlways:
                result(true)
            case .notDetermined:
                result(true)
            case .denied, .restricted:
                result(false)
            @unknown default:
                result(true)
            }
        } else {
            result(centralManager?.state == .poweredOn)
        }
    }

    func getBondedBleDevices(result: @escaping FlutterResult) {
        ensureCentralManager()
        guard let cm = centralManager, cm.state == .poweredOn else {
            result([[[String: String]]]())
            return
        }

        let connected = cm.retrieveConnectedPeripherals(withServices: [
            BleManager.escPosServiceUUID
        ])

        let devices: [[String: String]] = connected.map { peripheral in
            [
                "deviceId": peripheral.identifier.uuidString,
                "name": peripheral.name ?? peripheral.identifier.uuidString
            ]
        }
        result(devices)
    }

    func startScan(timeoutMs: Int, result: @escaping FlutterResult) {
        ensureCentralManager()

        waitForPoweredOn { [weak self] isPoweredOn in
            guard let self = self, let cm = self.centralManager, isPoweredOn else {
                result(FlutterError(code: "UNAVAILABLE", message: "Bluetooth is not powered on", details: nil))
                return
            }

            self.discoveredDevices.removeAll()
            cm.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])

            let timeout = Double(timeoutMs) / 1000.0
            self.scanTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.stopScanInternal()
            }

            result(nil)
        }
    }

    func stopScan(result: @escaping FlutterResult) {
        stopScanInternal()
        result(nil)
    }

    private func stopScanInternal() {
        scanTimer?.invalidate()
        scanTimer = nil
        centralManager?.stopScan()
        // Signal Flutter that no more scan events are coming. Closes the
        // Dart-side broadcast stream gracefully so a subsequent
        // subscription.cancel() becomes a no-op instead of producing
        // "No active stream to cancel" noise in services-library logs
        // (and Crashlytics).
        DispatchQueue.main.async {
            self.scanEventSink?(FlutterEndOfEventStream)
            self.scanEventSink = nil
        }
    }

    func connect(deviceId: String, timeoutMs: Int, serviceUuid: String?, characteristicUuid: String?, result: @escaping FlutterResult) {
        ensureCentralManager()

        waitForPoweredOn { [weak self] isPoweredOn in
            guard let self = self, let cm = self.centralManager, isPoweredOn else {
                result(FlutterError(code: "UNAVAILABLE", message: "Bluetooth is not powered on", details: nil))
                return
            }

            guard let uuid = UUID(uuidString: deviceId) else {
                result(FlutterError(code: "INVALID_DEVICE", message: "Invalid device UUID: \(deviceId)", details: nil))
                return
            }

            self.targetServiceUUIDs[deviceId] = serviceUuid != nil ? CBUUID(string: serviceUuid!) : BleManager.escPosServiceUUID
            self.targetCharUUIDs[deviceId] = characteristicUuid != nil ? CBUUID(string: characteristicUuid!) : BleManager.escPosTxCharUUID

            let peripherals = cm.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                result(FlutterError(code: "NOT_FOUND", message: "Peripheral not found for UUID: \(deviceId)", details: nil))
                return
            }

            // Clean up any existing connection
            self.cleanupConnection(deviceId)

            self.connectResults[deviceId] = result
            self.connectedPeripherals[deviceId] = peripheral
            peripheral.delegate = self

            cm.connect(peripheral, options: nil)

            // Timeout
            let timeout = Double(timeoutMs) / 1000.0
            self.connectTimers[deviceId] = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                guard let self = self, self.connectResults[deviceId] != nil else { return }
                cm.cancelPeripheralConnection(peripheral)
                self.connectResults.removeValue(forKey: deviceId)?(FlutterError(code: "TIMEOUT", message: "BLE connection timed out", details: nil))
                self.connectedPeripherals.removeValue(forKey: deviceId)
            }
        }
    }

    func getMtu(deviceId: String, result: @escaping FlutterResult) {
        result(mtuPayloads[deviceId] ?? 20)
    }

    func supportsWriteWithoutResponse(deviceId: String, result: @escaping FlutterResult) {
        result(canWriteWithoutResponses[deviceId] ?? false)
    }

    func write(deviceId: String, data: Data, withoutResponse: Bool, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId], let char = txCharacteristics[deviceId] else {
            result(FlutterError(code: "NOT_CONNECTED", message: "BLE device not connected: \(deviceId)", details: nil))
            return
        }

        // Fast path: buffer has room, the write is fire-and-forget, so it
        // can never stall waiting on a callback — resolve immediately.
        if withoutResponse && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
            result(nil)
            return
        }

        // One-shot guard so neither the CoreBluetooth callback, the
        // backstop timeout, nor a disconnect cleanup can resolve the same
        // FlutterResult twice.
        var settled = false
        let settle: FlutterResult = { [weak self] value in
            guard !settled else { return }
            settled = true
            self?.writeTimeoutWorkItems.removeValue(forKey: deviceId)?.cancel()
            result(value)
        }

        if withoutResponse {
            pendingWriteDatas[deviceId] = data
            pendingWriteResults[deviceId] = settle
        } else {
            writeResults[deviceId] = settle
            peripheral.writeValue(data, for: char, type: .withResponse)
        }

        // Backstop: fail the write if no callback arrives in time so the
        // Dart-side await can't hang forever on a silently stalled link.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.writeResults.removeValue(forKey: deviceId)
            self.pendingWriteResults.removeValue(forKey: deviceId)
            self.pendingWriteDatas.removeValue(forKey: deviceId)
            settle(FlutterError(code: "WRITE_FAILED", message: "BLE write timed out", details: nil))
        }
        writeTimeoutWorkItems[deviceId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeoutSeconds, execute: workItem)
    }

    /// Sends DLE EOT status query via write-with-response.  The write ACK
    /// confirms the printer's GATT server received the data.
    func queryStatus(deviceId: String, timeoutMs: Int, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId], let char = txCharacteristics[deviceId] else {
            result(FlutterError(code: "NOT_CONNECTED", message: "BLE device not connected: \(deviceId)", details: nil))
            return
        }

        let dleEot = Data([0x10, 0x04, 0x01])
        var responded = false

        // didWriteValueFor will call writeResults[deviceId] which we set here.
        writeResults[deviceId] = { [weak self] writeResult in
            guard !responded else { return }
            responded = true
            self?.writeResults.removeValue(forKey: deviceId)
            if let error = writeResult as? FlutterError {
                result(-1)
            } else {
                result(0)
            }
        }
        peripheral.writeValue(dleEot, for: char, type: .withResponse)

        // Timeout fallback
        let timeoutSec = Double(timeoutMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
            guard !responded else { return }
            responded = true
            self?.writeResults.removeValue(forKey: deviceId)
            result(-1)
        }
    }

    func disconnect(deviceId: String, result: @escaping FlutterResult) {
        if let peripheral = connectedPeripherals[deviceId], let cm = centralManager {
            cm.cancelPeripheralConnection(peripheral)
        }
        cleanupConnection(deviceId)
        connectionStateCallback?(deviceId, "disconnected")
        result(nil)
    }

    private func cleanupConnection(_ deviceId: String) {
        connectTimers.removeValue(forKey: deviceId)?.invalidate()
        writeTimeoutWorkItems.removeValue(forKey: deviceId)?.cancel()
        // Fail any in-flight write so the Dart-side `await bleWrite`
        // throws immediately on disconnect instead of leaking the
        // FlutterResult and hanging the print job forever. The settle
        // guard makes a double-resolution (callback already fired) a
        // no-op, so this is safe to call unconditionally.
        let disconnectError = FlutterError(code: "DISCONNECTED", message: "BLE device disconnected during write", details: nil)
        writeResults.removeValue(forKey: deviceId)?(disconnectError)
        pendingWriteResults.removeValue(forKey: deviceId)?(disconnectError)
        // Disable notifications on the cached notify characteristic, if
        // any, before dropping the reference. iOS Core Bluetooth keeps
        // a subscription on the peripheral even after we let go of the
        // characteristic object — leaving stale notifications running
        // would feed bytes to nobody and confuse the next reconnect.
        if let peripheral = connectedPeripherals[deviceId],
           let nf = notifyCharacteristics[deviceId],
           peripheral.state == .connected {
            peripheral.setNotifyValue(false, for: nf)
        }
        connectedPeripherals.removeValue(forKey: deviceId)
        txCharacteristics.removeValue(forKey: deviceId)
        notifyCharacteristics.removeValue(forKey: deviceId)
        mtuPayloads.removeValue(forKey: deviceId)
        canWriteWithoutResponses.removeValue(forKey: deviceId)
        pendingWriteDatas.removeValue(forKey: deviceId)
        pendingWriteResults.removeValue(forKey: deviceId)
        connectResults.removeValue(forKey: deviceId)
        writeResults.removeValue(forKey: deviceId)
        targetServiceUUIDs.removeValue(forKey: deviceId)
        targetCharUUIDs.removeValue(forKey: deviceId)
    }

    /// Resolve the deviceId (peripheral UUID string) for a given CBPeripheral.
    private func deviceId(for peripheral: CBPeripheral) -> String {
        return peripheral.identifier.uuidString
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Resolve any pending "wait for powered on" continuations.
        if central.state != .unknown {
            let isPoweredOn = central.state == .poweredOn
            let pending = poweredOnContinuations
            poweredOnContinuations.removeAll()
            for continuation in pending {
                continuation(isPoweredOn)
            }
        }
        // If BT turns off, ongoing connections will trigger
        // didDisconnectPeripheral automatically.
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        if !discoveredDevices.contains(where: { $0["deviceId"] == id }) {
            discoveredDevices.append([
                "deviceId": id,
                "name": peripheral.name ?? id
            ])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scanEventSink?(self.discoveredDevices)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = deviceId(for: peripheral)
        connectTimers.removeValue(forKey: id)?.invalidate()
        connectResults.removeValue(forKey: id)?(FlutterError(code: "CONNECTION_FAILED", message: "Failed to connect: \(error?.localizedDescription ?? "unknown")", details: nil))
        connectedPeripherals.removeValue(forKey: id)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = deviceId(for: peripheral)
        if connectResults[id] != nil {
            connectTimers.removeValue(forKey: id)?.invalidate()
            connectResults.removeValue(forKey: id)?(FlutterError(code: "DISCONNECTED", message: "Disconnected during setup", details: nil))
        } else {
            // Remote disconnection
            connectionStateCallback?(id, "disconnected")
        }
        cleanupConnection(id)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = deviceId(for: peripheral)
        if let error = error {
            connectTimers.removeValue(forKey: id)?.invalidate()
            centralManager?.cancelPeripheralConnection(peripheral)
            connectResults.removeValue(forKey: id)?(FlutterError(code: "SERVICE_DISCOVERY_FAILED", message: error.localizedDescription, details: nil))
            return
        }

        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = deviceId(for: peripheral)
        if error != nil { return }

        guard txCharacteristics[id] == nil else { return } // Already found

        var txChar: CBCharacteristic?
        var notifyChar: CBCharacteristic?

        // 1. Try target service/characteristic UUIDs first.
        if let targetSvc = targetServiceUUIDs[id], service.uuid == targetSvc,
           let chars = service.characteristics {
            for c in chars {
                if txChar == nil && c.uuid == targetCharUUIDs[id] && isWritable(c) {
                    txChar = c
                }
                if notifyChar == nil && isNotifiable(c) {
                    notifyChar = c
                }
            }
        }

        // 2. Fallback: any writable characteristic on this service, plus
        //    any notifiable sibling for ASB / status pushes.
        if txChar == nil, let chars = service.characteristics {
            for c in chars {
                if txChar == nil && isWritable(c) {
                    txChar = c
                }
                if notifyChar == nil && isNotifiable(c) {
                    notifyChar = c
                }
            }
        }

        guard let tx = txChar else { return }

        if let nf = notifyChar {
            notifyCharacteristics[id] = nf
            peripheral.setNotifyValue(true, for: nf)
        }

        selectCharacteristic(tx, peripheral: peripheral)
    }

    private func selectCharacteristic(_ char: CBCharacteristic, peripheral: CBPeripheral) {
        let id = deviceId(for: peripheral)
        txCharacteristics[id] = char
        // Prefer write-without-response whenever the characteristic supports
        // it, even if it also advertises write-with-response. Most ESC/POS
        // printers expose both; with-response forces a per-chunk ATT ACK
        // round-trip (and a prepared/long-write sequence for chunks > MTU),
        // sending only one packet per connection event — an order of
        // magnitude slower. Without-response lets iOS pipeline several
        // packets per event with flow control via
        // peripheralIsReady(toSendWriteWithoutResponse:).
        let useWithoutResponse = char.properties.contains(.writeWithoutResponse)
        canWriteWithoutResponses[id] = useWithoutResponse

        let writeType: CBCharacteristicWriteType = useWithoutResponse ? .withoutResponse : .withResponse
        mtuPayloads[id] = peripheral.maximumWriteValueLength(for: writeType)

        connectTimers.removeValue(forKey: id)?.invalidate()
        connectResults.removeValue(forKey: id)?(nil)
        connectionStateCallback?(id, "connected")
    }

    /// Forwards bytes from a subscribed notify / indicate characteristic to
    /// the Dart side via [incomingBytesCallback]. Consumed by the per-
    /// connector AsbMonitor to parse Automatic Status Back (ESC/POS
    /// `GS a`) packets.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { return }
        guard let value = characteristic.value, !value.isEmpty else { return }
        let id = deviceId(for: peripheral)
        // Copy the value to break any aliasing with the underlying Core
        // Bluetooth buffer before we hop to the main queue.
        let payload = Data(value)
        if let cb = incomingBytesCallback {
            DispatchQueue.main.async {
                cb(id, payload)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = deviceId(for: peripheral)
        if let error = error {
            writeResults.removeValue(forKey: id)?(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
        } else {
            writeResults.removeValue(forKey: id)?(nil)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let id = deviceId(for: peripheral)
        guard let data = pendingWriteDatas.removeValue(forKey: id),
              let char = txCharacteristics[id] else { return }
        let result = pendingWriteResults.removeValue(forKey: id)
        peripheral.writeValue(data, for: char, type: .withoutResponse)
        result?(nil)
    }

    private func isWritable(_ c: CBCharacteristic) -> Bool {
        return c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
    }

    private func isNotifiable(_ c: CBCharacteristic) -> Bool {
        return c.properties.contains(.notify) || c.properties.contains(.indicate)
    }
}

class BleScanStreamHandler: NSObject, FlutterStreamHandler {
    private weak var manager: BleManager?

    init(manager: BleManager) {
        self.manager = manager
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        manager?.setScanEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        manager?.setScanEventSink(nil)
        return nil
    }
}
