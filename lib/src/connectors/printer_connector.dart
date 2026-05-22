import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';
import '../models/printer_status.dart';
import '../models/printer_status_detail.dart';

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
  /// When [verifyStatus] is `true` (default), the connector also runs
  /// its pre-write and post-write status checks (DLE EOT polling +
  /// retry, and ASB pre-write/post-write gating when ASB is active).
  /// Set to `false` for control-byte sends — drawer open, LED toggle,
  /// short test sequences — where the latency of a status round-trip
  /// is unwanted and a fault on those bytes wouldn't change the
  /// caller's behavior anyway.
  ///
  /// Throws [PrinterStateException] if not connected.
  /// Throws [PrinterWriteException] if the write fails.
  /// Throws [PrinterDeviceException] when [verifyStatus] is `true` and
  /// the printer reports an error in its pre-write or post-write
  /// status check.
  Future<void> writeBytes(List<int> bytes, {bool verifyStatus = true});

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

  /// Send arbitrary [request] bytes and return the first response byte,
  /// or `-1` on timeout / transport without read capability.
  ///
  /// Escape hatch for experimenting with non-standard status protocols —
  /// e.g. `GS r 1` (paper sensor, in-queue), `ESC v` (older paper-end
  /// query), or vendor-specific commands — without having to add a new
  /// dedicated method per command. Callers parse the returned byte
  /// themselves.
  ///
  /// Default implementation returns `-1`; concrete connectors with a
  /// read-back path override it.
  ///
  /// Throws [PrinterStateException] if not connected.
  Future<int> queryRawByte(List<int> request, {int timeoutMs = 500}) async {
    return -1;
  }

  /// Whether the currently-connected printer responded to a DLE EOT 1 probe
  /// during [connect]. Many cheap thermal printers don't implement DLE EOT;
  /// for those we have no way to tell "post-write timeout = error" from
  /// "post-write timeout = the printer just doesn't speak this protocol",
  /// and we must treat write success as the source of truth.
  ///
  /// Values:
  /// - `true`: probe got a response — a post-write timeout is a real problem.
  /// - `false`: probe did not respond — post-write timeouts must be ignored.
  /// - `null`: probe has not run yet (not connected, transport that cannot
  ///   read back like BLE/Windows spooler).
  bool? get supportsRealtimeStatus;

  /// Whether the currently-connected printer has been confirmed to push
  /// Automatic Status Back (ASB) packets, enabled at connect via the
  /// `GS a n` ESC/POS command. When `true` the connector relies on ASB
  /// pushes for status (mutually exclusive with DLE EOT polling on the
  /// same byte stream); when `false` (or `null`) the connector falls
  /// back to DLE EOT polling and treats writes as best-effort.
  ///
  /// Default: `false` — transports that don't expose an inbound byte
  /// stream (current iOS BLE, Windows print spooler, …) override
  /// nothing and inherit the safe default.
  bool get supportsAsb => false;

  /// Latest [PrinterStatusDetail] reported by the printer via an ASB
  /// push. Empty (`isUnknown == true`) before the first ASB packet
  /// arrives or when [supportsAsb] is `false`.
  ///
  /// Connectors gate [writeBytes] on `latestAsbStatus.hasAnyProblem`
  /// when [supportsAsb] is `true` — a printer that reports paper-out
  /// must not be sent a job that would just sit in its buffer.
  PrinterStatusDetail get latestAsbStatus => const PrinterStatusDetail();

  /// Pushed every time a fresh ASB packet is parsed. Empty stream if
  /// ASB is not supported on this connection.
  Stream<PrinterStatusDetail> get asbStatusStream =>
      const Stream<PrinterStatusDetail>.empty();

  /// Disconnect from the current printer.
  Future<void> disconnect();

  /// Release all resources held by this connector (streams, subscriptions).
  Future<void> dispose();
}
