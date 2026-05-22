import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/commands.dart';
import '../exceptions/printer_exception.dart';
import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';

import '../platform/bluetooth_platform_channel.dart';
import '../models/printer_status.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';
import 'asb_monitor.dart';
import 'post_write_status.dart';
import 'pre_write_status.dart';
import 'printer_connector.dart';

const String _tag = 'Bluetooth';

/// Connector for Bluetooth Classic (SPP) ESC/POS printers.
///
/// **Platform support:** Android and Windows. Calling any method on iOS,
/// macOS, or Linux throws [PrinterConnectionException].
///
/// **Discovery:** Returns paired devices immediately via bonded device query,
/// then streams additional devices found during discovery.
///
/// **Writing:** Data is chunked into [chunkSize] byte blocks.
///
/// **Permissions:** Automatically requests Bluetooth permissions when
/// scanning or connecting. Throws [PrinterPermissionException] if denied.
class BluetoothConnector extends PrinterConnector<BluetoothPrinterDevice> {
  BluetoothConnector({this.chunkSize = kDefaultBtChunkSize});

  /// Maximum bytes per Bluetooth write operation.
  final int chunkSize;

  final BluetoothPlatformChannel _platform = BluetoothPlatformChannel.instance;
  String? _connectedAddress;
  StreamSubscription<Map<String, dynamic>>? _connectionSub;
  AsbMonitor? _asb;

  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool? _supportsRealtimeStatus;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  @override
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  @override
  PrinterConnectionState get state => _state;

  @override
  bool? get supportsRealtimeStatus => _supportsRealtimeStatus;

  @override
  bool get supportsAsb => _asb?.isEnabled ?? false;

  @override
  PrinterStatusDetail get latestAsbStatus =>
      _asb?.latest ?? const PrinterStatusDetail();

  @override
  Stream<PrinterStatusDetail> get asbStatusStream =>
      _asb?.statusStream ?? const Stream<PrinterStatusDetail>.empty();

