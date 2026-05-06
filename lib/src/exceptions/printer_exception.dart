import '../models/printer_connection_state.dart';
import '../models/printer_status_detail.dart';

/// Base class for all unified_esc_pos_printer errors.
sealed class PrinterException implements Exception {
  const PrinterException(this.message, {this.cause});

  final String message;

  /// The underlying error or exception that caused this, if any.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// The requested printer device was not found or has disappeared.
class PrinterNotFoundException extends PrinterException {
  const PrinterNotFoundException(super.message, {super.cause});
}

/// Connection attempt failed or timed out.
///
/// Has more specific subtypes — match against them first when handling errors:
/// [PrinterTimeoutException], [PrinterUnreachableException],
/// [PrinterPlatformUnsupportedException],
/// [PrinterDisconnectedDuringOperationException].
class PrinterConnectionException extends PrinterException {
  const PrinterConnectionException(super.message, {super.cause});
}

/// The connection attempt timed out without a response.
///
/// Typical causes: printer is powered off, out of range (BT/BLE), or the
/// IP/port is correct but no service is listening.
class PrinterTimeoutException extends PrinterConnectionException {
  const PrinterTimeoutException(super.message, {super.cause});
}

/// The target host/device cannot be reached at all.
///
/// Network: TCP connection refused or no route to host. USB: device could
/// not be opened.
class PrinterUnreachableException extends PrinterConnectionException {
  const PrinterUnreachableException(super.message, {super.cause});
}

/// The connection type is not supported on the current OS/platform.
///
/// Examples: Classic Bluetooth on iOS/macOS/Linux, USB on web.
class PrinterPlatformUnsupportedException extends PrinterConnectionException {
  const PrinterPlatformUnsupportedException(super.message, {super.cause});
}

/// The printer was disconnected while an operation was in progress.
///
/// Emitted when the OS reports a mid-operation disconnect (USB cable pulled,
/// BLE link lost) rather than a failure to establish the connection.
class PrinterDisconnectedDuringOperationException
    extends PrinterConnectionException {
  const PrinterDisconnectedDuringOperationException(
    super.message, {
    super.cause,
  });
}

/// An operation was attempted from an invalid state.
class PrinterStateException extends PrinterException {
  const PrinterStateException(
    super.message, {
    required this.currentState,
    required this.requiredState,
    super.cause,
  });

  final PrinterConnectionState currentState;
  final PrinterConnectionState requiredState;
}

/// Writing data to the printer failed at the transport layer
/// (TCP / BT / BLE / USB write returned an error).
///
/// This does NOT mean the printer hardware reported a problem — for that
/// see [PrinterDeviceException]. It means the bytes never made it to the
/// device or the OS reported the write itself as failed.
class PrinterWriteException extends PrinterException {
  const PrinterWriteException(super.message, {super.cause});
}

/// The printer accepted the bytes but its hardware reports an error
/// condition (cover open, out of paper, paper jam, overheat, cutter error,
/// cartridge problem, …).
///
/// Inspect [detail] to find out which physical condition is reported.
/// `detail` is filled in as best-effort: connectors that cannot read back
/// from the printer (e.g. BLE without an RX characteristic) leave individual
/// fields null. Always fall back to a generic message when fields are null.
class PrinterDeviceException extends PrinterException {
  const PrinterDeviceException(super.message, {required this.detail, super.cause});

  final PrinterStatusDetail detail;

  @override
  String toString() => 'PrinterDeviceException: $message — $detail';
}

/// The OS denied a required permission (Bluetooth, USB, etc.).
class PrinterPermissionException extends PrinterException {
  const PrinterPermissionException(super.message, {super.cause});
}

/// A scan failed or completed with no results.
///
/// Has a more specific subtype — match against it first when handling errors:
/// [PrinterNetworkUnavailableException].
class PrinterScanException extends PrinterException {
  const PrinterScanException(super.message, {super.cause});
}

/// Network-based scan failed because the device has no usable WiFi network
/// (no local IP, missing permissions, airplane mode, …).
class PrinterNetworkUnavailableException extends PrinterScanException {
  const PrinterNetworkUnavailableException(super.message, {super.cause});
}
