import Flutter
import UIKit

public class UnifiedEscPosPrinterPlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var bleScanEventChannel: FlutterEventChannel?
    private var connectionStateEventChannel: FlutterEventChannel?
    private var incomingBytesEventChannel: FlutterEventChannel?

    private var bleManager: BleManager?
    private var connectionStateHandler: ConnectionStateStreamHandler?
    private var incomingBytesHandler: IncomingBytesStreamHandler?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = UnifiedEscPosPrinterPlugin()
        instance.setup(with: registrar)
    }

    private func setup(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()

        methodChannel = FlutterMethodChannel(
            name: "com.elriztechnology.unified_esc_pos_printer/methods",
            binaryMessenger: messenger
        )
        methodChannel?.setMethodCallHandler(handle)

        bleManager = BleManager()

        bleScanEventChannel = FlutterEventChannel(
            name: "com.elriztechnology.unified_esc_pos_printer/ble_scan",
            binaryMessenger: messenger
        )
        let scanHandler: (FlutterStreamHandler & NSObjectProtocol)? = bleManager?.scanStreamHandler as? (FlutterStreamHandler & NSObjectProtocol)
        bleScanEventChannel?.setStreamHandler(scanHandler)

        // BT scan channel — not supported on iOS, use a no-op handler
        let btScanEventChannel = FlutterEventChannel(
            name: "com.elriztechnology.unified_esc_pos_printer/bt_scan",
            binaryMessenger: messenger
        )
        btScanEventChannel.setStreamHandler(NoOpStreamHandler())

        connectionStateHandler = ConnectionStateStreamHandler(bleManager: bleManager!)
        connectionStateEventChannel = FlutterEventChannel(
            name: "com.elriztechnology.unified_esc_pos_printer/connection_state",
            binaryMessenger: messenger
        )
        connectionStateEventChannel?.setStreamHandler(connectionStateHandler)

        // Incoming bytes channel — receives BLE notify-characteristic
        // pushes (iOS doesn't support Bluetooth Classic so there's no
        // BT-side input). Used by the Dart-side AsbMonitor to parse
        // Automatic Status Back (ESC/POS `GS a`) packets and surface
        // paper-out / cover-open events before they tank a print job.
        incomingBytesHandler = IncomingBytesStreamHandler(bleManager: bleManager!)
        incomingBytesEventChannel = FlutterEventChannel(
            name: "com.elriztechnology.unified_esc_pos_printer/incoming_bytes",
            binaryMessenger: messenger
        )
        incomingBytesEventChannel?.setStreamHandler(incomingBytesHandler)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        // Permissions
        case "requestPermissions":
            bleManager?.requestPermissions(result: result)

        // BLE
        case "startBleScan":
            let timeoutMs = args?["timeoutMs"] as? Int ?? 5000
            bleManager?.startScan(timeoutMs: timeoutMs, result: result)
        case "stopBleScan":
            bleManager?.stopScan(result: result)
        case "getBondedBleDevices":
            bleManager?.getBondedBleDevices(result: result)
        case "bleConnect":
            let deviceId = args?["deviceId"] as? String ?? ""
            let timeoutMs = args?["timeoutMs"] as? Int ?? 10000
            let serviceUuid = args?["serviceUuid"] as? String
            let characteristicUuid = args?["characteristicUuid"] as? String
            bleManager?.connect(
                deviceId: deviceId,
                timeoutMs: timeoutMs,
                serviceUuid: serviceUuid,
                characteristicUuid: characteristicUuid,
                result: result
            )
        case "bleGetMtu":
            let deviceId = args?["deviceId"] as? String ?? ""
            bleManager?.getMtu(deviceId: deviceId, result: result)
        case "bleSupportsWriteWithoutResponse":
            let deviceId = args?["deviceId"] as? String ?? ""
            bleManager?.supportsWriteWithoutResponse(deviceId: deviceId, result: result)
        case "bleWrite":
            let deviceId = args?["deviceId"] as? String ?? ""
            let data = (args?["data"] as? FlutterStandardTypedData)?.data ?? Data()
            let withoutResponse = args?["withoutResponse"] as? Bool ?? false
            bleManager?.write(deviceId: deviceId, data: data, withoutResponse: withoutResponse, result: result)
        case "bleQueryStatus":
            let deviceId = args?["deviceId"] as? String ?? ""
            let timeoutMs = args?["timeoutMs"] as? Int ?? 500
            bleManager?.queryStatus(deviceId: deviceId, timeoutMs: timeoutMs, result: result)
        case "bleDisconnect":
            let deviceId = args?["deviceId"] as? String ?? ""
            bleManager?.disconnect(deviceId: deviceId, result: result)

        // Bluetooth Classic — not supported on iOS
        case "getBondedDevices":
            result(FlutterError(code: "UNSUPPORTED", message: "Bluetooth Classic is not supported on iOS", details: nil))
        case "startBtDiscovery", "stopBtDiscovery", "btConnect", "btWrite", "btDisconnect":
            result(FlutterError(code: "UNSUPPORTED", message: "Bluetooth Classic is not supported on iOS", details: nil))

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - ConnectionStateStreamHandler

class ConnectionStateStreamHandler: NSObject, FlutterStreamHandler {
    private let bleManager: BleManager

    init(bleManager: BleManager) {
        self.bleManager = bleManager
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        bleManager.connectionStateCallback = { deviceId, state in
            DispatchQueue.main.async {
                events(["type": "ble", "deviceId": deviceId, "state": state])
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        bleManager.connectionStateCallback = nil
        return nil
    }
}

// MARK: - IncomingBytesStreamHandler

/// Forwards bytes from BLE notify characteristics to the Dart side.
/// Each event is a map `{"type": "ble", "deviceId": <id>, "bytes": <Data>}`
/// — consumed per-device by the AsbMonitor in the Dart connector.
class IncomingBytesStreamHandler: NSObject, FlutterStreamHandler {
    private let bleManager: BleManager

    init(bleManager: BleManager) {
        self.bleManager = bleManager
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        bleManager.incomingBytesCallback = { deviceId, data in
            DispatchQueue.main.async {
                events([
                    "type": "ble",
                    "deviceId": deviceId,
                    "bytes": FlutterStandardTypedData(bytes: data),
                ])
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        bleManager.incomingBytesCallback = nil
        return nil
    }
}

// MARK: - NoOpStreamHandler

class NoOpStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        return nil
    }
}
