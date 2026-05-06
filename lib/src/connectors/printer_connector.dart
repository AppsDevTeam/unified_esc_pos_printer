import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';
import '../models/printer_status.dart';

/// Abstract base for all connection-type-specific connectors.
///
/// [T] is the [PrinterDevice] subtype this connector handles.
///
/// Typical usage is through [PrinterManager], which selects the correct
/// connector automatically. Connectors can also be used directly for
/// advanced scenarios.
abstract class PrinterConnector<T extends PrinterDevice> {
  /// Stream of state changes. Broadcast so multiple listeners are supported.
  Stream<PrinterConnectionState> get stateStream;

  /// Current connection state.
  PrinterConnectionState get state;

  /// Scan for available devices of this connector's type.
  ///
  /// Returns a [Stream] that emits the growing list of discovered devices until
  /// [timeout] elapses or [stopScan] is called.
  Stream<List<T>> scan({Duration timeout = const Duration(seconds: 5)});

  /// Stop an in-progress scan.
  Future<void> stopScan();

  /// Connect to [device].
  ///
  /// Throws [PrinterConnectionException] if the connection fails or times out.
  /// Throws [PrinterStateException] if not in [PrinterConnectionState.disconnected].
  Future<void> connect(
    T device, {
    Duration timeout = const Duration(seconds: 5),
  });

  /// Write raw ESC/POS [bytes] to the connected printer.
  ///
  /// Throws [PrinterStateException] if not connected.
  /// Throws [PrinterWriteException] if the write fails.
  Future<void> writeBytes(List<int> bytes);

  /// Send a DLE EOT status query and return the parsed result.
  ///
  /// [timeoutMs] controls how long to wait for a response before returning
  /// [PrinterStatus.timeout].
  ///
  /// Throws [PrinterStateException] if not connected.
  Future<PrinterStatus> queryStatus({int timeoutMs = 2000});

  /// Send a DLE EOT n=[n] real-time status query and return the raw response
  /// byte, or `-1` if no response was received within [timeoutMs] (printer
  /// does not support that query, transport cannot read back, or the
  /// response was lost).
  ///
  /// Used by [PrinterManager.queryStatusDetail] to assemble a full
  /// [PrinterStatusDetail] from `n=1..4`.
  ///
  /// Connectors that cannot read back from the device (e.g. BLE without an
  /// RX characteristic) must return `-1`.
  ///
  /// Throws [PrinterStateException] if not connected.
  Future<int> queryStatusByte(int n, {int timeoutMs = 2000});

  /// Disconnect from the current printer.
  Future<void> disconnect();

  /// Release all resources held by this connector (streams, subscriptions).
  Future<void> dispose();
}
