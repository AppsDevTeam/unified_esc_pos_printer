import 'dart:async';

import 'package:flutter/services.dart';

import '../exceptions/printer_exception.dart';
import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';
import '../platform/bluetooth_platform_channel.dart';
import '../utils/printer_logger.dart';
import 'printer_connector.dart';

const String _tag = 'BLE';

/// Connector for BLE (Bluetooth Low Energy) ESC/POS printers.
///
/// **Discovery:** Uses native BLE scanning to find nearby BLE devices.
///
/// **Connection:** Discovers services, then auto-locates a writable
/// characteristic. Tries the well-known ESC/POS BLE service UUID first;
/// falls back to any writable characteristic found.
///
/// **Writing:** Negotiates MTU 512 after connecting and chunks data into
/// MTU-sized write operations.
///
/// **Permissions:** Automatically requests Bluetooth permissions when
/// scanning or connecting. Throws [PrinterPermissionException] if denied.
class BleConnector extends PrinterConnector<BlePrinterDevice> {
  final BluetoothPlatformChannel _platform = BluetoothPlatformChannel.instance;

  int _mtuPayload = 20;
  bool _writeWithoutResponse = false;
  String? _connectedDeviceId;
  StreamSubscription<Map<String, dynamic>>? _connectionSub;

  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  @override
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  @override
  PrinterConnectionState get state => _state;