  @override
  Stream<List<BluetoothPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);
    PrinterLogger.info(_tag, 'Starting scan (timeout: ${timeout.inSeconds}s)');

    if (!Platform.isAndroid && !Platform.isWindows) {
      PrinterLogger.error(
          _tag, 'Unsupported platform: ${Platform.operatingSystem}');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterPlatformUnsupportedException(
        'Classic Bluetooth (SPP) is only supported on Android and Windows. '
        'Use BleConnector for other platforms.',
      );
    }

    // Request permissions (no-op on Windows)
    final bool granted = await _platform.requestBluetoothPermissions();
    if (!granted) {
      PrinterLogger.error(_tag, 'Bluetooth permissions denied');
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterPermissionException(
        'Bluetooth permissions were denied',
      );
    }

    final List<BluetoothPrinterDevice> found = [];

    // Emit bonded (paired) devices immediately.
    try {
      final List<Map<String, dynamic>> bonded =
          await _platform.getBondedDevices();

      for (final Map<String, dynamic> d in bonded) {
        found.add(BluetoothPrinterDevice(
          name: (d['name'] as String?) ?? (d['address'] as String),
          address: d['address'] as String,
        ));
      }

      if (found.isNotEmpty) {
        PrinterLogger.debug(
          _tag,
          'Found ${found.length} bonded device(s)',
        );
        yield List<BluetoothPrinterDevice>.from(found);
      }
    } catch (_) {
      // Ignore — permissions may be denied; discovery below will also fail.
    }

    // Stream newly discovered devices until timeout or discovery finishes.
    final Completer<void> discoveryDone = Completer<void>();
    StreamSubscription<List<Map<String, dynamic>>>? discoverySub;

    try {
      try {
        await _platform.startBtDiscovery(
          timeoutMs: timeout.inMilliseconds,
        );
      } catch (e) {
        PrinterLogger.error(_tag, 'Failed to start discovery: $e');
        _setState(PrinterConnectionState.disconnected);

        if (found.isNotEmpty) return;

        throw PrinterScanException('Failed to start BT discovery', cause: e);
      }

      discoverySub = _platform.btDiscoveryResults.listen(
        (devices) {
          for (final Map<String, dynamic> d in devices) {
            final String addr = d['address'] as String;
            if (!found.any((dev) => dev.address == addr)) {
              final String name = (d['name'] as String?) ?? addr;
              PrinterLogger.debug(_tag, 'Discovered: $name ($addr)');
              found.add(BluetoothPrinterDevice(
                name: name,
                address: addr,
              ));
            }
          }
        },
        onDone: () {
          if (!discoveryDone.isCompleted) discoveryDone.complete();
        },
        onError: (_) {
          if (!discoveryDone.isCompleted) discoveryDone.complete();
        },
      );

      // Race between discovery completing and timeout.
      await Future.any([
        discoveryDone.future,
        Future.delayed(timeout),
      ]);

      if (found.isNotEmpty) yield List<BluetoothPrinterDevice>.from(found);
    } finally {
      if (discoverySub != null) {
        try {
          await discoverySub.cancel();
        } on PlatformException catch (_) {
          // Native stream may already be deactivated after discovery timeout.
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
    if (!Platform.isAndroid && !Platform.isWindows) return;

    try {
      await _platform.stopBtDiscovery();
    } catch (_) {
      // Ignore — discovery may have already finished or permissions may be denied.
    }

    if (_state == PrinterConnectionState.scanning) {
      PrinterLogger.debug(_tag, 'Stopping scan');
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> connect(
    BluetoothPrinterDevice device, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _assertState(PrinterConnectionState.disconnected, 'connect');
    PrinterLogger.info(
      _tag,
      'Connecting to ${device.name} (${device.address})',
    );
    _setState(PrinterConnectionState.connecting);

    if (!Platform.isAndroid && !Platform.isWindows) {
      PrinterLogger.error(
          _tag, 'Unsupported platform: ${Platform.operatingSystem}');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterPlatformUnsupportedException(
        'Classic Bluetooth (SPP) is only supported on Android and Windows. '
        'Use BleConnector for other platforms.',
      );
    }

    // Request permissions (no-op on Windows)
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
      await _platform.btConnect(
        address: device.address,
        timeoutMs: timeout.inMilliseconds,
      );

      // Send ESC @ to initialise the printer.
      await _platform.btWrite(
        address: device.address,
        data: Uint8List.fromList(cInit.codeUnits),
      );

      _connectedAddress = device.address;

      // Monitor for remote disconnection.
      _connectionSub = _platform.connectionStateStream
          .where((event) =>
              event['type'] == 'bt' && event['deviceId'] == device.address)
          .listen((event) {
        if (event['state'] == 'disconnected' &&
            _state != PrinterConnectionState.disconnected) {
          PrinterLogger.warning(_tag, 'Remote disconnection detected');
          _connectedAddress = null;
          _supportsRealtimeStatus = null;
          _connectionSub?.cancel();
          _connectionSub = null;
          _setState(PrinterConnectionState.error);
          _setState(PrinterConnectionState.disconnected);
        }
      });

      PrinterLogger.info(
        _tag,
        'Connected to ${device.name} (${device.address})',
      );
      _setState(PrinterConnectionState.connected);

      // Prefer ASB over DLE EOT polling — see NetworkConnector for the
      // rationale. Falls back to the original probe if the printer
      // doesn't push the initial 4-byte status packet within the
      // timeout.
      final String address = device.address;
      final Stream<List<int>> inboundBytes = _platform.incomingBytesStream
          .where((Map<String, dynamic> event) =>
              event['type'] == 'bt' && event['deviceId'] == address)
          .map((Map<String, dynamic> event) {
        final Object? raw = event['bytes'];
        if (raw is Uint8List) return raw;
        if (raw is List<int>) return raw;
        return const <int>[];
      });

      final AsbMonitor monitor = AsbMonitor(tag: _tag);
      _asb = monitor;
      final bool asbOk = await monitor.tryEnable(
        inboundStream: inboundBytes,
        sendBytes: (List<int> b) => _platform.btWrite(
          address: address,
          data: Uint8List.fromList(b),
        ),
      );

      if (!asbOk) {
        await monitor.dispose();
        _asb = null;
        _supportsRealtimeStatus = await probeRealtimeStatus(
          queryStatusByteFn: (int n, int timeoutMs) =>
              queryStatusByte(n, timeoutMs: timeoutMs),
          tag: _tag,
        );
      }
    } on TimeoutException catch (e) {
      PrinterLogger.error(
        _tag,
        'Connection timed out to ${device.address}',
      );
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterTimeoutException(
        'Bluetooth connection to ${device.address} timed out',
        cause: e,
      );
    } catch (e) {
      PrinterLogger.error(_tag, 'Connection failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'Bluetooth connection to ${device.address} failed',
        cause: e,
      );
    }
  }

  @override
  Future<void> writeBytes(List<int> bytes, {bool verifyStatus = true}) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');

    final AsbMonitor? asb = _asb;
    if (verifyStatus) {
      if (asb == null || !asb.isEnabled) {
        // See NetworkConnector for the rationale — quick DLE EOT poll
        // before the write so we catch mid-session error states and
        // late-bind realtime-status support on first positive response.
        _supportsRealtimeStatus = await verifyBeforeWrite(
          queryStatusByteFn: (int n, int timeoutMs) =>
              queryStatusByte(n, timeoutMs: timeoutMs),
          supportsRealtimeStatus: _supportsRealtimeStatus,
          tag: _tag,
        );
      }

      if (asb != null && asb.isEnabled && asb.latest.hasAnyProblem) {
        PrinterLogger.error(
          _tag,
          'Pre-write: refusing print, ASB reports problem: ${asb.latest}',
        );
        throw PrinterDeviceException(
          'Printer reports an error condition',
          detail: asb.latest,
        );
      }
    }

    _setState(PrinterConnectionState.printing);

    final String address = _connectedAddress ?? '';

    final int chunks = (bytes.length / chunkSize).ceil();
    PrinterLogger.debug(
      _tag,
      'Writing ${bytes.length} bytes in $chunks chunk(s)',
    );

    try {
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final int end = (i + chunkSize).clamp(0, bytes.length);
        await _platform.btWrite(
          address: address,
          data: Uint8List.fromList(bytes.sublist(i, end)),
        );
      }

      _setState(PrinterConnectionState.connected);
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('Bluetooth write failed', cause: e);
    }

    if (!verifyStatus) return;

    if (asb != null && asb.isEnabled) {
      if (asb.latest.hasAnyProblem) {
        PrinterLogger.error(
          _tag,
          'Post-write: ASB reports problem: ${asb.latest}',
        );
        throw PrinterDeviceException(
          'Printer reports an error condition',
          detail: asb.latest,
        );
      }
      return;
    }

    await verifyAfterWrite(
      queryStatusByteFn: (int n, int timeoutMs) =>
          queryStatusByte(n, timeoutMs: timeoutMs),
      bytesWritten: bytes.length,
      supportsRealtimeStatus: _supportsRealtimeStatus,
      tag: _tag,
    );
  }

  @override
  Future<PrinterStatus> queryStatus({int timeoutMs = 2000}) async {
    final int raw = await queryStatusByte(1, timeoutMs: timeoutMs);
    final PrinterStatus status =
        raw >= 0 ? PrinterStatus.fromByte(raw) : PrinterStatus.timeout;
    PrinterLogger.debug(_tag, 'queryStatus: $status');
    return status;
  }

  @override
  Future<int> queryStatusByte(int n, {int timeoutMs = 2000}) async {
    _assertState(PrinterConnectionState.connected, 'queryStatusByte');
    final String address = _connectedAddress ?? '';
    try {
      return await _platform.btQueryStatus(
        address: address,
        n: n,
        timeoutMs: timeoutMs,
      );
    } on MissingPluginException {
      // Windows native plugin does not implement btQueryStatus — treat as
      // "transport cannot read back" rather than letting the exception
      // bubble up and break the print.
      return -1;
    } on PlatformException catch (e) {
      PrinterLogger.warning(_tag, 'btQueryStatus failed: ${e.message}');
      return -1;
    }
  }

  @override
  Future<int> queryRawByte(List<int> request, {int timeoutMs = 500}) async {
    _assertState(PrinterConnectionState.connected, 'queryRawByte');

    // Refuse to interleave with an active ASB stream — the response
    // byte would be eaten by the AsbMonitor's packet buffer and we'd
    // never see it (or worse, corrupt the next ASB packet boundary).
    final AsbMonitor? asb = _asb;
    if (asb != null && asb.isEnabled) {
      PrinterLogger.warning(
        _tag,
        'queryRawByte refused: ASB stream active on this connection',
      );
      return -1;
    }

    final String address = _connectedAddress ?? '';
    final Completer<int> completer = Completer<int>();
    StreamSubscription<Map<String, dynamic>>? sub;

    try {
      sub = _platform.incomingBytesStream
          .where((Map<String, dynamic> event) =>
              event['type'] == 'bt' && event['deviceId'] == address)
          .listen(
        (Map<String, dynamic> event) {
          if (completer.isCompleted) return;
          final Object? raw = event['bytes'];
          List<int>? bytes;
          if (raw is Uint8List) bytes = raw;
          if (raw is List<int>) bytes = raw;
          if (bytes != null && bytes.isNotEmpty) {
            completer.complete(bytes.first);
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.complete(-1);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(-1);
        },
        cancelOnError: true,
      );
    } catch (e) {
      PrinterLogger.warning(_tag, 'queryRawByte listen failed: $e');
      return -1;
    }

    try {
      await _platform.btWrite(
        address: address,
        data: Uint8List.fromList(request),
      );
    } catch (e) {
      PrinterLogger.warning(_tag, 'queryRawByte write failed: $e');
      await sub.cancel();
      return -1;
    }

    final int rawResponse = await Future.any<int>([
      completer.future,
      Future<int>.delayed(Duration(milliseconds: timeoutMs), () => -1),
    ]);
    await sub.cancel();
    return rawResponse;
  }

  // ── Disconnection ──────────────────────────────────────────────────────────

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;

    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);

    await _connectionSub?.cancel();
    _connectionSub = null;

    await _asb?.dispose();
    _asb = null;

    try {
      final String? address = _connectedAddress;
      _connectedAddress = null;
      _supportsRealtimeStatus = null;
      if (address != null) {
        await _platform.btDisconnect(address: address);
      }
    } finally {
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
  }

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
