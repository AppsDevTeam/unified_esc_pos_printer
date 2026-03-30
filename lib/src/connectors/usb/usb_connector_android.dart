import 'dart:async';
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';

import '../../core/commands.dart';
import '../../exceptions/printer_exception.dart';
import '../../models/printer_connection_state.dart';
import '../../models/printer_device.dart';
import '../../utils/printer_logger.dart';
import 'usb_connector_interface.dart';

const String _tag = 'USB-Android';

/// USB connector for Android using the `usb_serial` plugin.
///
/// Scans for connected USB serial devices via [UsbSerial.listDevices].
/// Requests USB permission before opening the port, then configures it for
/// 115200 baud 8N1 communication (standard for ESC/POS USB printers).
class UsbConnectorImpl extends UsbConnectorBase {
  UsbPort? _port;

  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  @override
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  @override
  PrinterConnectionState get state => _state;

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

    UsbPort? port;
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
        try {
          PrinterLogger.debug(_tag, 'Trying serial type: "${type.isEmpty ? "auto" : type}"');
          final UsbPort? candidate = await found.create(type);
          if (candidate == null) continue;
          final bool didOpen = await candidate.open();
          if (didOpen) {
            port = candidate;
            opened = true;
            PrinterLogger.debug(_tag, 'Serial type "${type.isEmpty ? "auto" : type}" worked');
            break;
          }
          // open() failed — close and try next
          await candidate.close();
        } catch (_) {
          // Try next type
        }
      }

      // If no serial type worked, try raw bulk USB transfer (for direct USB printers).
      if (!opened) {
        PrinterLogger.debug(_tag, 'Serial types failed, trying raw USB');
        port = await UsbSerial.createRawFromDeviceId(found.deviceId);
        if (port == null) throw Exception('Could not create UsbPort – device not recognized');
        opened = await port.open();
        PrinterLogger.debug(_tag, 'Raw USB open: $opened');
        if (!opened) throw Exception('UsbPort.open() returned false');
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

      _port = port;
      PrinterLogger.info(_tag, 'Connected to ${device.identifier}');
      _setState(PrinterConnectionState.connected);
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
  Future<void> writeBytes(List<int> bytes) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');
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
  }

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;
    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);
    try {
      await _port?.close();
    } finally {
      _port = null;
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
        return PrinterConnectionException(
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
        return PrinterConnectionException(
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
        return PrinterConnectionException(
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
