import 'dart:async';

import '../../exceptions/printer_exception.dart';
import '../../models/printer_connection_state.dart';
import '../../models/printer_device.dart';
import '../../models/printer_status.dart';
import 'usb_connector_interface.dart';

/// Stub USB connector for unsupported platforms (web, Fuchsia, etc.).
///
/// All methods throw [PrinterConnectionException].
class UsbConnectorImpl extends UsbConnectorBase {
  @override
  Stream<PrinterConnectionState> get stateStream =>
      const Stream<PrinterConnectionState>.empty();

  @override
  PrinterConnectionState get state => PrinterConnectionState.disconnected;

  @override
  Stream<List<UsbPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) {
    return throw const PrinterConnectionException(
      'USB printing is not supported on this platform',
    );
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(
    UsbPrinterDevice device, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return throw const PrinterConnectionException(
      'USB printing is not supported on this platform',
    );
  }

  @override
  Future<void> writeBytes(List<int> bytes) {
    return throw const PrinterConnectionException(
      'USB printing is not supported on this platform',
    );
  }

  @override
  Future<PrinterStatus> queryStatus({int timeoutMs = 2000}) async {
    return PrinterStatus.unsupported;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}
}
