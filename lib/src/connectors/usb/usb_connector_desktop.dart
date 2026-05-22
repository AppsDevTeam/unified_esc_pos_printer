import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../../core/commands.dart';
import '../../exceptions/printer_exception.dart';
import '../../models/printer_connection_state.dart';
import '../../models/printer_device.dart';
import '../../models/printer_status.dart';
import '../../utils/printer_logger.dart';
import '../post_write_status.dart';
import 'usb_connector_interface.dart';

const String _tag = 'USB-Desktop';

/// USB connector for desktop platforms (Windows, Linux, macOS) using
/// `flutter_libserialport` (wraps libserialport).
///
/// Scans via [SerialPort.availablePorts] and opens the selected COM/tty port
/// configured for 115200 baud 8N1.
class UsbConnectorImpl extends UsbConnectorBase {
  SerialPort? _port;
  SerialPortReader? _reader;

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
  Stream<List<UsbPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);
    PrinterLogger.info(_tag, 'Scanning serial ports');
    final List<String> ports = SerialPort.availablePorts;
    _setState(PrinterConnectionState.disconnected);

    // Filter out Bluetooth virtual COM ports (e.g. "Standard Serial over
    // Bluetooth link" on Windows) — only keep native and USB serial ports.
    final List<UsbPrinterDevice> devices = [];
    for (final String path in ports) {
      final SerialPort sp = SerialPort(path);
      final int transport = sp.transport;
      final String name =
          sp.description?.isNotEmpty == true ? sp.description! : path;
      sp.dispose();

      if (transport == SerialPortTransport.bluetooth) {
        PrinterLogger.debug(_tag, 'Skipping Bluetooth port: $path');
        continue;
      }

      PrinterLogger.debug(_tag, 'Found port: $path ($name)');
      devices.add(UsbPrinterDevice(
        name: name,
        identifier: path,
        usbPlatform: UsbPlatform.desktop,
      ));
    }

    PrinterLogger.info(_tag, 'Found ${devices.length} serial port(s)');

    if (devices.isNotEmpty) {
      yield devices;
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

    final SerialPort port = SerialPort(device.identifier);
    try {
      if (!port.openReadWrite()) {
        throw Exception(SerialPort.lastError?.message ?? 'Could not open port');
      }

      PrinterLogger.debug(_tag, 'Configuring port (115200 8N1)');
      final SerialPortConfig config = SerialPortConfig()
        ..baudRate = kDefaultBaudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none);

      port.config = config;

      // Send ESC @ to initialise the printer.
      port.write(Uint8List.fromList(cInit.codeUnits));

      _port = port;
      PrinterLogger.info(_tag, 'Connected to ${device.identifier}');
      _setState(PrinterConnectionState.connected);

      _supportsRealtimeStatus = await probeRealtimeStatus(
        queryStatusByteFn: (int n, int timeoutMs) =>
            queryStatusByte(n, timeoutMs: timeoutMs),
        tag: _tag,
      );
    } catch (e) {
      PrinterLogger.error(_tag, 'Connection failed: $e');
      port.dispose();
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'Failed to open serial port ${device.identifier}',
        cause: e,
      );
    }
  }

  @override
  Future<void> writeBytes(List<int> bytes, {bool verifyStatus = true}) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');
    _setState(PrinterConnectionState.printing);
    try {
      PrinterLogger.debug(_tag, 'Writing ${bytes.length} bytes');
      _port!.write(Uint8List.fromList(bytes));

      _setState(PrinterConnectionState.connected);
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('USB serial write failed', cause: e);
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

    final SerialPort? port = _port;
    if (port == null) return -1;

    final SerialPortReader reader = SerialPortReader(port, timeout: timeoutMs);
    final Completer<int> completer = Completer<int>();
    final StreamSubscription<Uint8List> sub = reader.stream.listen(
      (Uint8List data) {
        if (!completer.isCompleted && data.isNotEmpty) {
          completer.complete(data.first);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete(-1);
      },
    );

    port.write(Uint8List.fromList([0x10, 0x04, n & 0xFF]));

    final int rawStatus = await Future.any<int>([
      completer.future,
      Future<int>.delayed(Duration(milliseconds: timeoutMs), () => -1),
    ]);
    await sub.cancel();
    reader.close();
    return rawStatus;
  }

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;
    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);
    try {
      _reader?.close();
      _port?.close();
    } finally {
      _port?.dispose();
      _reader = null;
      _port = null;
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
}
