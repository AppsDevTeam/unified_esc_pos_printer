import 'dart:async';

import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import '../../core/commands.dart';
import '../../exceptions/printer_exception.dart';
import '../../models/printer_connection_state.dart';
import '../../models/printer_device.dart';
import '../../models/printer_status.dart';
import '../../models/printer_status_detail.dart';
import '../../utils/printer_logger.dart';
import '../asb_monitor.dart';
import '../post_write_status.dart';
import '../pre_write_status.dart';
import 'usb_connector_interface.dart';

const String _tag = 'USB-Android';

/// USB connector for Android using the `usb_serial` plugin.
///
/// Scans for connected USB serial devices via [UsbSerial.listDevices].
/// Requests USB permission before opening the port, then configures it for
/// 115200 baud 8N1 communication (standard for ESC/POS USB printers).
class UsbConnectorImpl extends UsbConnectorBase {
  UsbPort? _port;
  // Broadcast view of [_port.inputStream] — see network_connector for the
  // reason. Plain port.inputStream is single-subscription, so re-listening
  // (e.g. probe + verifyAfterWrite) throws.
  Stream<Uint8List>? _inboundStream;

  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool? _supportsRealtimeStatus;
  AsbMonitor? _asb;
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
  Stream<List<UsbPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);
    PrinterLogger.info(_tag, 'Scanning for USB devices');
    final List<UsbDevice> devices = await UsbSerial.listDevices();
    _setState(PrinterConnectionState.disconnected);

    if (devices.isNotEmpty) {
      PrinterLogger.info(_tag, 'Found ${devices.length} USB device(s)');
      yield devices
          .map((d) => UsbPrinterDevice(
                name: d.productName ?? 'USB Device ${d.vid}:${d.pid}',
                identifier: '${d.vid}:${d.pid}',
                usbPlatform: UsbPlatform.android,
              ))
          .toList();
    } else {
      PrinterLogger.debug(_tag, 'No USB devices found');
    }
  }

  @override
  Future<void> stopScan() async {
    if (_state == PrinterConnectionState.scanning) {
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> connect(
    UsbPrinterDevice device, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _assertState(PrinterConnectionState.disconnected, 'connect');
    PrinterLogger.info(_tag, 'Connecting to ${device.identifier}');
    _setState(PrinterConnectionState.connecting);

    // Find the matching USB device.
    final List<UsbDevice> devices = await UsbSerial.listDevices();
    UsbDevice? found;
    for (final UsbDevice d in devices) {
      if ('${d.vid}:${d.pid}' == device.identifier) {
        found = d;
        break;
      }
    }

    if (found == null) {
      PrinterLogger.error(_tag, 'Device ${device.identifier} not found');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterNotFoundException(
        'USB device ${device.identifier} not found',
      );
    }

    PrinterLogger.info(
      _tag,
      'USB device: vid=0x${found.vid?.toRadixString(16).padLeft(4, '0')}, '
      'pid=0x${found.pid?.toRadixString(16).padLeft(4, '0')}, '
      'manufacturer="${found.manufacturerName ?? '?'}", '
      'product="${found.productName ?? '?'}", '
      'deviceId=${found.deviceId}',
    );

    UsbPort? port;
    String selectedType = '';
    bool selectedRaw = false;
    try {
      // Try auto-detect first, then fall back to known serial chip types.
      // ESC/POS printers often aren't recognized by auto-detect.
      // We must also try open() because some types create successfully but fail to open.
      const List<String> typesToTry = [
        '',
        UsbSerial.CDC,
        UsbSerial.CH34x,
        UsbSerial.CP210x,
        UsbSerial.FTDI,
        UsbSerial.PL2303
      ];
      bool opened = false;
      for (final String type in typesToTry) {
        final String label = type.isEmpty ? 'auto' : type;
        try {
          PrinterLogger.debug(_tag, 'Trying serial type: "$label"');
          final UsbPort? candidate = await found.create(type);
          if (candidate == null) {
            PrinterLogger.debug(_tag, '  → create("$label") returned null');
            continue;
          }
          final bool didOpen = await candidate.open();
          if (didOpen) {
            port = candidate;
            opened = true;
            selectedType = label;
            PrinterLogger.info(_tag, 'Serial type "$label" worked');
            break;
          }
          // open() failed — close and try next
          PrinterLogger.debug(_tag, '  → "$label" open() returned false');
          await candidate.close();
        } catch (e) {
          PrinterLogger.debug(_tag, '  → "$label" threw: $e');
        }
      }

      // If no serial type worked, try raw bulk USB transfer (for direct USB printers).
      if (!opened) {
        PrinterLogger.info(
            _tag, 'Serial types failed, falling back to raw USB');
        port = await UsbSerial.createRawFromDeviceId(found.deviceId);
        if (port == null) {
          throw Exception('Could not create UsbPort – device not recognized');
        }
        opened = await port.open();
        PrinterLogger.info(_tag, 'Raw USB open: $opened');
        if (!opened) throw Exception('UsbPort.open() returned false');
        selectedType = 'raw';
        selectedRaw = true;
      }

      final UsbPort openPort = port ?? (throw Exception('port is null'));

      PrinterLogger.debug(_tag, 'Configuring port (DTR, RTS, 115200 8N1)');
      await openPort.setDTR(true);
      await openPort.setRTS(true);
      openPort.setPortParameters(
        kDefaultBaudRate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      // Send ESC @ to initialise the printer.
      await openPort.write(Uint8List.fromList(cInit.codeUnits));

      _port = openPort;
      _inboundStream = openPort.inputStream?.asBroadcastStream();
      PrinterLogger.info(
        _tag,
        'Connected to ${device.identifier} '
        '(serialType=$selectedType, raw=$selectedRaw, '
        'inputStream=${openPort.inputStream == null ? "null (READS DISABLED)" : "available"})',
      );
      _setState(PrinterConnectionState.connected);

      // Prefer ASB over DLE EOT polling — see NetworkConnector for the
      // rationale. Falls back to the original probe if the printer
      // doesn't push the initial 4-byte status packet within the timeout.
      final Stream<Uint8List>? inbound = _inboundStream;
      if (inbound != null) {
        final AsbMonitor monitor = AsbMonitor(tag: _tag);
        _asb = monitor;
        final bool asbOk = await monitor.tryEnable(
          inboundStream: inbound.cast<List<int>>(),
          sendBytes: (List<int> b) => openPort.write(Uint8List.fromList(b)),
        );

        if (!asbOk) {
          await monitor.dispose();
          _asb = null;
        }
      }

      if (_asb == null) {
        _supportsRealtimeStatus = await probeRealtimeStatus(
          queryStatusByteFn: (int n, int timeoutMs) =>
              queryStatusByte(n, timeoutMs: timeoutMs),
          tag: _tag,
        );
      }
    } on PlatformException catch (e) {
      final UsbException usbError = UsbException.fromPlatformException(e);
      PrinterLogger.error(_tag, 'USB error: $usbError');
      await port?.close();
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw _mapUsbException(usbError, device.identifier);
    } catch (e) {
      PrinterLogger.error(_tag, 'Connection failed: $e');
      await port?.close();
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'Failed to open USB device ${device.identifier}',
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
    try {
      PrinterLogger.debug(_tag, 'Writing ${bytes.length} bytes');
      await _port!.write(Uint8List.fromList(bytes));

      _setState(PrinterConnectionState.connected);
    } on PlatformException catch (e) {
      final UsbException usbError = UsbException.fromPlatformException(e);
      PrinterLogger.error(_tag, 'Write failed: $usbError');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw _mapUsbException(usbError, 'write');
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('USB write failed', cause: e);
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

    final UsbPort? port = _port;
    final Stream<Uint8List>? input = _inboundStream;
    if (port == null || input == null) return -1;

    final Completer<int> completer = Completer<int>();
    final StreamSubscription<Uint8List> sub = input.listen(
      (Uint8List data) {
        if (!completer.isCompleted && data.isNotEmpty) {
          completer.complete(data.first);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete(-1);
      },
    );

    await port.write(Uint8List.fromList([0x10, 0x04, n & 0xFF]));

    final int rawStatus = await Future.any<int>([
      completer.future,
      Future<int>.delayed(Duration(milliseconds: timeoutMs), () => -1),
    ]);
    await sub.cancel();
    return rawStatus;
  }

  @override
  Future<int> queryRawByte(List<int> request, {int timeoutMs = 500}) async {
    _assertState(PrinterConnectionState.connected, 'queryRawByte');

    final UsbPort? port = _port;
    final Stream<Uint8List>? input = _inboundStream;
    if (port == null || input == null) return -1;

    final Completer<int> completer = Completer<int>();
    final StreamSubscription<Uint8List> sub = input.listen(
      (Uint8List data) {
        if (!completer.isCompleted && data.isNotEmpty) {
          completer.complete(data.first);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete(-1);
      },
    );

    await port.write(Uint8List.fromList(request));

    final int rawResponse = await Future.any<int>([
      completer.future,
      Future<int>.delayed(Duration(milliseconds: timeoutMs), () => -1),
    ]);
    await sub.cancel();
    return rawResponse;
  }

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;
    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);

    await _asb?.dispose();
    _asb = null;

    try {
      await _port?.close();
    } finally {
      _port = null;
      _inboundStream = null;
      _supportsRealtimeStatus = null;
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

  PrinterException _mapUsbException(UsbException error, String context) {
    switch (error.code) {
      case UsbErrorCode.deviceDisconnected:
        return PrinterDisconnectedDuringOperationException(
          'USB device disconnected during $context',
          cause: error,
        );
      case UsbErrorCode.permissionDenied:
        return PrinterPermissionException(
          'USB permission denied for $context',
          cause: error,
        );
      case UsbErrorCode.deviceNotFound:
        return PrinterNotFoundException(
          'USB device not found during $context',
          cause: error,
        );
      case UsbErrorCode.deviceNotOpen:
      case UsbErrorCode.deviceOpenFailed:
        return PrinterUnreachableException(
          'USB device could not be opened during $context',
          cause: error,
        );
      case UsbErrorCode.transferFailed:
        return PrinterWriteException(
          'USB transfer failed during $context',
          cause: error,
        );
      case UsbErrorCode.noEndpointFound:
      case UsbErrorCode.interfaceClaimFailed:
        return PrinterUnreachableException(
          'USB interface error during $context: ${error.message}',
          cause: error,
        );
      default:
        return PrinterConnectionException(
          'USB error during $context: ${error.message}',
          cause: error,
        );
    }
  }
}