  @override
  Stream<List<BlePrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);
    PrinterLogger.info(_tag, 'Starting scan (timeout: ${timeout.inSeconds}s)');

    // Request permissions first
    final bool granted = await _platform.requestBluetoothPermissions();
    if (!granted) {
      PrinterLogger.error(_tag, 'Bluetooth permissions denied');
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterPermissionException(
        'Bluetooth permissions were denied',
      );
    }

    final List<BlePrinterDevice> found = [];

    // Emit bonded (paired) BLE devices immediately.
    try {
      final List<Map<String, dynamic>> bonded =
          await _platform.getBondedBleDevices();

      for (final Map<String, dynamic> d in bonded) {
        found.add(BlePrinterDevice(
          name: (d['name'] as String?) ?? (d['deviceId'] as String),
          deviceId: d['deviceId'] as String,
        ));
      }

      if (found.isNotEmpty) {
        PrinterLogger.debug(
          _tag,
          'Found ${found.length} bonded BLE device(s)',
        );
        yield List<BlePrinterDevice>.from(found);
      }
    } catch (_) {
      // Ignore — permissions may be denied; scan below will also fail.
    }

    final Completer<void> scanDone = Completer<void>();
    StreamSubscription<List<Map<String, dynamic>>>? scanSub;

    try {
      try {
        await _platform.startBleScan(
          timeoutMs: timeout.inMilliseconds,
        );
      } catch (e) {
        PrinterLogger.error(_tag, 'Failed to start BLE scan: $e');
        _setState(PrinterConnectionState.disconnected);

        if (found.isNotEmpty) return;

        throw PrinterScanException('Failed to start BLE scan', cause: e);
      }

      scanSub = _platform.bleScanResults.listen(
        (devices) {
          for (final Map<String, dynamic> d in devices) {
            final String id = d['deviceId'] as String;
            if (!found.any((dev) => dev.deviceId == id)) {
              final String name = (d['name'] as String?) ?? id;
              PrinterLogger.debug(_tag, 'Discovered: $name ($id)');
              found.add(BlePrinterDevice(
                name: name,
                deviceId: id,
              ));
            }
          }
        },
        onError: (e) {
          if (!scanDone.isCompleted) scanDone.complete();
        },
        onDone: () {
          if (!scanDone.isCompleted) scanDone.complete();
        },
      );

      // Wait for scan timeout
      await Future.any([
        scanDone.future,
        Future.delayed(timeout),
      ]);

      if (found.isNotEmpty) yield found;
    } finally {
      if (scanSub != null) {
        try {
          await scanSub.cancel();
        } on PlatformException catch (_) {
          // Native stream may already be deactivated after scan timeout.
        }
      }
      PrinterLogger.info(
        _tag,
        'Scan complete — found ${found.length} device(s)',
      );
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> stopScan() async {
    try {
      await _platform.stopBleScan();
    } catch (_) {
      // Ignore errors from stopBleScan, as it may be called after a failed startBleScan
    }

    if (_state == PrinterConnectionState.scanning) {
      PrinterLogger.debug(_tag, 'Stopping scan');
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> connect(
    BlePrinterDevice device, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _assertState(PrinterConnectionState.disconnected, 'connect');
    PrinterLogger.info(_tag, 'Connecting to ${device.name} (${device.deviceId})');
    _setState(PrinterConnectionState.connecting);

    // Request permissions
    final bool granted = await _platform.requestBluetoothPermissions();
    if (!granted) {
      PrinterLogger.error(_tag, 'Bluetooth permissions denied');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterPermissionException(
        'Bluetooth permissions were denied',
      );
    }

    try {
      await _platform.bleConnect(
        deviceId: device.deviceId,
        timeoutMs: timeout.inMilliseconds,
        serviceUuid: device.serviceUuid,
        characteristicUuid: device.txCharacteristicUuid,
      );
    } catch (e) {
      PrinterLogger.error(_tag, 'Connection failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'BLE connection to ${device.name} failed',
        cause: e,
      );
    }

    _connectedDeviceId = device.deviceId;

    // Get negotiated MTU
    try {
      _mtuPayload = await _platform.bleGetMtu(deviceId: device.deviceId);
      PrinterLogger.debug(_tag, 'Negotiated MTU payload: $_mtuPayload bytes');
    } catch (_) {
      _mtuPayload = 20; // safe minimum
      PrinterLogger.warning(_tag, 'MTU negotiation failed, using default: 20');
    }

    // Check write-without-response support
    try {
      _writeWithoutResponse = await _platform.bleSupportsWriteWithoutResponse(
        deviceId: device.deviceId,
      );
      PrinterLogger.debug(
        _tag,
        'Write-without-response: $_writeWithoutResponse',
      );
    } catch (_) {
      _writeWithoutResponse = false;
    }

    // Monitor for remote disconnection
    _connectionSub = _platform.connectionStateStream
        .where((event) =>
            event['type'] == 'ble' &&
            event['deviceId'] == device.deviceId)
        .listen((event) {
      if (event['state'] == 'disconnected' &&
          _state != PrinterConnectionState.disconnected) {
        PrinterLogger.warning(_tag, 'Remote disconnection detected');
        _connectedDeviceId = null;
        _setState(PrinterConnectionState.error);
        _setState(PrinterConnectionState.disconnected);
      }
    });

    PrinterLogger.info(
      _tag,
      'Connected to ${device.name} (MTU: $_mtuPayload)',
    );
    _setState(PrinterConnectionState.connected);
  }

  @override
  Future<void> writeBytes(List<int> bytes) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');

    final String deviceId = _connectedDeviceId ?? '';

    _setState(PrinterConnectionState.printing);

    final int chunks = (bytes.length / _mtuPayload).ceil();
    PrinterLogger.debug(
      _tag,
      'Writing ${bytes.length} bytes in $chunks chunk(s)',
    );

    try {
      for (int i = 0; i < bytes.length; i += _mtuPayload) {
        final int end = (i + _mtuPayload).clamp(0, bytes.length);
        await _platform.bleWrite(
          deviceId: deviceId,
          data: Uint8List.fromList(bytes.sublist(i, end)),
          withoutResponse: _writeWithoutResponse,
        );
      }

      _setState(PrinterConnectionState.connected);
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('BLE write failed', cause: e);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;

    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);

    await _connectionSub?.cancel();
    _connectionSub = null;

    try {
      final String deviceId = _connectedDeviceId ?? '';
      _connectedDeviceId = null;
      await _platform.bleDisconnect(deviceId: deviceId);
    } finally {
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await disconnect();
    await _stateController.close();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _setState(PrinterConnectionState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _assertState(PrinterConnectionState required, String operation) {
    if (_state != required) {
      throw PrinterStateException(
        'Cannot $operation: expected $required but was $_state',
        currentState: _state,
        requiredState: required,
      );
    }
  }
}
